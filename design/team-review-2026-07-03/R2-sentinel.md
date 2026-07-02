# R2 — Sentinel (Principal Engineer) — Verification of the cb8a0a9 remediation

Target: the post-fix `WhisperCommandDetector.swift` (full rewrite) + `AppState.swift` wake
wiring. Job: verify the 4 risky fixes are correct (no new races/regressions) and surface any
remaining ship-now bug. Verdicts are precise; reasoning shows the trace.

---

## VERDICT SUMMARY

| # | Area | Verdict |
|---|------|---------|
| 1 | Thread-safety / queue confinement | **PASS** |
| 2 | The deep copy (`commandDetectorCopy`) | **PASS — the copy is SAFE** |
| 3 | Session token + `transcribing` single-in-flight | **PASS** |
| 4 | Lifecycle (retain cycles / timers / callback-after-stop) | **PASS** |

New ship-now findings: **none.** One LOW correctness nit (N1) + two DEFER notes carried
forward. The loop has converged on the concurrency surface — this is a clean pass.

---

## 1 — THREAD-SAFETY — PASS

Traced every read/write of the queue-confined state (`isActive, mode, session, utterance*,
capturing, trailingSilence, transcribing, lastUploadAt, lastErrorSignalAt, lastFire,
recentSnippets`). All access is now genuinely on `queue`:

- **Writes to `isActive`/`mode`/`session`/utterance state** happen only inside `queue.async`
  blocks: `startIdle` (:84–89), `startRecording` (:96–101), `stop` (:111–115). The engine
  lifecycle (`startOwnEngine`/`stopEngine`) stays on the caller thread — correct; AVAudioEngine
  must NOT move onto the serial queue. Only the flags hop. This is exactly the S1 fix I asked for.
- **Audio-thread entry points** `feed`→`ingest` (:105, :155) and the tap closure (:129–131) do
  the deep copy on the audio thread, then `queue.async { self.handle(copy) }` (:157). `handle`
  (:160) reads `isActive`, `capturing`, `mode`, utterance state entirely on `queue`. No off-queue
  read remains. The old `guard isActive, mode == .recording` on the audio thread (R1-S1) is gone.
- **`transcribing`** is set true in `finalizeUtterance` (:258, on queue), reset to false only via
  `queue.async` in the `defer` of `transcribeAndMatch` (:266) and read on queue at :254. Confined.
- **`match`** (:291) runs via `queue.async` from `transcribeAndMatch` (:281) — reads `isActive`,
  `session`, `recentSnippets`, mutates `recentSnippets`/`lastFire` all on queue. Confined.
- **`lastErrorSignalAt`** read/written inside `signalTranscriptionError`'s `queue.async` (:341–344).

**Ordering of the S2 stale-buffer race** (engine stop on main vs. in-flight tap buffers on queue):
this is now handled by the **session token**, not by ordering. A tap buffer captured microseconds
before `removeTap` still deep-copies and lands on `queue` behind the `stop()`/`startRecording()`
`queue.async` blocks (serial FIFO). By the time that stale `handle` runs, `isActive`/`mode`/`session`
already reflect the new state. `handle` gates on `isActive` (:161); a stale idle buffer arriving
after `stop()` is dropped (isActive=false). A stale buffer arriving after `startRecording()` is
processed in `.recording` mode — but that's harmless: it can only ever open/extend an utterance that
is later matched, and the **match** is session-gated (:292) so a result derived from a superseded
session is dropped. The dangerous R1-S2 outcome (idle audio matched against stop phrases in the wrong
mode) is closed because `match` re-checks `session == self.session` at fire time. PASS.

One subtlety worth stating: `handle` itself does NOT re-check `session` (only `isActive`), so a
straggler buffer can still be *written into* the current utterance file. That is benign — it's a few
ms of real mic audio appended to a live capture in the correct current mode; it cannot cross a mode
boundary because finalize captures `mode`+`session` atomically on queue (:238–239) and match re-gates.
No fix needed.

---

## 2 — THE DEEP COPY — PASS. **The copy is SAFE.** (`commandDetectorCopy`, :378–392)

This is the one with history (an earlier audioBufferList-memcpy correlated with zero captured audio),
so I traced it byte-for-byte. It is correct this time. Reasoning:

