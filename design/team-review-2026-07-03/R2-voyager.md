# R2 — Voyager (Data / Backend / Pipeline Integrity)

Target: verify the Round-1 cost/rate/data/privacy fixes on the hands-free command path (remediation commit `cb8a0a9`) and hunt any remaining ship-now data/provider/audio bug.

**Verdict: the R1 blockers are fixed and effective. Cost IS bounded now** (hard ceiling 60 uploads/min/user, realistic ~30–50). Temp-file leak is closed on every traced path. The `transcribing` flag cannot wedge. Privacy logs are clean. 429/timeout now reaches the user (debounced). One residual concern (onset threshold 0.006) is a *tunable*, not a blocker — quantified below with a recommendation. **Loop converges from a data/backend standpoint.**

---

## VERIFICATION — PASS/FAIL per point

### 1. RATE / COST — **PASS (bounded)**
Mechanism (`WhisperCommandDetector.swift:250-260`): before spawning the transcription `Task`, `finalizeUtterance` enforces `!transcribing && now.timeIntervalSince(lastUploadAt) >= minUploadInterval` (1.0s). `transcribing` is set true here and reset in `transcribeAndMatch`'s `defer` (:264-267); `lastUploadAt = now` is stamped at upload *start*.

**Worst-case uploads/min:** hard ceiling **60/min** (one per 1.0s interval). But single-in-flight adds a second brake — the next upload cannot start until the current round-trip returns (`transcribing` stays true across the `await`). With typical cloud-Whisper latency 0.5–1.5s, effective steady-state is **~30–50 uploads/min** in a continuously-talky room, ceilinged at 60. That is acceptable: it's the same order as one active dictation session, on a window that auto-disarms after 15 min (`AppState.swift:58`, verified `scheduleWakeAutoDisarm` :489-497 actually fires `disarmWakeWord`). **No unbounded storm, no self-DoS of the shared Groq key** — the command path can now emit at most ~1 req/s, well under Groq's limits, leaving foreground dictation headroom.

**Does dropping in-flight snippets ever drop a REAL command?** Yes — possible but acceptable. If the user speaks "Comet copy" while a *previous* snippet's transcription is still in flight (or within the 1s interval), that utterance is dropped at :254-257. Mitigating factors: (a) commands are short and users pause after the wake word — the rolling 4s context window (`contextWindow`, :78) + `recentSnippets` stitching means a dropped fragment can still be re-heard on the next snippet; (b) the debounce is per-command, not global, so a genuine command spoken into a quiet moment (the normal case) sees `transcribing=false` and fires. The drop only bites when the room is *already* saturating the uploader — exactly when you want to shed load. **Correct trade-off.** Not a blocker.

**onsetThreshold 0.006 — still low, but NOT a ship blocker.** It still admits ambient noise above the ~0.003 silence floor, so a talky room will still *open* utterances on non-speech. BUT the R1 cost blowout is now capped downstream by the rate/in-flight gate, so the blast radius is "up to 60 mostly-garbage uploads/min" rather than "unbounded." Weighing regressing detection (Justin just got reliability at 0.006) vs cost: **keep 0.006 for now.** If you want a cheap, detection-safe tightening later, add a *cumulative-voiced-frames* test inside the utterance (count frames where `rms >= onsetThreshold`, require ≥0.25s voiced before allowing finalize→upload) rather than raising the onset — that culls single-transient blips (cough, click) without touching quiet-speech sensitivity. Queue it; don't gate ship on it.

### 2. TEMP-FILE LEAKS — **PASS (no orphans on any traced path)**
Traced every exit of `finalizeUtterance` + `transcribeAndMatch`:
- **duration < min** (:245-248): `removeItem(url)` then return. Clean.
- **drop: in-flight / interval** (:254-257): `removeItem(url)` then return. Clean.
- **spawn Task** (:258-260): `url` handed to `transcribeAndMatch`, whose **outer `defer` (:264-266) removes `url` unconditionally** + resets flag. Registered as the first statement, before any `await`, so it runs on *every* return below it.
- **normalize throws** (:272-276): returns after outer defer registered → `url` removed. `wavURL` never created, nothing to leak. Clean.
- **transcribe throws** (:280-286): inner `defer` (:277) removes `wavURL`, outer removes `url`. Clean.
- **success** (:280-281): both defers run on scope exit. Clean.
- **openUtterance throws** (:198-207): `removeItem(url)` in the catch, all state nilled. Clean.
- **stop()/disarm mid-utterance** (:109-116 → `discardUtterance` :229-231): removes `utteranceURL` if set. Clean.

