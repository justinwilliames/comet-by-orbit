# Nova UI/State Review — Comet Dictation
**Reviewer:** Nova (UI craft + state correctness)  
**Date:** 2026-07-03  
**Target:** `APIKeyField`, `ProvidersSettingsView`, `GeneralSettingsView`, `VoiceCommandsSettingsView`, `SettingsView`, `SettingsTab`, `MenuBarView`

---

## Priority order: SHIP-NOW first, DEFER below

---

## SHIP-NOW bugs

---

### BUG 1 — Eye button does "work" — but only reveals nothing (misleading UX, not a SwiftUI bug)
**File:** `Sources/UI/Components/APIKeyField.swift:38–53`

**Root cause analysis:**

The if/else inside `Group` is the classic SwiftUI identity trap — but whether it actually breaks in this code depends on SwiftUI's view tree reconciler. The concrete problem here is **not** that the toggle doesn't flip (it does: `isRevealed` is `@State` private, the button correctly calls `.toggle()`, and both fields bind to `$value`). The real problem is:

> `value` always starts **empty** (line 14: `@State private var value: String = ""`), and the `onAppear` (line 83–87) deliberately does **not** load the saved key into `value`. So when the user clicks the eye on a fresh open with no text typed, they reveal a blank TextField. They cannot tell whether "nothing is showing" means "no key saved" or "key is saved but the reveal isn't working."

**The secondary risk — SwiftUI identity swap:** when `isRevealed` flips, SwiftUI sees two different view types (`TextField` vs `SecureField`) in the same if/else branch inside a `Group`. On macOS Sonoma+ the reconciler usually handles this, but it can lose first-responder focus and, in rare cases, reset the field value if the views don't carry a stable `.id()`. Since `value` is `@State` (not a binding passed in), a reconciler identity miss would appear to clear what the user typed. This is latent — add `.id("apikey-\(key.rawValue)")` to both fields to guarantee identity stability.

**Why it breaks/misleads operation:**
- User has a stored key, opens Settings, clicks the eye, sees blank. Thinks reveal is broken. Files a support ticket or re-enters their key unnecessarily.
- Saves a new key mid-session, clicks eye to verify before navigating away — again sees blank (value was cleared on save, line 60).
- The eye button is a promise: "show me what's in there." It delivers silence. That's a broken promise whether or not the SwiftUI toggle fires.

**Severity:** SHIP-NOW (misleads users into thinking key management is broken; likely causes key re-entry and confusion)

**Concrete fix — two parts:**

**Part A: Stable identity (prevents any future reconciler-identity reset)**
```swift
// In APIKeyField body, replace the Group block:
Group {
    if isRevealed {
        TextField(placeholder, text: $value)
            .id("apikey-visible-\(key.rawValue)")
    } else {
        SecureField(placeholder, text: $value)
            .id("apikey-secure-\(key.rawValue)")
    }
}
```

**Part B: Make reveal meaningful when a key is stored (the actual UX fix)**

Load the saved key into `value` on reveal tap (not on appear — that was deliberately avoided to prevent mask bleed). Clear it again when the user cancels or navigates away.

```swift
// Replace the reveal Button:
Button {
    if !isRevealed, hasStoredKey, value.isEmpty {
        // Load from keychain only at reveal time — never at appear
        value = keychain.get(key) ?? ""
        isRevealedFromKeychain = true
    } else if isRevealed, isRevealedFromKeychain {
        // Re-conceal: clear the loaded value so it can't be accidentally saved
        value = ""
        isRevealedFromKeychain = false
    }
    isRevealed.toggle()
} label: {
    Image(systemName: isRevealed ? "eye.slash" : "eye")
}
.buttonStyle(.borderless)
// Add this @State:
// @State private var isRevealedFromKeychain: Bool = false
```

Then guard the Save button from accidentally re-saving the revealed-from-keychain value unchanged:

```swift
.disabled(trimmedValue.isEmpty || (isRevealedFromKeychain && trimmedValue == keychain.get(key)))
```

And on trash (line 71–79), also reset `isRevealedFromKeychain = false`.

**Alternative simpler fix** if loading the key into the field feels like too much surface area: hide the eye button entirely when `value.isEmpty && hasStoredKey`, replacing it with a static lock icon. This is honest ("a key is saved, you can't peek, type to replace") rather than a reveal that reveals nothing.

---

### BUG 2 — `hasStoredKey` / "Saved" badge goes stale across APIKeyField instances
**File:** `Sources/UI/Components/APIKeyField.swift:15–17, 83–87`

