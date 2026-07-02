# R1 — Sentinel (Principal Engineer) — Hands-free Voice Command Review

Target: comet-by-orbit hands-free voice commands. Focus: concurrency, AVAudioEngine
lifecycle, the `recorder.onBuffer` tee, async transcription races, timers/Tasks, error
paths, crashes.

"Will this still be debuggable in 6 months?" — the honest answer is: the data races
below will produce field crashes that reproduce ~never on a dev machine and constantly
on a busy user's mic. Fix those first.

---

## SHIP-NOW (breaks operation / crashes / wedges)

### S1 — `isActive` / `mode` are cross-thread data races, not "queue-confined"
**File:** `Sources/Input/WhisperCommandDetector.swift:51,50` (decls), written at `73–74, 78–80, 91–93`, read at `86, 135, 139, 224`.

`mode` and `isActive` are plain stored `var`s with **no synchronization**. The comment at
line 20/53 implies confinement, but the actual access pattern crosses three execution
contexts:

- **Written on the main actor:** `startIdle()`, `startRecording()`, `stop()` are all called
  only from `AppState` (`@MainActor`) — lines 73–74, 78–81, 91–93.
- **Read on the audio (tap) thread:** `feed()` at :86 (`guard isActive, mode == .recording`)
  and `ingest()` at :135 (`guard isActive`) run inside the recorder tap callback / AVAudioEngine
  render-adjacent thread.
- **Read on the serial `queue`:** `handle()` at :139 (`guard isActive`), and `mode` is captured
  at :224 (`let currentMode = mode`) inside `finalizeUtterance()`.

Concurrent read on the audio thread while the main actor writes `isActive = false` in `stop()`
is an unsynchronized read/write on non-atomic memory = undefined behaviour. In practice on
Swift/ARM it usually only tears/staleness, but `mode` transitions (`.idle`→`.recording`) racing
with in-flight tap buffers is the exact window that produces wrong-mode processing (see S2) and,
with the Swift runtime's exclusivity checks, can trap.

**Why it breaks operation:** every arm/disarm and every start/stop transition is a race window.
A user toggling the wake word or saying "start/stop" repeatedly (the normal usage!) hits it.
Symptom: sporadic crashes or a detector that processes a buffer in the wrong mode.

**Fix:** confine ALL mutable state to `queue`. Make `isActive`/`mode` writes hop through the queue,
and have the audio-thread entry points (`feed`, `ingest`) not read them directly — read them inside
`queue.async`:

```swift
func startIdle() {
    queue.async { self.mode = .idle; self.isActive = true }
    startOwnEngine()          // engine lifecycle stays on main
}
func startRecording() {
    stopEngine()
    queue.async { self.mode = .recording; self.isActive = true; self.resetUtterance() }
}
func stop() {
    queue.async { self.isActive = false; self.discardUtterance() }
    stopEngine()
}
func feed(_ buffer: AVAudioPCMBuffer) {
    queue.async { guard self.isActive, self.mode == .recording else { return }; self.handle(buffer) }
}
private func ingest(_ buffer: AVAudioPCMBuffer) {
    queue.async { guard self.isActive else { return }; self.handle(buffer) }
}
```
(Engine start/stop must remain on the calling/main thread — don't move AVAudioEngine onto the
serial queue. Only the *flags* move.)

---

### S2 — Own-engine tap buffers get processed AFTER `startRecording()`, in `.recording` mode, with no engine to match
**File:** `WhisperCommandDetector.swift:107–109, 122–128, 77–82, 134–137`

`stopEngine()` (:122) does `removeTap` + `engine.stop()` synchronously, but AVAudioEngine tap
callbacks already **in flight / already dispatched** to `queue` are not cancelled. `ingest()`
does `queue.async { self.handle(buffer) }` — so a buffer captured microseconds before
`removeTap` sits in the serial queue. When `startRecording()` then flips `mode = .recording`
and `resetUtterance()`, that stale idle-mic buffer is now `handle()`-d under `.recording`
semantics.

