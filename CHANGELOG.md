# Changelog

## [0.2.18] — 2026-05-01

### Fixed

* **Fillers are now actually removed.** Sir reported that after switching to Anthropic Haiku 4.5, fillers ("um", "uh", "you know") were being preserved instead of stripped. Audit found three structural issues in the prompt: (1) zero concrete examples demonstrated filler removal — the rule was stated but unanchored, so smaller models had no positive pattern to follow; (2) the CLEANUP rule said *"Remove fillers… unless intentional"* — the hedge gave the model an out it shouldn't have; (3) the NEVER bullet led with *"Compress, abbreviate, or summarise. Keep every content word"* and only mentioned the filler carve-out mid-paragraph, so the dominant signal Haiku picked up was preservation. Three changes: (a) added two filler-removal examples to the EXAMPLES section, (b) replaced the "unless intentional" hedge with explicit "required, not optional" framing in CLEANUP, (c) restructured the NEVER bullet to lead with the filler carve-out before the broad prohibition. Same fixes applied to the simplified prompt used on the Groq 8B fallback.

## [0.2.17] — 2026-05-01

### Changed

* **Learn-from-edits is more permissive and observable.** The vocabulary-learning toast was firing far less often than the toggle's description implied. Three changes: (1) `pastedStillPresent` threshold dropped from 60% to 40%, so a 2-word edit on a 4-word transcript no longer trips the "user wiped the field" guard; (2) the toast auto-dismiss bumped from 15s to 45s so it isn't gone before you context-switch back; (3) every reconcile bail point now logs at `info` level under `subsystem == "team.yourorbit.OrbitDictation" AND category == "Learning"`, naming the exact reason — so when it doesn't fire you can see whether the app didn't expose its AX value, you switched apps, the snapshot went stale, or the diff produced no paired substitutions. Several apps (Electron, certain web fields) silently fail to expose `AXValue` and learn-from-edits can't reach into those — that's an OS-level limit, now visible in the logs.

## [0.2.16] — 2026-05-01

### Changed

* **Groq 8B fallback now uses a simplified prompt.** When the Groq 70B model rate-limits and the pipeline falls back to `llama-3.1-8b-instant`, the system prompt is swapped from the full ~1,400-token cleanup contract to a tight ~250-token version (`Prompts.simplifiedCleanup`) with three few-shot examples and structured `<output>` tags. Small models can't reliably hold the full prompt's rule set in attention — they pattern-match conversation cues, refuse, wrap output in framing, or drop content. The simplified prompt anchors them on the transformation task. Sir's custom prompt + tone-of-voice overrides are not applied on the 8B path; the v0.2.15 compression and framing guardrails catch any remaining failures.

## [0.2.15] — 2026-05-01

### Fixed

* **Settings reopen, the actual fix.** v0.2.14's diagnostic logs proved the real bug: `NSApp.delegate as? AppDelegate` returns nil at runtime on macOS Sequoia even though AppDelegate's methods are clearly running. SwiftUI's `@NSApplicationDelegateAdaptor` wraps the user delegate in a private class, defeating the cast. Replaced with an `AppDelegate.shared` singleton set in `init()`. Direct path now works; the NotificationCenter fallback added in v0.2.12 stays as a defensive safety net but should never fire.
* **Reject weak-fallback-model garbage output.** Two new guardrails in `DictationPipeline` mirror the existing expansion guardrail. *Compression*: when the raw transcript is ≥10 words and the cleaned output is under half that length (e.g. 47-word input → 12-word reply), use raw instead. *Framing/refusal*: when the cleaned output starts with phrases like "I've cleaned the input. Here is…", "I don't have the ability…", "It's asking you, not me", "I cannot…", "as an AI…", etc., use raw instead. Both fire mostly when Groq's free-tier daily token cap is hit and dictation falls back to `llama-3.1-8b-instant`, which is too weak to follow the cleanup contract.

### Changed

* **Anthropic provider: prompt caching enabled, default model = Haiku 4.5.** The ~1,400-token cleanup prompt is now sent with `cache_control: { type: "ephemeral" }` — Anthropic caches it server-side for 5 minutes and discounts cached tokens 90%. Combined with switching the default model from Sonnet 4 to Haiku 4.5, the structural answer to Sir's Groq rate-limit problem is "use Anthropic Haiku" — no daily token caps that bite an active dictation user, faster than the Groq fallback path on average, and effectively free at this prompt size. Existing users who explicitly chose a different model keep their selection.

