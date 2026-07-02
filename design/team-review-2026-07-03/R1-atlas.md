# Atlas UX Review — Comet Voice Commands
**Reviewer:** Atlas (Senior UX Designer)  
**Date:** 2026-07-03  
**Scope:** Hands-free wake word flow — arm/disarm, command detection, failure states, permission UX

---

## SHIP-NOW findings (blocks or wedges real-world use)

---

### F1 — Transcription failure on command snippets is completely silent
**Severity:** SHIP-NOW

**What happens:** `transcribeCommandSnippet` returns `""` if `registry.makeSTTProvider` returns `nil` (no provider registered), if the API key is invalid, if the network is down, or if the provider returns a 429/5xx. The `WhisperCommandDetector.transcribeAndMatch` method swallows the error in a `logger.error` call only — no user-visible signal. The user says "Comet start dictation" and nothing happens. They repeat themselves. They check nothing, because nothing changed.

**Why it breaks real use:** This is the exact failure mode the user already experienced (repeating commands with no response). The feature becomes a black box. There is no way for the user to distinguish "command not recognized" from "transcription is broken."

**Concrete fix:**

In `WhisperCommandDetector.transcribeAndMatch`, change the catch block to call a new `onTranscriptionError` closure alongside the existing logger call:

```swift
// In WhisperCommandDetector — add alongside onCommand/onUnavailable:
var onTranscriptionError: ((Error) -> Void)?

// In transcribeAndMatch, replace:
} catch {
    logger.error("Snippet transcription failed: \(error.localizedDescription, privacy: .public)")
    return
}

// With:
} catch {
    logger.error("Snippet transcription failed: \(error.localizedDescription, privacy: .public)")
    DispatchQueue.main.async { [weak self] in self?.onTranscriptionError?(error) }
    return
}
```

In `AppState.setupWakeWord`, wire the closure to surface a non-fatal inline signal. Because `pipeline.presentError` would disarm by triggering the `onUnavailable` path and displaying a blocking overlay error, use a lighter signal instead — for example, a transient status update on the wake button label or a brief menu-bar icon badge. A minimal implementation:

```swift
commandDetector.onTranscriptionError = { [weak self] error in
    guard let self else { return }
    // Log for diagnostics; flash the menu bar icon with a brief amber state
    // or surface a non-modal notification. Do NOT disarm — the user may
    // recover (network blip) without needing to re-arm.
    // Minimum viable: post an NSUserNotification / UNUserNotificationCenter
    // alert titled "Wake word: transcription error" with the provider name
    // and a "Check Providers" action that opens settings.
}
```

A one-line approach that requires no new UI: set the menu bar icon to a "warning" state for 3 seconds using `DockIconController` or the existing menu bar status item.

---

### F2 — Arm state has no persistent ambient signal; auto-disarm at 15min is invisible
**Severity:** SHIP-NOW

**What happens:** When armed, the only indicator is the menu bar button label inside the popover ("Listening — say 'Comet start'…") and the macOS system mic indicator dot (top-right of menu bar). The system mic dot appears because `AVAudioEngine` holds the mic — but it is not labeled, and users who don't know Comet is armed may dismiss it as something else. There is zero signal when the armed window expires after 15 minutes.

**Why it breaks real use:** The user arms Comet, gets distracted, comes back 16 minutes later, says "Comet start dictation", nothing happens. They don't know it disarmed. They have to open the menu bar popover to find out. The mental model of "it's always listening until I tell it to stop" leads to surprised non-responses.

**Concrete fix — two parts:**

1. **Menu bar icon state for armed:** When `wakeArmed` flips to `true`, change the menu bar `NSStatusItem` image to a distinct "armed" variant (e.g., the existing Comet mark with a small waveform badge or a tinted/animated variant). This is the most discoverable persistent signal because the menu bar icon is always visible. The app already has `DockIconController` — apply the same pattern to the status item image. One additional `NSImage` asset is all that's required.

2. **Auto-disarm notification:** In `AppState.scheduleWakeAutoDisarm`, before calling `disarmWakeWord()`, post a local `UNUserNotificationCenter` notification: "Comet disarmed — 15 minutes idle. Tap to re-arm." This surfaces in Notification Center and the screen corner, and requires no new UI code beyond the notification post.

```swift
// In scheduleWakeAutoDisarm, before self?.disarmWakeWord():
let content = UNMutableNotificationContent()
content.title = "Comet disarmed"
content.body = "15 minutes of inactivity. Open Comet to re-arm."
let request = UNNotificationRequest(identifier: "comet.disarm", content: content, trigger: nil)
UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
```

---

### F3 — STT provider unconfigured while armed: commands silently never fire
**Severity:** SHIP-NOW