1. **Order of operations is right.** `AVAudioPCMBuffer(pcmFormat:frameCapacity:)` constructs with
   `frameLength = 0`. The code sets `copy.frameLength = frameLength` (:382) **before** reading
   `destination[index].mDataByteSize` (:388). `mDataByteSize` in `mutableAudioBufferList` tracks the
   current `frameLength` (bytesPerFrame × frameLength), so after the assignment it reports the real
   payload size, not 0 and not garbage. **The prior zeroed-audio bug was almost certainly a copy that
   read `mDataByteSize` while `frameLength` was still 0 (→ copied 0 bytes → silence), or the separate
   0.012 threshold. This version sequences the assignment first, so it copies the true byte count.**
2. **Capacity == length here**, because it's constructed with `frameCapacity: frameLength`. So source
   and destination `mDataByteSize` are identical, and `min(src, dst)` (:388) is a belt-and-braces
   guard that changes nothing in the happy path but prevents any overrun if an SDK ever reports them
   differently. Safe.
3. **Interleaved vs. non-interleaved / mono / stereo / aggregate device** — all handled, because the
   copy iterates the `AudioBufferList` buffers (`source.count == destination.count`, :385) and memcpy's
   each `mData` blob by its own `mDataByteSize`. For non-interleaved stereo the list has 2 buffers
   (one per channel); for interleaved it has 1 buffer with both channels packed. Either way the raw
   per-buffer byte copy is faithful — it does not assume channel layout, sample type, or interleaving.
   This is strictly more correct than the R1-suggested `floatChannelData`-only copy, which would have
   mishandled interleaved or int16 buffers. Good call by the implementer.
4. **`format` is preserved** (`AVAudioPCMBuffer(pcmFormat: format, …)`), so `buffer.format.sampleRate`
   and the RMS `floatChannelData`/`int16ChannelData` reads downstream (:360, :365) see the same layout
   the bytes were copied under. Consistent.
5. **Failure modes are safe-nil:** frameLength 0 → nil (dropped); allocation fail → nil; count
   mismatch → nil; missing mData → nil. Every nil path just drops the buffer in `ingest` (:156) — no
   crash, no partial copy. Correct.

**One residual note (not a bug):** the copy reads `audioBufferList` (the *immutable* accessor) on the
source via `UnsafeMutablePointer(mutating:)` (:383). That's a read-only memcpy source, so const-casting
is fine — we never write through it. No aliasing hazard.

Bottom line: **this deep copy faithfully reproduces the audio; there is NO zeroed/garbled-buffer risk.**
If you want zero-doubt confidence, a one-time debug assert `copy RMS ≈ source RMS` on the first N
buffers would prove it in the field, but I'm satisfied from the trace. PASS.

---

## 3 — SESSION TOKEN + SINGLE-IN-FLIGHT — PASS

**Session guard prevents stale-mode fire:** `session &+= 1` on every start/stop (:87, :99, :113, all
on queue). `finalizeUtterance` snapshots `capturedSession = session` (:239) and threads it through
`transcribeAndMatch(session:)` → `match(session:)`, which gates `guard … session == self.session`
(:292). So a transcription that completes *after* the mode changed (user said "start", provider took
800ms, session already bumped) is dropped instead of firing a stop against the new session. Correct.
`mode` is likewise snapshotted at finalize (:238) and passed through, so match switches on the mode
that was live *when the utterance closed*, then the session gate ensures that mode is still current.

**Can `transcribing` leak true and permanently wedge commands?** I traced EVERY exit of
`transcribeAndMatch` (:263–287):
- Early `guard let transcribe else { return }` (:268) — returns, but the **`defer` at :264–267 still
  runs** and resets `transcribing = false`. Safe.
- `normalize` throws → `return` (:275) — `defer` runs. Safe.
- transcribe throws → falls through to `signalTranscriptionError()` then the function returns normally
  — `defer` runs. Safe.
- Success → `match` dispatched, function returns — `defer` runs. Safe.
- The inner `defer { removeItem(wavURL) }` (:277) is registered after the outer one, unwinds in LIFO —
  no interaction with the `transcribing` reset.

Because the reset lives in a top-level `defer`, there is **no early-return, throw, or await-cancellation
path that skips it.** The `Task {}` (:260) is unstructured but `transcribeAndMatch` is `async` with no
internal cancellation checks, and even task cancellation would still run the `defer` on the thrown
`CancellationError` unwind (the `await transcribe` is the only suspension point and its throw is caught).
`transcribing` cannot get stuck true. No permanent wedge. PASS.