**Why it breaks operation:** at the exact "Start Comet" → begin-recording transition, leftover
idle-engine audio can open/extend an utterance that then gets matched against **stop** phrases.
Low-probability per transition, but it's the core hot path of the feature. Also couples with S1.

**Fix:** stamp each capture with a generation token. Bump it on every `startIdle`/`startRecording`/`stop`
(on the queue), capture it at `ingest` time, and drop buffers whose token != current inside `handle`:

```swift
private var generation = 0            // queue-confined
private func ingest(_ buffer: AVAudioPCMBuffer) {
    queue.async {
        let gen = self.generation
        guard self.isActive else { return }
        self.handle(buffer, gen: gen)
    }
}
// in handle: guard gen == self.generation else { return }
```
Bump `generation` wherever mode/isActive change.

---

### S3 — `recorder.onBuffer` tee retains `WhisperCommandDetector` indirectly and is set/cleared on races; buffer outlives the tap
**File:** `Sources/App/AppState.swift:431–433, 621, 407`; `Sources/Audio/AudioRecorder.swift:184, 169`

Two issues, one file:onBuffer.

(a) **The raw tap buffer is hopped across a queue without a copy.** `AudioRecorder.handleIncomingBuffer`
fires `onBuffer?(buffer)` (:184) with the *same* `AVAudioPCMBuffer` the tap owns. The tee lands in
`WhisperCommandDetector.feed` → `ingest` → `queue.async { self.handle(buffer) }` (:136). The tap's
buffer storage is only valid for the duration of the tap callback; AVAudioEngine reuses/frees its
ring buffers after the callback returns. `handle` then reads `buffer.floatChannelData`/writes it to
`AVAudioFile` on the serial queue **after the tap callback has returned** — use-after-free / garbage
RMS / corrupt utterance audio. The recorder's *own* writer path (`fileQueue.async`, :169) has the
identical pattern and the comment at :132 in the detector literally says "tap buffers survive this in
practice" — that's a hope, not a guarantee, and it's the classic AVAudioEngine footgun.

**Why it breaks operation:** intermittent corrupt command audio (so "Comet stop" silently fails to
transcribe) and, under load, a crash in `write(from:)` or the RMS loop. "In practice" holds until the
user has a fast input device or the system is under memory pressure.

**Fix:** deep-copy the buffer before crossing the queue boundary, in BOTH `ingest` and the recorder's
writer hop:

```swift
private func ingest(_ buffer: AVAudioPCMBuffer) {
    guard let copy = buffer.deepCopy() else { return }
    queue.async { ... self.handle(copy) }
}
// extension AVAudioPCMBuffer { func deepCopy() -> AVAudioPCMBuffer? {
//   guard let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
//   c.frameLength = frameLength
//   let ch = Int(format.channelCount); let n = Int(frameLength)
//   if let s = floatChannelData, let d = c.floatChannelData { for i in 0..<ch { memcpy(d[i], s[i], n*MemoryLayout<Float>.size) } }
//   else if let s = int16ChannelData, let d = c.int16ChannelData { for i in 0..<ch { memcpy(d[i], s[i], n*MemoryLayout<Int16>.size) } }
//   return c } }
```
(The recorder's own `fileQueue.async` write at AudioRecorder.swift:169 needs the same copy — separate
but identical latent bug in the non-wake path.)

(b) **`onBuffer` closure strongly forms a cycle window.** `recorder.onBuffer = { [weak self] buffer in self?.commandDetector.feed(buffer) }` (:431) is `[weak self]` — good. But it's cleared only on the
pipeline-idle path (:621) and `disarmWakeWord` (:407). If a wake session ends via an **error path** that
routes `phase → .error`, observePipeline's `.error` case (AppState:612) DOES clear it — OK. But if
`wakeWordEnabledChanged(to:false)` is called mid-recording, `disarmWakeWord` clears `onBuffer` and calls
`commandDetector.stop()` while a recording is still active and the pipeline still owns the recorder — the
tee stops but the recording continues headless with no stop-phrase listener and no max-duration guard reset
(the guard was armed for *that* session). Not a crash, but a wedge risk — see S4.

---