**Root cause:** `hasStoredKey` is `@State` set once in `.onAppear`. If the user saves a key in the **Groq** `APIKeyField` at the top of `ProvidersSettingsView` and then scrolls to the advanced section where a second `APIKeyField` for the same key may appear (or if another session writes to the keychain), the local `@State` never updates. Conversely, if the user saves a key and then immediately hits the trash button in a *different* `APIKeyField` referencing the same `KeychainKey`, the first field's badge still shows "Saved" until the view re-appears.

More critical: after hitting **Save**, `value` is cleared and `isSaved` is briefly `true` (the 2s flash), but `hasStoredKey` only shows "Saved" in the header badge — the user has **no persistent confirmation** if they navigate away before the 2s expires and return. The badge depends on `hasStoredKey = true` being in memory, but if SwiftUI recreates the view (e.g. scrolling the advanced DisclosureGroup closed and re-opening it), `onAppear` re-reads the keychain and gets `true` correctly. So this is tolerable for the close/open case but fragile for any cross-instance scenario.

**Severity:** SHIP-NOW for the cross-instance case if the same `KeychainKey` appears in multiple `APIKeyField` instances (it does: `.groqAPIKey` appears in the Recommended card AND potentially in the advanced STT card). **DEFER** for the single-instance in-session stale case.

**Fix:** Make `KeychainManager` post a `NotificationCenter` notification on `set`/`delete`, and have `APIKeyField.onAppear` register an observer:

```swift
// In KeychainManager.set():
NotificationCenter.default.post(name: .keychainDidChange, object: key.rawValue)

// In APIKeyField:
.onAppear { hasStoredKey = keychain.has(key) }
.onReceive(NotificationCenter.default.publisher(for: .keychainDidChange)) { note in
    if note.object as? String == key.rawValue {
        hasStoredKey = keychain.has(key)
    }
}
```

---

### BUG 3 — "Key configured" badge in ProvidersSettingsView doesn't update after saving/deleting a key without leaving the view
**File:** `Sources/UI/Settings/ProvidersSettingsView.swift:32–34`

**Root cause:** `groqKeyConfigured` (line 32) calls `appState.keychain.has(.groqAPIKey)` directly. `AppState` doesn't publish keychain changes — `KeychainManager` is a plain `final class`, not `ObservableObject`. So when `APIKeyField` saves a key (via `keychain.set()`), `AppState.objectWillChange` is never fired, and `ProvidersSettingsView` doesn't re-render. The "Key needed" → "Key configured" badge flip only happens on the next external re-render trigger (e.g. the user switches tabs and comes back, or another `@Published` property changes).

Same issue affects `isConfigured` in `ProviderConfigurationCard` (line 167, 205) and `isSelectedSTTConfigured`/`isSelectedLLMConfigured` in `AppState` (lines 211–217 in AppState.swift) — these all call through to `keychain.has()` synchronously and are only evaluated when `AppState` publishes.

**Severity:** SHIP-NOW — this is the primary reason provider cards look misconfigured after the user just set up their key. They have to leave and return to see the correct status.

**Fix:** Same `NotificationCenter` approach from BUG 2, OR have `APIKeyField` call a callback/closure that the parent (`ProvidersSettingsView`) can use to trigger `appState.objectWillChange.send()`. The cleanest production fix is the notification approach — one point of truth.

---

### BUG 4 — Wake word arm button shows "Listening" state but button can remain enabled when `wakeWordEnabled` flips to `false` mid-session
**File:** `Sources/UI/MenuBarView.swift:108–126`

**Root cause:** The arm button is shown only `if appState.wakeWordEnabled` (line 108). When `wakeWordEnabled` is toggled off from **Settings** (via `wakeWordEnabledChanged(to:)` in AppState), `disarmWakeWord()` correctly sets `wakeArmed = false` and `wakeArmed` is `@Published`, so the menu bar re-renders. The button itself correctly disappears because `if appState.wakeWordEnabled` gates its display. **This path is clean.**

The real bug is subtler: the arm/disarm button (line 112) is `.disabled(!appState.microphoneAccessGranted)` — but NOT disabled when `pipeline.canStopRecording` is true (i.e. a manual dictation session is in progress). A user can click "Listen for wake word" while recording is active. `armWakeWord()` in AppState has `guard wakeWordEnabled, !wakeArmed` but **no guard against `pipeline.canStopRecording`**. This means a user recording via the manual button can accidentally start the wake detector running concurrently, which sets `recorder.onBuffer` (a tap in the running recording stream), and the command detector will start trying to detect "Comet stop" inside an already-running manual session — potentially stopping it early via the `.stop` case in `handleWakeCommand` (line 441 — `guard wakeInitiatedSession` saves us here, but `wakeInitiatedSession` is only true for wake-started sessions, so the guard holds). However `commandDetector.startIdle()` still starts a parallel audio capture engine while the main recorder is running.