## [0.2.14] — 2026-05-01

### Added

* **Tone of Voice section in Prompts settings.** New text field where users describe how their dictated text should sound when it comes back — e.g. "Casual, dry, never use exclamation marks. Australian spellings." The instructions are appended as a `TONE OF VOICE` section after whichever cleanup prompt is active (default or custom override), so they compose with the rules-level prompt without forcing users to copy/edit the whole default to add a tone paragraph. Stored under `customToneInstructions` in UserDefaults; picked up at the start of every dictation via `syncPipelineConfig`.

## [0.2.13] — 2026-05-01

### Changed

* **New start/finish chime.** Replaced the system "Tink" boop at recording start with a custom chime sourced from Orion Desktop Companion's ping set (`Resources/dictation-chime.mp3`, originally `ping-bb`). The same chime now also plays when the transcript has been pasted into the focused text field — so each dictation cycle is bookended by the same sound. The intermediate "Pop" at recording-stop and "Bottle" at no-speech are unchanged.

## [0.2.12] — 2026-05-01

### Fixed

* **Settings reopen, attempt 3.** v0.2.11 still didn't fully resolve the popover-driven Settings open path. Three changes here: (1) reordered popover-open code so the Settings window is created and `makeKeyAndOrderFront`'d *before* the popover dismiss animation runs — previously `NSApp.activate(ignoringOtherApps:)` was racing against an animating popover and getting swallowed; (2) added a NotificationCenter fallback path in `MenuBarView` so that even if `NSApp.delegate as? AppDelegate` ever returns nil, the open call still routes through the AppDelegate observer; (3) added per-tap diagnostic logs at `subsystem == "team.yourorbit.OrbitDictation" AND category == "MenuBarView"` so a regression here is debuggable from Console.app without an Xcode attach.

## [0.2.11] — 2026-05-01

### Fixed

* **Settings reopens reliably after close (round 2).** Even with the AppKit `NSWindowController` conversion in v0.2.9, Sir reported Settings still wouldn't reopen after the first close. Root cause: `NSHostingController`-backed `NSWindow`s on macOS Sequoia don't reliably re-show after `orderOut`/close — `makeKeyAndOrderFront` on a hidden window silently no-ops. Fix: when `showSettings` finds the previous window non-visible, it drops the stale `SettingsWindowController` and instantiates a fresh one. Same pattern for About. Adds diagnostic logging so future regressions in this path can be confirmed via Console.app filter `subsystem == "team.yourorbit.OrbitDictation" AND category == "AppDelegate"`.

## [0.2.10] — 2026-05-01

### Changed

* **Sparkle auto-update is now ON by default.** Added `SUEnableAutomaticChecks = true` and `SUScheduledCheckInterval = 1800` (30 min) to Info.plist, mirroring Orion. Without these, Sparkle pops a "check for updates automatically?" prompt on first launch and a user can accidentally opt out and never see another update; the 24h default also leaves Sparkle perpetually one release behind during active iteration. The user-driven "Check for Updates…" entry in the popover footer and the post-update Gatekeeper xattr dialog were already in place — this change just makes the auto-prompt path reliable.

## [0.2.9] — 2026-05-01

### Fixed

* **Settings reopens reliably from the menu-bar popover.** After first close, SwiftUI's `Window(id: "settings")` scene went into a stale state — `openWindow` and `comet://settings` URL routing both stopped firing, and "Open Settings" from the popover did nothing. Replaced the SwiftUI Settings + About `Window` scenes with AppKit `NSWindowController`s (`SettingsWindowController`, `AboutWindowController`) — the same pattern Onboarding already uses. `isReleasedWhenClosed = false` keeps the NSWindow alive between opens.
* **Cleanup prompt no longer abbreviates content.** The "Output length ≈ input length. Never expand" rule was silent on compression, so the LLM still tightened phrasing — dropping intensifiers ("really", "very"), modifiers ("the whole", "sort of"), and qualifiers it judged stylistically redundant. Rule now bidirectional: never expand AND never compress, with a ±10% word-count band (excluding fillers + list-connector framings) and an explicit "compression is the more common failure mode" anchor. New NEVER-list bullet enumerates which words may be dropped (only `um`/`uh`/`like`/`you know` plus list connectors when bulleting). Two existing examples that themselves demonstrated compression have been corrected to preserve all content words.