**Cost guard intact:** `!transcribing && now - lastUploadAt >= minUploadInterval` (:254) still enforces
one upload in flight + 1s rate cap before setting `transcribing = true` (:258). The R1 cost bug (storm
the shared provider key) stays fixed.

---

## 4 — LIFECYCLE — PASS

- **Retain cycles:** every escaping closure that captures the owner uses `[weak self]` — tap closure
  (:129), `fire`→main hop (:337), `signalTranscriptionError`→main (:345), `emitUnavailable` (:352),
  and on the AppState side `onCommand`/`onUnavailable`/`onTranscriptionError`/`transcribe` (:353–369),
  `recorder.onBuffer` (:463), and the wake Tasks (:436, :491, :503). No strong self→closure→self loop.
  `transcribeAndMatch`'s `Task { await self.transcribeAndMatch(...) }` (:260) captures `self` strongly,
  but it's a bounded one-shot Task that completes (or throws) and releases — not a retained stored
  reference. Fine.
- **Timers/Tasks cancelled:** `wakeAutoDisarmTask`, `wakeMaxDurationTask`, `wakeIssueClearTask` are all
  `.cancel()`-ed before reassignment and in `disarmWakeWord` (:418–421). `wakeIssueClearTask` cancels
  on re-flag (:435). No orphaned timer keeps the mic or a callback alive.
- **Callback-after-stop:** the S4 orphan is fixed — `disarmWakeWord` now stops the live dictation if
  `wakeInitiatedSession && pipeline.canStopRecording` (:425–427) BEFORE niling `onBuffer` and calling
  `commandDetector.stop()`. The mic can't be left open headless. And `handleWakeCommand` guards
  `wakeArmed, wakeWordEnabled` at entry (:450), so a late `onCommand` delivered on main after a disarm
  is a no-op. `match`'s `isActive`+`session` gate stops a late transcription from firing a command into
  a torn-down detector. PASS.

---

## N1 — LOW (correctness nit, not ship-blocking): `disarmWakeWord` orders `stopDictation` before nil-ing the tee

**File:** `AppState.swift:425–429`

`disarmWakeWord` calls `stopDictation()` (:426) *before* `recorder.onBuffer = nil` (:428). `stopDictation`
drives the pipeline toward idle, which asynchronously trips `observePipeline`'s `.idle` branch (:644–658)
— which ALSO nils `onBuffer` and calls `commandDetector.stop()`/`startIdle()`. But `disarmWakeWord` has
already set `wakeArmed = false` (:422), and the `.idle` branch re-arms idle listening only `if
self.wakeArmed` (:655) — which is now false. So we do NOT accidentally re-arm after a disarm. Good — but
it's load-bearing on the ordering of those two writes. There's a benign double-`stop()` (once here :429,
once from observePipeline when the phase settles), which is idempotent (bumps session, discards utterance
twice). No functional bug; flagging only so a future edit doesn't reorder `wakeArmed = false` below
`stopDictation()` and silently resurrect idle listening on a disarm. **Recommend:** a one-line comment at
:422 noting `wakeArmed = false` must precede `stopDictation()` for exactly this reason. Optional.

---

## Carried-forward DEFERs (unchanged, still non-blocking)

- **D-recorder-metrics (was R1-D1):** `AudioRecorder.bufferMetrics.append` on the tap thread vs. main-read
  after `removeTap` — still latent, still fine in practice (removeTap is effectively render-synchronous).
  No change in cb8a0a9. DEFER.
- **D-engine-handoff (was R1-D2):** idle engine `stop()` → recorder engine `start()` device-release race
  on some aggregate/interface devices → possible transient start failure → `presentError`, recoverable.
  DEFER; a short retry on wake-path engine start would harden it.
- **D5/D6 (LocalCLIRuntime stdin/shell timeout):** off the hands-free path entirely, untouched, DEFER.

---

## Bottom line

All four risky fixes verify correct. The deep copy — the one with a zeroing history — is **safe**: the
`frameLength`-before-`mDataByteSize` ordering is exactly what prevents the old silent-buffer bug, and the
per-audio-buffer raw memcpy is more format-robust than my R1 suggestion. Thread confinement is genuine,
the session token closes the wrong-mode fire, `transcribing` cannot leak (reset lives in a top-level
`defer`), and the S4 orphaned-recording wedge is closed. No new ship-now bug introduced. N1 is a
comment-worthy ordering dependency, not a defect.

**This is a clean pass. The concurrency loop has converged — ship it.**
