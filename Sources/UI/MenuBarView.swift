import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "MenuBarView")

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @AppStorage("settings.selectedTab") private var selectedTabRaw = SettingsTab.setup.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actionCard

            if appState.showSetupGuide && (!appState.isReadyForDailyUse || !appState.hasCompletedFirstDictation) {
                setupCard
            }

            if !appState.hotkeyManager.isAccessibilityGranted {
                warningCard(
                    title: "Accessibility Needed",
                    detail: "Global shortcuts and paste-back won’t work until accessibility access is enabled.",
                    tint: .orange,
                    buttonTitle: "Grant Access",
                    action: appState.requestAccessibilityAccess
                )
            }

            if !appState.microphoneAccessGranted {
                warningCard(
                    title: "Microphone Needed",
                    detail: "Comet can’t record until macOS microphone permission is granted.",
                    tint: .yellow,
                    buttonTitle: "Allow Microphone",
                    action: appState.requestMicrophoneAccess
                )
            }

            providersCard
            shortcutsCard

            if let preview = appState.lastTranscriptPreview,
               !appState.pipeline.canStopRecording {
                lastTranscriptCard(preview)
            }

            footerButtons
        }
        .padding(16)
        .frame(width: 370)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // Small Orbit-indigo squircle hosting the white Orbit glyph —
            // mirrors how the dock icon reads, gives the popover a clear
            // brand anchor before the title.
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.orbit)
                Image("CometMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(6)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Comet Dictation")
                    .font(.title3.weight(.semibold))

                Text(appState.pipeline.statusTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            PreferenceBadge(title: statusBadgeTitle, tone: statusBadgeTone)
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appState.recordingSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                appState.toggleManualDictation()
            } label: {
                Label(primaryActionTitle, systemImage: primaryActionIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.pipeline.canStopRecording && !appState.canStartDictation)

            if appState.pipeline.canStopRecording {
                Text(appState.pipeline.activeTriggerMode == .toggle
                    ? "Toggle mode is active. Use the shortcut again or press Stop."
                    : "Push-to-talk is active. Releasing the shortcut also stops recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.wakeWordEnabled {
                Divider()
                    .padding(.vertical, 2)

                Button {
                    appState.toggleWakeWord()
                } label: {
                    Label(
                        appState.wakeArmed
                            ? "Listening — say \u{201C}Comet start\u{201D}\u{2026}"
                            : "Listen for wake word",
                        systemImage: appState.wakeArmed ? "waveform.circle.fill" : "waveform.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(appState.wakeArmed ? Color.orbit : nil)
                .disabled(!appState.microphoneAccessGranted || appState.pipeline.canStopRecording)

                if let issue = appState.wakeIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(backgroundTone.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Setup Guide")
                        .font(.subheadline.weight(.semibold))
                    Text("\(appState.setupCompletedCount) of \(appState.setupItemCount) complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open") {
                    openSettings(tab: .setup)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ProgressView(value: appState.setupProgress)
                .tint(.orbit)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var providersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Providers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit") {
                    openSettings(tab: .providers)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            providerRow(
                title: "Speech",
                value: appState.selectedSTT.displayName,
                configured: appState.isSelectedSTTConfigured
            )

            providerRow(
                title: "Cleanup",
                value: appState.selectedLLM.displayName,
                configured: appState.isSelectedLLMConfigured,
                fallbackText: "Raw transcripts still paste when cleanup credentials are missing."
            )
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shortcuts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit") {
                    openSettings(tab: .general)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            HStack(spacing: 10) {
                ShortcutSummaryBadge(title: "Hold: \(appState.holdShortcut.menuTitle)")
                ShortcutSummaryBadge(title: "Toggle: \(appState.toggleShortcut?.menuTitle ?? "Off")")
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func warningCard(
        title: String,
        detail: String,
        tint: Color,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func lastTranscriptCard(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last Transcript")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("History") {
                    openSettings(tab: .activity)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Text(preview)
                .font(.caption)
                .lineLimit(5)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("Paste Again") {
                    appState.pasteLastTranscript()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Copy") {
                    appState.copyLastTranscript()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var footerButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("About") {
                    openAbout()
                }

                Button("Settings") {
                    openSettings(tab: .general)
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("Check for Updates…") {
                    appState.sparkleUpdater.checkForUpdates()
                }
                .disabled(!appState.sparkleUpdater.canCheckForUpdates)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .font(.caption)

            orbitFooter
        }
    }

    // "by Orbit AI · yourorbit.team" — the Orbit company mark + link, marking
    // Comet Dictation as an Orbit product.
    private var orbitFooter: some View {
        HStack(spacing: 5) {
            Image("OrbitLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(.secondary)
            Text("by Orbit AI")
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Link("yourorbit.team", destination: URL(string: "https://yourorbit.team")!)
            Spacer()
        }
        .font(.caption2)
    }

    private func providerRow(
        title: String,
        value: String,
        configured: Bool,
        fallbackText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Image(systemName: configured ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(configured ? .green : .orange)
                    .font(.caption)
            }

            Text(value)
                .font(.subheadline)

            if !configured, let fallbackText {
                Text(fallbackText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openSettings(tab: SettingsTab) {
        selectedTabRaw = tab.rawValue
        // `NSApp.delegate as? AppDelegate` returns nil on macOS Sequoia
        // (confirmed via v0.2.14 diagnostic logs) — SwiftUI wraps the
        // user AppDelegate in a private adaptor class for the property,
        // defeating the cast. Use AppDelegate.shared directly. The
        // NotificationCenter fallback below remains as a defensive
        // safety net but should never fire after this fix.
        let appDelegate = AppDelegate.shared
        logger.info("openSettings tap: tab=\(tab.rawValue, privacy: .public) appDelegate=\(appDelegate == nil ? "nil" : "ok", privacy: .public)")

        if let appDelegate {
            appDelegate.showSettings(tab: tab)
        } else {
            logger.error("openSettings fallback: posting whispurOpenSettings notification")
            NotificationCenter.default.post(name: .whispurOpenSettings, object: tab.rawValue)
        }

        appDelegate?.closeMenuBarPopover()
    }

    private func openAbout() {
        let appDelegate = AppDelegate.shared
        logger.info("openAbout tap: appDelegate=\(appDelegate == nil ? "nil" : "ok", privacy: .public)")
        appDelegate?.showAbout()
        appDelegate?.closeMenuBarPopover()
    }

    private var primaryActionTitle: String {
        appState.pipeline.canStopRecording ? "Stop Dictation" : "Start Dictation"
    }

    private var primaryActionIcon: String {
        appState.pipeline.canStopRecording ? "stop.circle.fill" : "mic.circle.fill"
    }

    private var backgroundTone: Color {
        switch appState.pipeline.phase {
        case .recording:
            return .red
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return .blue
        case .done:
            return .green
        case .error:
            return .orange
        default:
            return .secondary
        }
    }

    private var statusBadgeTitle: String {
        switch appState.pipeline.phase {
        case .idle:
            return appState.isReadyForDailyUse ? "Ready" : "Setup"
        case .requestingMicrophonePermission, .starting:
            return "Starting"
        case .recording:
            return appState.pipeline.activeTriggerMode == .hold ? "Listening" : "Latched"
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return "Working"
        case .done:
            return "Done"
        case .error:
            return "Issue"
        }
    }

    private var statusBadgeTone: PreferenceBadge.Tone {
        switch appState.pipeline.phase {
        case .idle:
            return appState.isReadyForDailyUse ? .good : .warning
        case .requestingMicrophonePermission, .starting:
            return .warning
        case .recording:
            return .critical
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return .neutral
        case .done:
            return .good
        case .error:
            return .critical
        }
    }
}