### Internal

* `WhispurApp` no longer declares `Window` scenes for Settings/About — all visible UI is now AppKit-managed (menu bar, Settings, About, Onboarding). One placeholder `Settings { }` scene satisfies SwiftUI's "App needs a Scene" requirement; it's never invoked at runtime for an `LSUIElement` app.
* `comet://` URL scheme handler in `AppDelegate.application(_:open:)` now routes directly to `showSettings`/`showAbout` instead of attempting SwiftUI scene activation.

## [0.2.8] — 2026-05-01

### Fixed

* **Cleanup prompt no longer drifts to third person on narrative-sounding dictation.** The pronoun-preservation rule previously only forbade `I → you/we`; it was silent on `I → he/she/they`, so the LLM occasionally rewrote first-person narrative ("I went down to the beach…") into third person. Rule expanded to cover all person shifts in either direction, with an explicit narrative example.

## [0.2.7] — 2026-05-01

### Fixed

* **Menu-bar icon no longer disappears.** Replaced SwiftUI's `MenuBarExtra` with a manual `NSStatusItem` managed by `MenuBarController`. SwiftUI's `MenuBarExtra` in macOS 14/15 was structurally fragile — the underlying status item was repeatedly torn down on label re-evaluation, on `Window` scene activation (`NSApp.activate(ignoringOtherApps:)`), and on activation-policy flips. The previous defensive patches mitigated symptoms but never the root cause. Manual `NSStatusItem` is what production menu-bar apps (Bartender, iStat, Rectangle) use precisely because of this.

### Internal

* `AppDelegate` now owns `AppState` and `MenuBarController` directly, removing the SwiftUI `@StateObject` → `connect(appState:)` handshake that previously had to ride on a `MenuBarExtra` `.task`.
* Popover content (`MenuBarView`) is hosted in `NSHostingController` inside `NSPopover`. Window-open routes go through `AppDelegate.showSettings(tab:)` / `.showAbout()` instead of relying on SwiftUI's `\.openWindow` environment, which isn't reliably wired into NSHostingController-hosted views.
* Removed `WindowUtilities.swift` and the `MenuBarStatusIcon` / `MenuBarGlyphIcon` SwiftUI views — no longer used.

## [0.2.6] — 2026-05-01

### Fixed

* **Right Option (and any modifier-only hotkey) now actually triggers hold-to-talk.** Bindings whose key code is itself a modifier (Right Option, Right Command, etc.) were silently failing because the matcher only checked the regular pressed-keys set; modifier key codes flow through `flagsChanged` and live in a separate set. Same fix unblocks any future modifier-only binding.
* **Menu-bar icon no longer disappears shortly after launch.** SwiftUI's `MenuBarExtra` was discarding the underlying `NSStatusItem` when the label view re-evaluated — the label held reactive dependencies (`@AppStorage`, `@Environment(\.openWindow)`, `.onReceive`, `.task`) and switched between distinct concrete view types per pipeline phase. Label is now a single concrete view driven solely by phase; side effects moved to the popover content and to `AppDelegate`.

### Added

* **Right Command** as a hold-to-talk preset alongside Right Option, Fn, Control + Space, and F5.

### Internal

* `comet://` URL scheme registered for AppKit-to-SwiftUI scene routing (replaces the notification-via-label hack the old menu-bar code relied on for opening Settings at launch).

## [0.1.0] — 2026-04-30

Initial Comet release. Forked from [Whispur](https://github.com/sophiie-ai/whispur) at v0.13.4.

### Branding

* Application name: Comet
* Bundle identifier: `team.yourorbit.OrbitDictation`
* App icon, menu bar glyph, and Settings/About surfaces rebranded for Orbit
* Application Support directory and Keychain service rescoped under the Orbit identifier so installations do not collide with upstream Whispur

### Cleanup prompt

* New default cleanup prompt: strict text-post-processor contract that refuses to act on the transcript content even when it reads like an instruction
* Adds proper-noun preservation, sentence-boundary inference, English-first language scope, sharper number-normalization rules, hallucination guard for repeated-sentence STT artefacts, list rule that requires three or more items, and explicit "no Markdown unless dictated" rule

### Distribution

* Sparkle update channel points to GitHub Releases on this fork
* Distributed from the Orbit Downloads page on get.yourorbit.team