**Only residual (unchanged from R1 #6, still DEFER):** hard force-quit while a `.caf`/`.wav` is mid-flight leaves that one file in `temporaryDirectory` — OS-level, not a logic leak, and now at most a handful of files (rate cap ⇒ ≤1 in-flight + ≤1 opening). A launch-time sweep of stale app-owned temp files is still the clean fix but is not ship-blocking.

### 3. `transcribing` FLAG WEDGE — **PASS (cannot leak true)**
The flag is set true at exactly one site (:258), immediately before `Task { await transcribeAndMatch(...) }`. `transcribeAndMatch`'s `defer { queue.async { self.transcribing = false } }` (:264-267) is the first statement in the function body, so it registers before the first `await` and runs on **every** return path (early `guard let transcribe else` :268, normalize-throw, transcribe-throw, success). `Task{}` is always scheduled by the runtime, so the body always runs. There is no `throw` between setting the flag and spawning the Task. **No wedge path from the data side.** (Concurrency-model wedge — e.g. queue starvation — defer to Sentinel, but the reset is correctly re-hopped onto `queue` so it's serialized against the set. Clean.)

### 4. PRIVACY / LOGS — **PASS (no content at .public)**
Grepped the whole `Sources/` tree for `privacy: .public`. Every remaining `.public` is non-content diagnostics: status codes, durations, provider IDs, endpoint URLs, sample rates, channel counts, command *keys* (`WhisperCommandDetector.swift:334` logs the matched key like "start", not the transcript), file-open error descriptions, and **word-count ratios** (`DictationPipeline.swift:487` — counts/ratios, no text). Specifically confirmed the R1 gaps are closed:
- `WhisperCommandDetector.swift:284` — transcription failure now logs `"Snippet transcription failed"` with **no transcript interpolation** (R1 #4 site, was :267). Fixed.
- `DictationPipeline.swift:403` — LLM raw preview now `privacy: .private`. Fixed.
No transcript / bystander-speech / LLM-output content survives at `.public` anywhere. **PASS.**

### 5. 429 / ERROR HONESTY — **PASS (fires, debounced)**
Traced end to end: on HTTP 429, `ProviderHTTPClient` returns a response with `errorMessage` set and `statusCode` outside 200–299. `GroqWhisperSTT.swift:77-82` sees `!(200...299).contains(statusCode)` → **throws** `STTError.apiError(statusCode: 429)` (timeout path :91 throws `STTError.timeout` likewise). That propagates through the injected `transcribe(wavURL)` closure into `transcribeAndMatch`'s `catch` (:282-286) → `signalTranscriptionError()` (:340-349), which is debounced at 20s (`errorSignalInterval`) and fires `onTranscriptionError` on main. `AppState.setupWakeWord` (:363-365) wires that to `flagWakeIssue` (:433-441), surfacing a non-fatal 6s-auto-clearing toast *without* disarming. **The user now learns the provider is unreachable/rate-limited instead of the feature silently dying.** PASS. (Same wiring also closes R1 DEFER #5 — arming is now gated on `isSelectedSTTConfigured` at `AppState.swift:406-409, 215-217`, so "armed with no key" is caught up front.)

---

## RESIDUAL FINDINGS

**No NEW ship-now data/provider/audio bug found.** The three DEFER items carry over unchanged, none ship-blocking:

- **[DEFER] Force-quit temp-file remnant** — launch-time sweep of stale app-owned `.caf`/`.wav` in `temporaryDirectory`. Blast radius now tiny (rate cap). `WhisperCommandDetector.swift` / app launch.
- **[DEFER] onsetThreshold 0.006 admits ambient noise** — cost now capped downstream; if tightening later, add a cumulative-voiced-frames gate inside the utterance rather than raising the onset (preserves quiet-speech detection). `WhisperCommandDetector.swift:45,160-188`.
- **[DEFER] Aggregate/virtual-device normalize failure is silent** — `AudioNormalization` throws honestly and the snippet is dropped; add a one-time toast so "commands don't work on my Aggregate Device" is diagnosable. Not a correctness bug.

---

## CONVERGENCE CALL
**Cost IS bounded now.** Hard ceiling 60 uploads/min/user, realistically ~30–50 under continuous chatter, single-in-flight + 1s-interval enforced, 15-min auto-disarm confirmed to fire, shared-key self-DoS eliminated, 429/timeout surfaced honestly, temp files clean on every path, no PII at `.public`. All four R1 SHIP-NOW blockers verified fixed and effective. From the data/backend/pipeline lens, **this converges — clean to ship.** Remaining items are DEFER polish, not gates.
