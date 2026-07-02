import SwiftUI

/// Provider configuration: API keys and active provider selection.
///
/// Top-level UX is decision-fatigue-minimised: one Recommended setup using
/// Groq (free tier covers most users, single API key powers both speech and
/// cleanup), one Apple-only fallback for users who want zero cloud, and
/// everything else is hidden behind an "Other providers" disclosure for
/// power users who want to mix-and-match.
struct ProvidersSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var advancedExpanded: Bool = false
    /// Bumped whenever any Keychain key changes so computed badge properties recompute.
    @State private var refreshToken: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                recommendedCard
                appleOnlyCard
                advancedCard
                languagesCard
            }
            .padding(24)
        }
        // Force a re-evaluation of all keychain-dependent computed properties
        // whenever a key is saved or deleted — no tab-switch required.
        .onReceive(NotificationCenter.default.publisher(for: KeychainManager.apiKeysDidChange)) { _ in
            refreshToken &+= 1
        }
        .id(refreshToken)
    }

    // MARK: - Recommended (Groq)

    private var isOnRecommendedSetup: Bool {
        appState.selectedSTT == .groqWhisper && appState.selectedLLM == .groq
    }

    private var groqKeyConfigured: Bool {
        appState.keychain.has(.groqAPIKey)
    }

    private var recommendedCard: some View {
        PreferenceCard(
            "Recommended setup",
            detail: "One free API key from Groq powers both speech recognition and cleanup. Free tier is generous — usually plenty for daily dictation use.",
            icon: "sparkles"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    PreferenceBadge(title: "Recommended", tone: .good)
                    PreferenceBadge(
                        title: groqKeyConfigured ? "Key configured" : "Key needed",
                        tone: groqKeyConfigured ? .good : .warning
                    )
                    if isOnRecommendedSetup {
                        PreferenceBadge(title: "Active", tone: .good)
                    }
                    Spacer()
                    Link(destination: URL(string: "https://console.groq.com/keys")!) {
                        Label("Get a free key", systemImage: "arrow.up.forward.app")
                            .font(.caption.weight(.medium))
                    }
                }

                Text("Sign up at console.groq.com (no credit card needed), create an API key, paste it here. Comet uses Groq's whisper-large-v3 for speech and Llama 3.3 70B for cleanup — Groq's free models, picked for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                APIKeyField(
                    label: "Groq API Key",
                    key: .groqAPIKey,
                    keychain: appState.keychain
                )

                Button {
                    appState.selectedSTT = .groqWhisper
                    appState.selectedLLM = .groq
                } label: {
                    Label(
                        isOnRecommendedSetup ? "Using Groq for speech + cleanup" : "Use Groq for speech + cleanup",
                        systemImage: isOnRecommendedSetup ? "checkmark.circle.fill" : "arrow.right.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.orbit)
                .disabled(isOnRecommendedSetup)
            }
        }
    }

    // MARK: - Apple-only path

    private var isOnAppleOnly: Bool {
        appState.selectedSTT == .apple
    }

    private var appleOnlyCard: some View {
        PreferenceCard(
            "Or just use Apple Dictation",
            detail: "Apple's on-device speech recognition runs locally with zero API keys. The recording stays on your Mac and Comet pastes the raw transcript with light punctuation only.",
            icon: "applelogo"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Trade-offs to know about:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("• Transcription is good but not as accurate as Whisper.")
                    Text("• Cleanup is off — filler words, run-ons, and self-corrections all paste verbatim.")
                    Text("• Apple may need a one-time language model download the first time you use it.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    appState.selectedSTT = .apple
                } label: {
                    Label(
                        isOnAppleOnly ? "Using Apple Dictation" : "Use Apple Dictation",
                        systemImage: isOnAppleOnly ? "checkmark.circle.fill" : "applelogo"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isOnAppleOnly)
            }
        }
    }

    // MARK: - Advanced (full provider matrix)

    private var advancedCard: some View {
        PreferenceCard(
            "Other providers",
            detail: "Bring your own keys for OpenAI, Anthropic, Deepgram, ElevenLabs, or AWS Bedrock. Mix-and-match speech and cleanup providers independently.",
            icon: "slider.horizontal.3"
        ) {
            DisclosureGroup("Advanced configuration", isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    speechCard
                    cleanupCard
                }
                .padding(.top, 12)
            }
        }
    }

    private var speechCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speech-to-Text")
                .font(.subheadline.weight(.semibold))

            Text("Pick which transcription service Comet calls after recording.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Speech provider", selection: $appState.selectedSTT) {
                ForEach(STTProviderID.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 250)

            ForEach(STTProviderID.allCases, id: \.self) { provider in
                ProviderConfigurationCard(
                    name: provider.displayName,
                    note: provider == .apple
                        ? "Runs on-device and works without an API key."
                        : "Configure credentials in Keychain before using this provider.",
                    isActive: appState.selectedSTT == provider,
                    isConfigured: !provider.requiresAPIKey || appState.keychain.hasKeysFor(stt: provider)
                ) {
                    if provider.requiresAPIKey {
                        ForEach(provider.keychainKeys, id: \.rawValue) { key in
                            APIKeyField(
                                label: key.displayName,
                                key: key,
                                keychain: appState.keychain
                            )
                        }
                    }
                }
            }
        }
    }

    private var cleanupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cleanup Model")
                .font(.subheadline.weight(.semibold))

            Text("Post-processing adds punctuation, removes filler, and smooths dictation before paste. Skipped automatically if no key is configured.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Cleanup provider", selection: $appState.selectedLLM) {
                ForEach(LLMProviderID.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 250)

            ForEach(LLMProviderID.allCases, id: \.self) { provider in
                ProviderConfigurationCard(
                    name: provider.displayName,
                    note: noteForLLM(provider),
                    isActive: appState.selectedLLM == provider,
                    isConfigured: appState.keychain.hasKeysFor(llm: provider)
                ) {
                    ForEach(provider.keychainKeys, id: \.rawValue) { key in
                        APIKeyField(
                            label: key.displayName,
                            key: key,
                            keychain: appState.keychain
                        )
                    }
                }
            }
        }
    }

    private func noteForLLM(_ provider: LLMProviderID) -> String {
        if provider.usesLocalCLI {
            let tool = provider.localCLITool?.displayName ?? "CLI"
            return "No API key needed — cleanup runs through your local \(tool) login. "
                + "Requires \(tool) installed and signed in. \(provider.localCLITool?.loginHint ?? "")"
        }
        if appState.selectedLLM == provider, !appState.isSelectedLLMConfigured {
            return "Comet will paste raw transcripts until credentials are added."
        }
        return "Use this provider for transcript cleanup after transcription."
    }

    // MARK: - Languages

    private var languagesCard: some View {
        PreferenceCard(
            "Preferred Language",
            detail: "Pick the language you speak. Comet sends this as a hint to the selected speech provider. Auto-detect asks the provider to identify the language itself — best when you switch between languages.",
            icon: "character.bubble"
        ) {
            STTLanguagePicker(appState: appState)
        }
    }
}