### S4 — Turning the wake word OFF mid-recording orphans the running dictation
**File:** `AppState.swift:412–415, 401–409, 469–478`

`wakeWordEnabledChanged(to:false)` → `disarmWakeWord()` cancels `wakeMaxDurationTask` (:405) and nils
`onBuffer`. But if a **wake-initiated recording is in progress**, `wakeInitiatedSession` is still `true`
and the pipeline is still recording. The max-duration safety task is now cancelled, `onBuffer` is nil so
"Comet stop" can never fire, and nothing stops the recording. The only remaining stop is the user's
hotkey or the pipeline finishing on its own — but a hands-free user who just disabled the feature reasonably
expects the mic to close.

**Why it breaks operation:** mic stays open indefinitely on a session the user thought they killed. This is
the "mic doesn't stay open indefinitely" invariant the code explicitly tries to hold (:467) — this path
defeats it.

**Fix:** in `disarmWakeWord()`, if a wake session is live, stop the dictation too:

```swift
func disarmWakeWord() {
    wakeAutoDisarmTask?.cancel(); wakeAutoDisarmTask = nil
    wakeMaxDurationTask?.cancel(); wakeMaxDurationTask = nil
    wakeArmed = false
    recorder.onBuffer = nil
    commandDetector.stop()
    if wakeInitiatedSession, pipeline.canStopRecording { stopDictation() }
}
```

---

### S5 — `lastFire` / `recentSnippets` are "main-thread only" but `match` runs on main via `DispatchQueue.main.async` — OK — EXCEPT `fire()` re-entrancy through `onCommand` mutates state mid-iteration
**File:** `WhisperCommandDetector.swift:261–307`, `AppState.swift:349–351, 430, 434`

`match` → `fire` → `onCommand?(action)` (:306) is invoked **synchronously** on the main thread. For
`.start`, `onCommand` is `handleWakeCommand` which calls `commandDetector.stop()` (:430) then
`commandDetector.startRecording()` (:434) **synchronously, re-entering the detector from inside its own
`match`/`fire` stack.** `stop()` sets `isActive = false` and `startRecording()` resets utterance state —
all while we're still unwinding the `for command in VoiceCommands.keystroke` loop / switch in `match`.
With S1's fix moving flags onto the queue this is less explosive, but today `match` reads `isActive` at
:262 and then mutates the detector via the callback mid-method.

**Why it breaks operation:** reentrancy makes the start transition order-dependent and hard to reason
about; combined with S1/S2 it's a live-lock/tear source. Marked SHIP-NOW because it's on the primary
"Start Comet" path.

**Fix:** dispatch the command delivery async so `match` fully unwinds first:
```swift
private func fire(_ action: WakeAction, key: String) {
    ...
    lastFire[key] = now
    let cb = onCommand
    DispatchQueue.main.async { cb?(action) }   // break the reentrant stack
}
```

---

### S6 — `openUtterance` failure leaves `capturing == false` but a stale `utteranceURL`/temp file can leak; and finalize with `utteranceFile==nil` path
**File:** `WhisperCommandDetector.swift:180–192, 194–202, 218–234`

