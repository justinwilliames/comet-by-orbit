import AppKit
import SwiftUI

struct SetupSettingsView: View {
    @ObservedObject var appState: AppState
    let openTab: (SettingsTab) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                checklistCard
                quickStartCard
                troubleshootingCard
            }
            .padding(24)
        }
    }

    private var heroCard: some View {
        PreferenceCard(
            "Comet Setup",
            detail: "Finish the core steps once, then dictation stays out of your way.",
            icon: "sparkles"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(appState.setupCompletedCount) of \(appState.setupItemCount) complete")
                            .font(.title2.weight(.semibold))
                        Text(appState.isReadyForDailyUse ? "Comet is ready to dictate across your Mac." : "A few items still need attention before daily use feels seamless.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    PreferenceBadge(
                        title: appState.isReadyForDailyUse ? "Ready" : "Needs setup",
                        tone: appState.isReadyForDailyUse ? .good : .warning
                    )
                }

                ProgressView(value: appState.setupProgress)
                    .tint(.orbit)

                HStack(spacing: 10) {
                    ShortcutSummaryBadge(title: "Hold: \(appState.holdShortcut.menuTitle)")
                    ShortcutSummaryBadge(title: "Toggle: \(appState.toggleShortcut?.menuTitle ?? "Off")")
                }
            }
        }
    }

    private var checklistCard: some View {
        PreferenceCard(
            "Checklist",
            detail: "These are the steps that matter for a smooth first-run experience.",
            icon: "checklist"
        ) {
            VStack(spacing: 10) {
                SetupChecklistRow(
                    title: "Grant microphone access",
                    detail: "Comet needs live audio input before it can capture speech.",
                    isComplete: appState.microphoneAccessGranted,
                    actionTitle: appState.microphoneAccessGranted ? nil : "Allow",
                    action: appState.microphoneAccessGranted ? nil : { appState.requestMicrophoneAccess() }
                )

                SetupChecklistRow(
                    title: "Enable accessibility access",
                    detail: "This lets Comet trigger shortcuts globally and paste text back into the active app. After granting in System Settings, use the Recheck button on the General tab if this row still says incomplete.",
                    isComplete: appState.hotkeyManager.isAccessibilityGranted,
                    actionTitle: appState.hotkeyManager.isAccessibilityGranted ? nil : "Open",
                    action: appState.hotkeyManager.isAccessibilityGranted ? nil : { appState.requestAccessibilityAccess() }
                )

                SetupChecklistRow(
                    title: "Choose a speech provider",
                    detail: appState.isSelectedSTTConfigured
                        ? "\(appState.selectedSTT.displayName) is ready."
                        : "The current speech provider still needs credentials.",
                    isComplete: appState.isSelectedSTTConfigured,
                    actionTitle: "Providers",
                    action: { openTab(.providers) }
                )

                SetupChecklistRow(
                    title: "Review your shortcuts",
                    detail: appState.shortcutSummary,
                    isComplete: true,
                    actionTitle: "Shortcuts",
                    action: { openTab(.general) }
                )

                SetupChecklistRow(
                    title: "Run a first dictation",
                    detail: appState.hasCompletedFirstDictation
                        ? "Recent activity is available in the Activity tab."
                        : "Try one dictation to confirm your end-to-end flow.",
                    isComplete: appState.hasCompletedFirstDictation,
                    actionTitle: appState.hasCompletedFirstDictation ? "Activity" : nil,
                    action: appState.hasCompletedFirstDictation ? { openTab(.activity) } : nil
                )
            }
        }
    }

    private var quickStartCard: some View {
        PreferenceCard(
            "How It Works",
            detail: "Comet keeps capture, cleanup, and paste in a single pass.",
            icon: "waveform.and.mic"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hold your shortcut to speak, or use the toggle shortcut when you want to stay in dictation mode. After you stop, Comet transcribes, cleans up the wording, and pastes the final text back into the frontmost app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Review Prompts") {
                        openTab(.prompts)
                    }

                    Button("Hide Setup Guide") {
                        appState.hideSetupGuide()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var troubleshootingCard: some View {
        PreferenceCard(
            "Troubleshooting",
            detail: "Permissions can drift across updates while the app is unsigned. If something stops working, the fix is usually to reset the relevant entry in System Settings.",
            icon: "wrench.and.screwdriver"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                DisclosureGroup("Accessibility doesn't take effect after granting") {
                    TroubleshootingSteps(steps: [
                        "Open System Settings → Privacy & Security → Accessibility.",
                        "Find Comet in the list and click the − button to remove it.",
                        "Quit Comet completely (right-click the menu-bar icon → Quit, or ⌘Q from the popover).",
                        "Relaunch Comet.",
                        "Click Grant Access in the in-app prompt — the new entry will be picked up immediately.",
                    ])
                    .padding(.top, 8)
                }

                DisclosureGroup("Keychain asks for your login password on launch") {
                    TroubleshootingSteps(steps: [
                        "When the prompt appears, click Always Allow.",
                        "The grant persists until the next Sparkle update — the prompt will return then because the binary changed.",
                        "Once the app is signed (Apple Developer Programme), this stops happening permanently.",
                    ])
                    .padding(.top, 8)
                }

                DisclosureGroup("Gatekeeper blocks the app after an update") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Comet shows a one-click \"Copy & Open Terminal\" helper after each update. If you missed it, run this in Terminal once:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(#"xattr -dr com.apple.quarantine "/Applications/Comet.app""#)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button("Copy command") {
                            let command = #"xattr -dr com.apple.quarantine "/Applications/Comet.app""#
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 8)
                }

                DisclosureGroup("Microphone permission already granted but the app says \"Missing\"") {
                    TroubleshootingSteps(steps: [
                        "Open System Settings → Privacy & Security → Microphone.",
                        "Toggle Comet off, then back on.",
                        "If that doesn't help, remove the entry with the − button and relaunch the app to re-prompt.",
                    ])
                    .padding(.top, 8)
                }

                DisclosureGroup("Live logs (advanced)") {
                    LiveLogsView()
                        .padding(.top, 8)
                }

                DisclosureGroup("Still stuck? Nuclear reset (recommended last)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("If remove + re-add + toggle still doesn't pick up, the system permission database (tccd) has a cached entry pointing at a stale bundle. Wipe all permission grants for Comet and start fresh:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(Self.tccResetCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        HStack(spacing: 8) {
                            Button("Copy reset commands") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Self.tccResetCommand, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Find duplicate copies") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Self.findBundlesCommand, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()
                        }

                        Text("After running the commands, quit Comet completely (menu-bar icon → Quit), wait a few seconds, then relaunch from /Applications. Re-grant when prompted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("After granting in System Settings, the running app must restart for AXIsProcessTrusted() to see the new state. Click below to relaunch Comet in one step.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        Self.relaunchApp()
                    } label: {
                        Label("Restart Comet", systemImage: "arrow.clockwise.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Diagnostic info")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Running from:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Bundle.main.bundleURL.path)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("If this isn't /Applications/Comet.app, your TCC grants are being recorded against the wrong path. Move the app, run the xattr command, and relaunch.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Why this happens")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Comet currently ships unsigned (no Apple Developer Programme certificate yet). macOS keys permission grants — Accessibility, Microphone, Keychain access, and Gatekeeper approval — to the running binary's identity. Signed apps use the signing identity, which is stable across versions. Unsigned apps fall back to the binary hash, which changes on every Sparkle update. That's why grants need refreshing after updates, and why a running process must restart to pick up a fresh grant. Signing the app fixes all four issues above permanently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Link(destination: URL(string: "https://github.com/justinwilliames/comet-dictation/issues")!) {
                        Label("Report an issue", systemImage: "exclamationmark.bubble")
                            .font(.caption)
                    }
                    Link(destination: URL(string: "https://github.com/justinwilliames/comet-dictation")!) {
                        Label("View source", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                    }
                    Spacer()
                }
            }
        }
    }

    private static let tccResetCommand = """
        tccutil reset Accessibility team.yourorbit.OrbitDictation
        tccutil reset Microphone team.yourorbit.OrbitDictation
        """

    private static let findBundlesCommand =
        #"mdfind 'kMDItemCFBundleIdentifier == "team.yourorbit.OrbitDictation"'"#

    /// Relaunch the app cleanly: spawn a new instance via NSWorkspace, then
    /// terminate the current process. NSWorkspace's `createsNewApplicationInstance`
    /// flag lets the second instance start before we exit, so the user briefly
    /// sees nothing rather than an error. Required after granting Accessibility
    /// because `AXIsProcessTrusted()` only re-reads on process launch.
    private static func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct TroubleshootingSteps: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(idx + 1).")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(step)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
