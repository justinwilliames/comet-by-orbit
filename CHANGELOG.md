# Changelog

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