private struct STTLanguagePicker: View {
    @ObservedObject var appState: AppState

    private static let autoTag = "__auto__"

    private var selectionTag: String {
        switch appState.sttLanguageSelection {
        case .auto: return Self.autoTag
        case .single(let code): return code
        }
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { selectionTag },
            set: { newTag in
                appState.sttLanguageSelection = newTag == Self.autoTag
                    ? .auto
                    : .single(code: newTag)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Language", selection: selectionBinding) {
                Text("Auto-detect").tag(Self.autoTag)
                Divider()
                ForEach(STTLanguageCatalog.all) { language in
                    Text(language.displayName).tag(language.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 260)

            Text(footnote(for: appState.selectedSTT, selection: appState.sttLanguageSelection))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func footnote(for provider: STTProviderID, selection: STTLanguageSelection) -> String {
        switch (provider, selection) {
        case (.deepgram, .auto):
            return "Deepgram will use nova-3's multilingual mode (English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, Dutch)."
        case (.apple, .auto):
            return "Apple has no auto mode — Comet falls back to your system language."
        case (.openai, .auto), (.groqWhisper, .auto), (.elevenlabs, .auto):
            return "The provider will detect the language on each recording."
        default:
            return "Comet will tell \(provider.displayName) which language to expect."
        }
    }
}

private struct ProviderConfigurationCard<Content: View>: View {
    let name: String
    let note: String
    let isActive: Bool
    let isConfigured: Bool
    let content: Content

    init(
        name: String,
        note: String,
        isActive: Bool,
        isConfigured: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.name = name
        self.note = note
        self.isActive = isActive
        self.isConfigured = isConfigured
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.headline)

                if isActive {
                    PreferenceBadge(title: "Active", tone: .good)
                }

                PreferenceBadge(
                    title: isConfigured ? "Configured" : "Needs setup",
                    tone: isConfigured ? .good : .warning
                )

                Spacer()
            }

            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
