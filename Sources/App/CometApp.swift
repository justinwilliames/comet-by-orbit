import SwiftUI

@main
struct CometApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All visible UI is AppKit-managed:
        //   - Menu bar:  `MenuBarController` (NSStatusItem)
        //   - Settings:  `SettingsWindowController`
        //   - About:     `AboutWindowController`
        //   - Onboarding: `OnboardingWindowController` (was already AppKit)
        //
        // SwiftUI Window/MenuBarExtra scenes proved too fragile when
        // combined with NSPopover-hosted content and `LSUIElement = true`:
        //   - MenuBarExtra status items were torn down on label re-eval,
        //     scene activation, and activation-policy flips.
        //   - `Window` scenes went stale after first close — `openWindow`
        //     and `comet://` URL routing both stopped firing.
        // Production menu-bar apps (Bartender, iStat, Rectangle) all use
        // direct AppKit window management precisely because of this.
        //
        // SwiftUI's `App` protocol still requires at least one Scene, so we
        // declare a `Settings` scene with empty content. It's never
        // actually invoked at runtime (LSUIElement apps have no app menu
        // bar to surface the standard "Settings…" item), but it satisfies
        // the type system.
        Settings {
            EmptyView()
        }
    }
}
