import SwiftUI

/// Reference page listing every voice command available while the wake word is
/// armed. Reads straight from the `VoiceCommands` table so it never drifts from
/// what the recognizer actually matches.
struct VoiceCommandsSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introCard
                dictationCard
                keystrokeCard
            }
            .padding(24)
        }
    }

    private var introCard: some View {
        PreferenceCard(
            "Voice Commands",
            detail: "Hands-free control while the wake word is armed. Arm it from the menu bar, then just speak. All recognition is on-device. Keystroke commands only fire while idle (not mid-dictation), and act on whatever app is focused.",
            icon: "mic.and.signal.meter.fill"
        ) {
            if !appState.wakeWordEnabled {
                Label(
                    "Turn on the wake word in the General tab to use these.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var dictationCard: some View {
        PreferenceCard(
            "Dictation",
            detail: "Any listed phrasing works — including “Dictation” in place of “Comet”.",
            icon: "waveform"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                commandRow(title: "Start dictation", keystroke: "🎙", phrases: VoiceCommands.startDisplayPhrases, tint: .green)
                Divider()
                commandRow(title: "Stop dictation", keystroke: "⏹", phrases: VoiceCommands.stopDisplayPhrases, tint: .red)
            }
        }
    }

    private var keystrokeCard: some View {
        PreferenceCard(
            "Keystrokes (while idle)",
            detail: "Say these after stopping — to send, edit, or navigate. “Undo that” reverses any command that misfires.",
            icon: "keyboard"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(VoiceCommands.keystroke.enumerated()), id: \.element.id) { index, command in
                    if index > 0 { Divider() }
                    commandRow(
                        title: command.title,
                        keystroke: command.keystrokeLabel,
                        phrases: command.actions.map { "“Comet \($0)”" }.joined(separator: "  ·  "),
                        tint: command.isDestructive ? .orange : .primary,
                        destructive: command.isDestructive
                    )
                }
            }
        }
    }

    private func commandRow(
        title: String,
        keystroke: String,
        phrases: String,
        tint: Color,
        destructive: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(keystroke)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(minWidth: 46, alignment: .leading)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium))
                    if destructive {
                        Text("destructive")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(phrases).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