**Severity:** SHIP-NOW — add `pipeline.canStopRecording` to the disabled condition:

```swift
.disabled(!appState.microphoneAccessGranted || appState.pipeline.canStopRecording)
```

---

### BUG 5 — Save button label flashes "Saved" but field re-enables immediately on empty (not a 2-second lock)
**File:** `Sources/UI/Components/APIKeyField.swift:55–68`

After saving, `value` is set to `""` (line 60) and `isSaved` becomes `true`. The Save button label reads "Saved" but its `.disabled(trimmedValue.isEmpty)` evaluates `trimmedValue` on `value`, which is now `""` — so the button is **disabled** while reading "Saved". That's correct visually. But: `isSaved` resets after 2 seconds — at which point the button reads "Save" again and remains disabled (field is empty). So the 2s "Saved" flash is purely cosmetic and `isSaved` has no functional role beyond the label. This is not a bug per se, but the `isSaved` state is dead weight — the label could be driven by the `hasStoredKey` badge alone. Low priority — DEFER.

---

## DEFER findings

---

### DEFER A — `SettingsView.selectedTab` is a computed property using `nonmutating set`
**File:** `Sources/UI/Settings/SettingsView.swift:100–103`

`selectedTab` uses `@AppStorage("settings.selectedTab")` as the backing store via `selectedTabRaw`, with a computed property. The `nonmutating set` pattern works correctly in SwiftUI because `@AppStorage` is itself a property wrapper that triggers re-renders. No active bug — but `nonmutating set` on a struct member can confuse the compiler about mutation in some contexts. Worth knowing, low priority.

---

### DEFER B — `VoiceCommandsSettingsView` has no live state — it's a static reference page
**File:** `Sources/UI/Settings/VoiceCommandsSettingsView.swift`

No state bugs found. It reads `VoiceCommands.keystroke` (a static table) and `appState.wakeWordEnabled` (for the empty state). Clean.

---

### DEFER C — `GeneralSettingsView` `wakeWordCard` Toggle binding is wrapped but the `wakeWordEnabledChanged` path is correct
**File:** `Sources/UI/Settings/GeneralSettingsView.swift:156–158`

The custom `Binding` correctly routes through `appState.wakeWordEnabledChanged(to:)` which calls `disarmWakeWord()` if disabled. No bug. The toggle and the arm state stay consistent.

---

### DEFER D — `isSelectedLLMConfigured` can show "configured" for providers that use a local CLI tool
**File:** `Sources/App/AppState.swift:215–217`

`keychain.hasKeysFor(llm: selectedLLM)` returns `true` only if all `keychainKeys` are present. For `usesLocalCLI` providers, `keychainKeys` is likely empty, so `hasKeysFor` returns `allSatisfy { ... }` on an empty array = `true`. The provider row in MenuBarView shows a green ✓ for local CLI providers even before the CLI is actually installed. This is tolerable since local CLI providers don't need keychain keys, and the user sees the note text — but the green badge is semantically wrong. DEFER: add a specific `isConfigured` path for local CLI providers.

---

### DEFER E — Eye button icon doesn't animate the toggle (minor)
**File:** `Sources/UI/Components/APIKeyField.swift:48–52`

The image swap (`eye` ↔ `eye.slash`) has no transition. A `.animation(.easeInOut(duration: 0.15), value: isRevealed)` on the button image would make the affordance feel more intentional. Not a state bug — purely craft.

---

## Summary table

| # | Severity | File:Line | Description |
|---|---|---|---|
| 1 | SHIP-NOW | APIKeyField:38–53 | Eye reveals blank field — key never loaded into value; add stable `.id()` + load-on-reveal |
| 2 | SHIP-NOW | APIKeyField:15–17 | `hasStoredKey` stale across instances; add NotificationCenter observer |
| 3 | SHIP-NOW | ProvidersSettingsView:32 | Provider badges don't update after key save without tab switch |
| 4 | SHIP-NOW | MenuBarView:125 | Wake arm button not disabled during active recording |
| 5 | DEFER | APIKeyField:55–68 | `isSaved` state is dead weight — cosmetic only |
| A | DEFER | SettingsView:100 | `nonmutating set` pattern — works, worth noting |
| B | DEFER | VoiceCommandsSettingsView | Clean, no bugs |
| C | DEFER | GeneralSettingsView:156 | Wake toggle binding is correct |
| D | DEFER | AppState:215 | Local CLI providers show green badge without CLI installed |
| E | DEFER | APIKeyField:48 | Eye icon swap has no animation transition |
