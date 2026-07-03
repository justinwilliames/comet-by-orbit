import SwiftUI

/// Cleanup prompt override and vocabulary configuration.
struct PromptsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showsDefaultPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                advancedCleanupCard
                promptCard
                toneCard
                vocabularyCard
                referenceCard
            }
            .padding(24)
        }
    }

    private var toneCard: some View {
        PreferenceCard(
            "Tone of Voice",
            detail: "Optional. Describe how your dictated text should sound when it comes back — the cleanup pipeline applies these style instructions on top of the cleanup prompt without changing what you said.",
            icon: "waveform"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $appState.customToneInstructions)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("Example: \"Casual, dry, never use exclamation marks. Australian spellings (organise, colour). Prefer 'so I' over 'therefore I'.\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    PreferenceBadge(
                        title: appState.customToneInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No tone instructions"
                            : "Tone applied",
                        tone: appState.customToneInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .neutral : .good
                    )

                    Spacer()

                    if !appState.customToneInstructions.isEmpty {
                        Button("Clear") {
                            appState.customToneInstructions = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var advancedCleanupCard: some View {
        PreferenceCard(
            "Advanced Cleanup",
            detail: "Optional, off by default. When on, Comet does more than tidy grammar — it reshapes rambling dictation into clear, well-organised text: reordering points, tightening waffle, and formatting sets of items as proper bulleted lists with line breaks. It never invents anything or acts on your words; it only restructures what you actually said. With it off, Comet stays close to verbatim and only makes a list when you explicitly ask for one.",
            icon: "wand.and.stars"
        ) {
            Toggle(isOn: $appState.advancedCleanupEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enhanced grammar, structure & formatting")
                        .font(.callout.weight(.medium))
                    Text("Restructures and reformats, not just cleans. Best with a capable cleanup model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var promptCard: some View {
        PreferenceCard(
            "Cleanup Prompt",
            detail: "Optional. When set, this replaces the built-in cleanup prompt for every dictation. Leave empty to use Comet's default.",
            icon: "text.bubble"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $appState.customSystemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    PreferenceBadge(
                        title: appState.customSystemPrompt.isEmpty ? "Using default" : "Custom prompt active",
                        tone: appState.customSystemPrompt.isEmpty ? .neutral : .good
                    )

                    Spacer()

                    if !appState.customSystemPrompt.isEmpty {
                        Button("Reset to default") {
                            appState.customSystemPrompt = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var vocabularyCard: some View {
        PreferenceCard(
            "Custom Vocabulary",
            detail: "One term per line. Useful for product names, acronyms, and proper nouns.",
            icon: "text.book.closed"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $appState.customVocabulary)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Toggle(isOn: $appState.learnFromEdits) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learn from my edits")
                            .font(.callout.weight(.medium))
                        Text("After a paste, Comet re-reads the focused text field on your next dictation. If you changed a word, it asks before adding that word to this vocabulary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var referenceCard: some View {
        PreferenceCard(
            "Default Reference",
            detail: "Comet's built-in cleanup prompt. Copy it as a starting point if you want to tweak instead of rewrite.",
            icon: "doc.text.magnifyingglass"
        ) {
            DisclosureGroup(isExpanded: $showsDefaultPrompt) {
                Text(Prompts.defaultCleanup)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } label: {
                Button(action: { withAnimation { showsDefaultPrompt.toggle() } }) {
                    Text("Show default cleanup prompt")
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