If `AVAudioFile(forWriting:)` throws (:184), `openUtterance` sets `utteranceFile = nil` but leaves
`utteranceURL`/`utteranceFormat` at their prior values (it only assigns them on success — actually it
never assigns URL on failure, so URL keeps the *previous* utterance's URL if any). Then in `handle`
(:172) `if utteranceFile != nil` guards starting capture — good, capture won't start. But `resetUtterance`
isn't called, so a subsequently-finalized-then-failed sequence can point `utteranceURL` at a file that was
already removed, or orphan a temp `.caf`. Low-severity leak individually, but the always-listening idle
loop opens a new file per utterance — over a 15-minute armed window that's potentially hundreds of temp
files if the disk/temp dir is failing.

**Why it breaks operation (mild):** temp-dir accumulation under a persistent write failure; and a
confused state machine after a transient file error. Not a crash.

**Fix:** on `openUtterance` failure, fully reset: `utteranceURL = nil; utteranceFormat = nil` (or call
`resetUtterance()`), and in `finalizeUtterance` you already guard `url`/`format` — fine. Cheap hardening.

**Severity note:** this is the weakest of the SHIP-NOW set — could be argued DEFER. I'm flagging it here
because it sits in the always-on idle loop where a failing temp dir compounds.

---

## DEFER (latent / cosmetic / needs-a-real-user-to-hit-rarely)

### D1 — `AudioRecorder.bufferMetrics` read after `removeTap` assumes no in-flight tap callback
**File:** `AudioRecorder.swift:110–125, 152–153`
`removeTap(onBus:)` guarantees no *future* callbacks but does NOT join a callback already executing on the
tap thread. `bufferMetrics.append` (:153) on the tap thread could theoretically race the main-thread read at
:122–125. Apple's removeTap is effectively synchronous w.r.t. the render thread in practice, so this is
latent. Fix: drain via `fileQueue.sync {}` (already done for the file) and move metric mutation onto that
queue too, or snapshot under the same barrier.

### D2 — Two AVAudioEngines can briefly coexist; no explicit audio-session arbitration
**File:** `AppState.swift:430–434`; both engine files.
On "Start Comet", `commandDetector.stop()` tears the idle engine, then `pipeline.startRecording` spins up the
recorder's engine — sequential, so no true double-open. But there's no ordering guarantee the idle engine's
`stop()` fully released the input device before the recorder grabs it; on some interfaces this yields a brief
`kAudioUnitErr_CannotDoInCurrentContext` start failure → `presentError`. Recoverable (user retries), so DEFER.
Consider a short retry on engine-start failure in the wake path.

### D3 — `debounce`/`recentSnippets` context window can drop a legitimately re-issued command
**File:** `WhisperCommandDetector.swift:46, 301–307`
2s debounce keyed per-command means saying "Comet stop" twice within 2s (latency-driven repeats — the very
thing `strippingTrailingPhrases` is built to handle) only fires once. That's intended for `stop`, but for a
keystroke like "Comet return, Comet return" (send two lines) the second is silently swallowed. Product call,
not a bug. DEFER.

### D4 — `scheduleWakeMaxDuration` fires `stopDictation()` but doesn't guarantee the detector re-arms to idle
**File:** `AppState.swift:469–478`
The max-duration task calls `stopDictation()`; re-arm to idle listening relies on `observePipeline` seeing the
phase return to idle (:617–626). If the pipeline errors instead of cleanly idling, the `.error` branch also
re-arms (:612 default? — actually `.error` is in the idle/done/error case) so it's covered. Verified OK, noting
for the record. No action.

### D5 — `LocalCLIRuntime.run` writes stdin without draining a full stdin pipe; large transcripts could block
**File:** `LocalCLIRuntime.swift:228–231`
`inPipe.fileHandleForWriting.write(data)` is a blocking write on the calling thread; for a transcript-sized
payload it's fine (well under pipe buffer), but a pathologically long dictation (many KB) could block if the
child doesn't read stdin. Current invocations pass `stdin: nil` (LocalCLILLM folds prompt into args), so this
path is dead today. DEFER / document.

### D6 — `shellEnvironment()` spawns `zsh -l -i` with no timeout
**File:** `LocalCLIRuntime.swift:111–132`
A misconfigured interactive shell (a `.zshrc` that prompts or hangs) blocks the first CLI cleanup call
indefinitely — `proc.waitUntilExit()` has no cap. Off the hands-free hot path (only when the user picks a CLI
LLM provider), so DEFER, but worth a timeout for the same "debuggable in 6 months" reason.

---

## Summary of the concurrency truth
The file-level comments assert queue-confinement and buffer-survival that the code does not actually
enforce (S1, S3). The feature works on a dev machine because the races are narrow and AVAudioEngine's
buffer reuse is lazy. Under real hands-free use — repeated arm/disarm, start/stop, a fast input device —
S1–S3 are the crash/corruption surface. S4/S5 are logic wedges on the primary path. Fix S1–S5 before ship;
S6 and the DEFER list are hardening.