**What happens:** The wake word feature can be enabled and armed even when `isSelectedSTTConfigured` is `false` (e.g., user picks Groq but hasn't added the API key). `transcribeCommandSnippet` returns `""` because `registry.makeSTTProvider` returns `nil`. Commands never fire. The arm button does not warn about this.

**Why it breaks real use:** The user enables the wake word, arms it, speaks commands, nothing happens. The menu bar shows "Listening" but the feature is broken. They have no idea the issue is a missing API key — they think the voice recognition is just bad.

**Concrete fix:**

In `AppState.armWakeWord`, add a guard before `commandDetector.startIdle()`:

```swift
func armWakeWord() {
    guard wakeWordEnabled, !wakeArmed else { return }
    guard microphoneAccessGranted else {
        pipeline.presentError("Microphone access is required for the wake word.")
        return
    }
    // ADD THIS:
    guard isSelectedSTTConfigured else {
        pipeline.presentError("\(selectedSTT.displayName) is not configured. Add its API key in Settings → Providers to use the wake word.")
        return
    }
    // ...rest
}
```

This surfaces the error at arm time via the existing overlay error path, which is appropriate — it's a configuration error, not a transient failure.

---

### F4 — Keystroke commands fire into the wrong app with no guard and no undo path
**Severity:** SHIP-NOW

**What happens:** Keystroke commands (Select All, Delete Word, Delete Line, etc.) fire `TextInjector.pressKey` into whatever app is focused at that moment — which may not be the app the user just dictated into. If the user says "Comet select all" while a file browser, terminal, or IDE is focused (because focus shifted between the dictation stop and the voice command), the destructive action hits the wrong target. "Comet undo" is listed as the recovery, but it only works if the focused app is the one that received the command.

**Why it breaks real use:** Delete Word / Delete Line in a terminal or code editor can silently delete irreplaceable content. Select All in a file browser selects all files. These are not recoverable situations. The 2-second debounce prevents re-fire but doesn't guard the wrong-app case at all.

**Concrete fix (two-part):**

1. **Destructive command confirmation delay:** For commands where `isDestructive == true`, add a 1.5-second delay before `TextInjector.pressKey` fires, with a cancellation toast or overlay that reads "Deleting word in 1.5s — say 'Comet cancel' or press Esc". This is the pattern voice assistants use for destructive actions and it's achievable by wrapping the keystroke dispatch in a Task with `.sleep`.

2. **"Comet cancel" as a first-class phrase in the command table:** `VoiceCommands.keystroke` already has an Escape command (`id: "escape"`), but its actions are `["escape", "cancel"]`. "Comet cancel" currently fires `CGKeyCode 0x35` (Esc key), which may or may not cancel a pending destructive action depending on the app. The safer model: before any destructive keystroke fires, check if a destructive command is pending and surface a brief overlay. Add "cancel that" alongside "escape" as an action that aborts the pending destructive Task rather than sending Esc.

For the minimum ship-now fix: just add the 1.5-second delay + cancellable overlay for destructive commands only.

---

### F5 — First-run permission ordering: microphone prompt fires before user understands why
**Severity:** SHIP-NOW

**What happens:** On first launch, `setupWakeWord` and `armWakeWord` both call `commandDetector.startIdle()` which calls `startOwnEngine()` which calls `engine.start()`. If the user enables the wake word toggle in settings before completing the setup guide (which only requires mic + accessibility to show as "complete"), the AVAudioEngine start triggers the macOS microphone permission prompt with no Comet-branded context — the user sees a generic "Comet would like to access the microphone" dialog with no explanation that this is for the wake word feature.

The accessibility permission dialog also fires without a clear explanation of why it's needed (the setup guide mentions it, but the first-run sequence can reach the dialog before the user has read that).

**Why it breaks real use:** Users who deny microphone access at this prompt because they don't understand the context are permanently stuck — re-requesting requires going to System Settings. The feature is broken for them from first launch.

**Concrete fix:**

In `GeneralSettingsView.wakeWordCard`, wrap the `Toggle("Enable wake word")` in a check: if `!microphoneAccessGranted`, disable the toggle and show a one-line inline note:

```swift
Toggle("Enable wake word", isOn: ...)
    .disabled(!appState.microphoneAccessGranted)

if !appState.microphoneAccessGranted {
    Text("Grant microphone access first (above) to enable the wake word.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

This prevents the user from reaching the wake word feature before granting mic access, which eliminates the context-free permission prompt.

---

## DEFER findings (real pain, not blocking ship)

---

### D1 — No feedback when a command phrase mishears
**Severity:** DEFER

**What happens:** When a snippet is transcribed but doesn't match any phrase (e.g., "comment start" hits the keyword list but no action matches, or the normalized text is "comet stir" which doesn't match any start action), the `match` function returns silently. The user hears nothing, sees nothing, and has no idea whether Comet heard them at all or just didn't understand.

**Why it's real pain:** The real-world recovery loop is: say it → wait 1-4 seconds for transcription → nothing happens → say it again, louder → same outcome. The user has no signal to distinguish "heard but misunderstood" from "didn't hear at all."

**Proposed fix:** Log the `snippet heard` text (already in `logger.info`) and optionally surface it transiently — e.g., a 1-second tooltip on the menu bar icon showing "Heard: 'comment stir'" to help users understand what the recognizer captured. This does not require new UI infrastructure; it can use the existing `NSStatusItem` tooltip or a tiny HUD overlay.

---

### D2 — Keystroke commands fire while wake word is armed and a different app is in a sensitive state
**Severity:** DEFER

**What happens:** The code guards that keystroke commands only fire while `pipeline.canStartRecording` (i.e., not mid-recording). But "idle" includes states like: a file upload dialog is open, a password field is focused, a fullscreen game is running. There's no check for focused app identity or window type.

**Why it's real pain:** Difficult to fix without app-focus heuristics, which are fragile. The F4 fix (destructive delay) addresses the worst subset. Full app-context awareness is out of scope for v1.

---

### D3 — Auto-disarm timer resets on ANY activity including keystroke commands, not just voice
**Severity:** DEFER

**What happens:** `scheduleWakeAutoDisarm()` is called inside `handleWakeCommand` for all action types including `.keystroke`. This means keystroke commands reset the 15-minute idle timer, which is correct behavior. However, the timer is a Task that runs on wall-clock time and doesn't account for the machine sleeping (Task.sleep is suspended during sleep). After a lid-close/open cycle, the timer fires immediately on wake if the elapsed wall time exceeds 15 minutes, even if the user just sat down at their desk expecting Comet to still be armed.

**Proposed fix:** Replace the `Task.sleep` approach with a `Date`-based deadline — store `wakeDisarmDeadline = Date().addingTimeInterval(wakeAutoDisarmInterval)` and check it on app-foreground events (already observed via `NSWorkspace.didActivateApplicationNotification`). This is a minor refactor.

---

### D4 — "Comet undo" is not surfaced as the recovery phrase immediately after a destructive command
**Severity:** DEFER

**What happens:** The Voice Commands settings page mentions "Undo that" reverses misfires in its card description, but this is only visible inside Settings → Voice Commands. After a destructive command fires, there's no in-flow reminder that "Comet undo" is available as the immediate next step.

**Proposed fix:** After a destructive keystroke fires, show a 2-second transient overlay or tooltip that reads "Done — say 'Comet undo' to reverse." This pairs with the destructive delay added in F4.

---

### D5 — No accent/mishear tuning visible to the user; bias vocabulary is hardcoded
**Severity:** DEFER

**What happens:** `VoiceCommands.biasVocabulary` and `VoiceCommands.keywords` (including mishears like "comment", "komet", "commit") are hardcoded. Users with accents that produce consistent alternative transcriptions (e.g., "Comet" → "Karma" for some Australian accents) cannot add their own keyword variant without a code change. The existing `customVocabulary` system for dictation does not extend to command recognition.

**Proposed fix:** Add a "Custom command keyword" text field in the Voice Commands settings tab that prepends the user's variant to `VoiceCommands.keywords` at runtime. One `@AppStorage` key and a runtime merge in `VoiceCommands` or `WhisperCommandDetector.match`. Scope is small.

---

### D6 — Wake word card in settings mentions the 15-minute idle disarm but not the 3-minute recording cap
**Severity:** DEFER

**What happens:** `GeneralSettingsView.wakeWordCard` reads: "Listening auto-disarms after 15 minutes idle (a recording also hard-stops after 3 minutes if the stop phrase is missed)." This is accurate. However, there is no signal when the 3-minute recording cap fires — the pipeline stops and transitions to transcribing, but the user is not told "your recording was auto-stopped." This looks like a normal stop and they may not realize their full dictation was captured vs. truncated.

**Proposed fix:** When `wakeMaxDurationTask` fires in `AppState.scheduleWakeMaxDuration`, set a flag and surface a toast or append a note to the pipeline result: "Recording auto-stopped after 3 minutes." Minimal — one boolean flag and one additional line in the done/result UI.

---

## Summary table

| ID | Finding | Severity |
|----|---------|----------|
| F1 | Transcription failure on command snippets is completely silent | SHIP-NOW |
| F2 | No persistent armed-state indicator; auto-disarm fires invisibly | SHIP-NOW |
| F3 | Wake word arms with unconfigured STT provider, silently broken | SHIP-NOW |
| F4 | Destructive keystroke commands have no guard, no undo prompt | SHIP-NOW |
| F5 | First-run mic prompt fires without context when enabling wake word | SHIP-NOW |
| D1 | Mishear/no-match produces zero user feedback | DEFER |
| D2 | Keystroke commands unaware of focused app type | DEFER |
| D3 | Auto-disarm timer doesn't account for machine sleep | DEFER |
| D4 | "Comet undo" not surfaced after destructive command fires | DEFER |
| D5 | Bias vocabulary not user-configurable for accent variants | DEFER |
| D6 | 3-min recording cap fires without any user notification | DEFER |

---

*Atlas — "What's the user actually trying to do here?" They're trying to stay in flow. Every silent failure breaks that contract.*
