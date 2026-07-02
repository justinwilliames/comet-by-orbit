import AppKit
import AVFoundation
import Combine
import Foundation
import ServiceManagement
import SwiftUI

/// Central application state used by the menu bar UI and settings window.
@MainActor
final class AppState: ObservableObject {
    @AppStorage("selectedSTT") var selectedSTT: STTProviderID = .apple
    /// Empty string = auto-detect; otherwise a BCP-47 code like `en-US`.
    @AppStorage("sttLanguageSelection") var sttLanguageSelectionStorage: String = ""
    @AppStorage("selectedLLM") var selectedLLM: LLMProviderID = .anthropic
    @AppStorage("deepContextEnabled") var deepContextEnabled: Bool = false
    @AppStorage("preserveClipboard") var preserveClipboard: Bool = true
    @AppStorage("customSystemPrompt") var customSystemPrompt: String = ""
    /// User-supplied tone-of-voice / style guidance. Appended to the
    /// cleanup prompt (default or custom) under a TONE OF VOICE section
    /// at runtime — the user describes how their writing should sound,
    /// not what the cleanup pipeline should DO. Examples: "Casual,
    /// dry, never use exclamation marks. Australian spellings."
    @AppStorage("customToneInstructions") var customToneInstructions: String = ""
    @AppStorage("customVocabulary") var customVocabulary: String = ""
    @AppStorage("learnFromEdits") var learnFromEdits: Bool = false
    @AppStorage("soundEnabled") var soundEnabled: Bool = true
    @AppStorage("showSetupGuide") var showSetupGuide: Bool = true
    @AppStorage("whispur.onboarding.completed") var onboardingCompleted: Bool = false
    /// Default ON so first-install users get Comet in their menu bar
    /// after a reboot without thinking about it. The first call to
    /// `applyLaunchAtLoginPreference()` registers with SMAppService,
    /// which triggers macOS to surface the Login Items approval prompt.
    @AppStorage("launchAtLoginEnabled") var launchAtLoginEnabled: Bool = true

    /// Hands-free wake word. Off by default — it's an always-listening feature
    /// (while armed) and users should opt in deliberately.
    @AppStorage("wakeWordEnabled") var wakeWordEnabled: Bool = false

    @Published var holdShortcut: ShortcutBinding
    @Published var toggleShortcut: ShortcutBinding?
    @Published private(set) var microphoneAccessGranted = AudioRecorder.hasMicrophoneAccess
    /// True while the wake word is actively listening (armed window).
    @Published private(set) var wakeArmed = false

    let pipeline: DictationPipeline
    let recorder: AudioRecorder
    private let wakeWordListener = WakeWordListener()
    /// True while the current dictation session was started by the wake word —
    /// gates silence-based auto-stop so hold/toggle sessions are unaffected.
    private var wakeInitiatedSession = false
    private var wakeAutoDisarmTask: Task<Void, Never>?
    private var wakeMaxDurationTask: Task<Void, Never>?
    /// The armed window auto-disarms after this much inactivity.
    private static let wakeAutoDisarmInterval: TimeInterval = 15 * 60
    /// Hard cap on a single wake-started recording if "End Comet" is missed.
    private static let wakeMaxSessionDuration: TimeInterval = 3 * 60

    let hotkeyManager: HotkeyManager
    let historyStore: PipelineHistoryStore
    let providerRequestLog: ProviderRequestLog
    let keychain: KeychainManager
    let registry: ProviderRegistry
    let overlayManager: OverlayPanelManager
    let sparkleUpdater: SparkleUpdater
    let learning: TranscriptLearning
    let learningSuggestions: LearningSuggestionCenter
    private let learningToastPanel: LearningToastPanelManager

    private let shortcutSessionController = ShortcutSessionController()
    private var permissionObservers: [NSObjectProtocol] = []
    private var phaseCancellable: AnyCancellable?
    private var hotkeyManagerCancellable: AnyCancellable?

    init() {
        let loadedHoldShortcut = Self.loadShortcut(forKey: "holdShortcut", fallback: .fnKey)
        let loadedToggleShortcut = Self.loadOptionalShortcut(forKey: "toggleShortcut", fallback: .commandFn)
        let sanitizedToggleShortcut = loadedToggleShortcut == loadedHoldShortcut
            ? ShortcutBinding.commandFn
            : loadedToggleShortcut

        _holdShortcut = Published(initialValue: loadedHoldShortcut)
        _toggleShortcut = Published(initialValue: sanitizedToggleShortcut)

        let keychain = KeychainManager.shared
        let providerRequestLog = ProviderRequestLog()
        let httpClient = ProviderHTTPClient(requestLog: providerRequestLog)
        let registry = ProviderRegistry(keychain: keychain, httpClient: httpClient)
        let recorder = AudioRecorder()
        let historyStore = PipelineHistoryStore()
        let pipeline = DictationPipeline(
            recorder: recorder,
            registry: registry,
            historyStore: historyStore,
            httpClient: httpClient
        )
        let sparkleUpdater = SparkleUpdater()
        let hotkeyManager = HotkeyManager()
        let overlayManager = OverlayPanelManager()
        let learning = TranscriptLearning()
        let learningSuggestions = LearningSuggestionCenter()
        let learningToastPanel = LearningToastPanelManager()

        self.keychain = keychain
        self.registry = registry
        self.recorder = recorder
        self.historyStore = historyStore
        self.pipeline = pipeline
        self.sparkleUpdater = sparkleUpdater
        self.hotkeyManager = hotkeyManager
        self.overlayManager = overlayManager
        self.providerRequestLog = providerRequestLog
        self.learning = learning
        self.learningSuggestions = learningSuggestions
        self.learningToastPanel = learningToastPanel

        hotkeyManager.holdBinding = loadedHoldShortcut
        hotkeyManager.toggleBinding = sanitizedToggleShortcut

        setupHotkeys()
        observeHotkeyManager()
        observePipeline()
        setupLearning()
        setupWakeWord()

        overlayManager.bind(
            to: pipeline,
            onStop: { [weak self] in self?.stopDictation() },
            onCancel: { [weak self] in self?.cancelDictation() }
        )

        syncPipelineConfig()
        refreshPermissionSnapshot()

        // Defer everything non-critical until after the menu bar paints.
        // Installing the CGEventTap, the legacy-preferences migration, and
        // the Sparkle update check all touch the filesystem / event system
        // and would otherwise add ~30–100 ms before the icon appears.
        Task { @MainActor [weak self] in
            guard let self else { return }
            Self.migrateLegacyLanguagesPreferenceIfNeeded()
            Self.clearRetiredModesStorage()
            self.hotkeyManager.start()
            self.startPermissionMonitoring()
            self.sparkleUpdater.checkForUpdatesInBackground()
        }
    }

    /// Drop UserDefaults keys that outlived dictation modes and per-app
    /// provider rules. A user's global `customSystemPrompt` override (if
    /// any) is preserved; per-mode customizations and per-app rules are
    /// not carried forward.
    private static func clearRetiredModesStorage() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "whispur.dictationModes.customPrompts")
        defaults.removeObject(forKey: "selectedDictationMode")
        defaults.removeObject(forKey: "whispur.appProviderRules")
        defaults.removeObject(forKey: "appRulesEnabled")
    }

    /// One-shot migration of the prior multi-language CSV setting
    /// (`sttLanguages`) into the new single-selection storage key
    /// (`sttLanguageSelection`). Keeps the first entry as the user's single
    /// preferred language; empty list becomes auto-detect.
    private static func migrateLegacyLanguagesPreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        let legacyKey = "sttLanguages"
        let newKey = "sttLanguageSelection"
        guard let legacy = defaults.string(forKey: legacyKey) else { return }
        // Only migrate if the new key hasn't been set yet — don't overwrite a
        // user who already made a choice in the new UI.
        if defaults.object(forKey: newKey) == nil {
            let firstCode = legacy
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            defaults.set(firstCode, forKey: newKey)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    private func setupLearning() {
        learning.isEnabled = learnFromEdits
        learning.suggestionCenter = learningSuggestions
        learning.onLearnTerm = { [weak self] _, toTerm in
            guard let self else { return }
            self.appendToVocabulary(toTerm)
        }
        learningSuggestions.onAccept = { [weak self] suggestion in
            self?.appendToVocabulary(suggestion.to)
        }
        learningToastPanel.bind(to: learningSuggestions)
        pipeline.onPasteCompleted = { [weak self] pasted in
            guard let self, self.learnFromEdits else { return }
            self.learning.captureAfterPaste(pastedText: pasted)
        }
    }

    private func appendToVocabulary(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = VocabularyParser.parse(customVocabulary)
        guard !existing.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { return }
        let prefix = customVocabulary.isEmpty || customVocabulary.hasSuffix("\n")
            ? customVocabulary
            : customVocabulary + "\n"
        customVocabulary = prefix + trimmed
        syncPipelineConfig()
    }

    var isSelectedSTTConfigured: Bool {
        !selectedSTT.requiresAPIKey || keychain.hasKeysFor(stt: selectedSTT)
    }

    var isSelectedLLMConfigured: Bool {
        keychain.hasKeysFor(llm: selectedLLM)
    }

    var canStartDictation: Bool {
        pipeline.canStartRecording && isSelectedSTTConfigured && hotkeyManager.isAccessibilityGranted
    }

    var hasRequiredPermissions: Bool {
        microphoneAccessGranted && hotkeyManager.isAccessibilityGranted
    }

    var isReadyForDailyUse: Bool {
        hasRequiredPermissions && isSelectedSTTConfigured
    }

    var hasCompletedFirstDictation: Bool {
        !historyStore.items.isEmpty
    }

    var setupProgress: Double {
        Double(setupCompletedCount) / Double(setupItemCount)
    }

    var setupCompletedCount: Int {
        [
            microphoneAccessGranted,
            hotkeyManager.isAccessibilityGranted,
            isSelectedSTTConfigured,
            true,
            hasCompletedFirstDictation
        ]
        .filter { $0 }
        .count
    }

    var setupItemCount: Int { 5 }

    var lastTranscriptPreview: String? {
        let text = pipeline.lastResult?.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var lastRawTranscriptPreview: String? {
        let text = pipeline.lastResult?.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var hasToggleShortcut: Bool {
        toggleShortcut != nil
    }

    var shortcutSummary: String {
        if let toggleShortcut {
            return "\(holdShortcut.menuTitle) to talk, \(toggleShortcut.menuTitle) to latch"
        }
        return "\(holdShortcut.menuTitle) to talk"
    }

    var recordingSummary: String {
        switch pipeline.phase {
        case .idle:
            if !isReadyForDailyUse {
                return "Finish setup to start dictating."
            }
            return shortcutSummary
        case .requestingMicrophonePermission:
            return "Allow microphone access to begin recording."
        case .starting:
            return "Preparing your microphone."
        case .recording:
            if pipeline.activeTriggerMode == .hold {
                return "Release \(holdShortcut.menuTitle) to transcribe."
            }
            if let toggleShortcut {
                return "Press \(toggleShortcut.menuTitle) again or use Stop."
            }
            return "Use Stop when you're done."
        case .normalizingAudio:
            return "Cleaning up the captured audio."
        case .transcribing:
            return "Turning speech into text."
        case .cleaningTranscript:
            return "Polishing the transcript for paste."
        case .pasting:
            return "Inserting text into the active app."
        case .done:
            return "Ready for the next dictation."
        case .error:
            return "Review setup or try again."
        }
    }

    func startDictation(triggerMode: RecordingTriggerMode = .hold) {
        syncPipelineConfig()
        refreshPermissionSnapshot()

        // Before the new recording begins, check whether the user edited
        // the previous paste — if so, offer to learn those words.
        learning.isEnabled = learnFromEdits
        if learnFromEdits {
            Task { [weak self] in await self?.learning.reconcile() }
        }

        guard hotkeyManager.isAccessibilityGranted else {
            pipeline.presentError("Accessibility access is required before Comet can paste dictated text.")
            return
        }

        guard isSelectedSTTConfigured else {
            pipeline.presentError("\(selectedSTT.displayName) is not configured. Add its API key or switch to Apple STT.")
            return
        }

        pipeline.startRecording(triggerMode: triggerMode)
    }

    func stopDictation() {
        shortcutSessionController.reset()
        pipeline.stopAndProcess()
    }

    func toggleManualDictation() {
        if pipeline.canStopRecording {
            stopDictation()
        } else if canStartDictation {
            shortcutSessionController.beginManual(mode: .toggle)
            startDictation(triggerMode: .toggle)
        }
    }

    // MARK: - Wake word

    private func setupWakeWord() {
        wakeWordListener.localeID = STTLanguageResolver.appleLocale(for: sttLanguageSelection)
        wakeWordListener.onCommand = { [weak self] command in
            self?.handleWakeCommand(command)
        }
        wakeWordListener.onUnavailable = { [weak self] message in
            guard let self else { return }
            self.disarmWakeWord()
            self.pipeline.presentError(message)
        }
        // Strip a trailing stop phrase (captured in the recording) from the
        // transcript before it's cleaned and pasted.
        pipeline.trailingStripPhrases = WakePhrases.stop
    }

    /// Menu-bar entry point: flip the armed listening window on/off.
    func toggleWakeWord() {
        if wakeArmed {
            disarmWakeWord()
        } else {
            armWakeWord()
        }
    }

    func armWakeWord() {
        guard wakeWordEnabled, !wakeArmed else { return }
        guard microphoneAccessGranted else {
            pipeline.presentError("Microphone access is required for the wake word.")
            return
        }
        wakeArmed = true
        wakeWordListener.localeID = STTLanguageResolver.appleLocale(for: sttLanguageSelection)
        pipeline.trailingStripPhrases = WakePhrases.stop
        wakeWordListener.startAwaitingStart()
        scheduleWakeAutoDisarm()
    }

    func disarmWakeWord() {
        wakeAutoDisarmTask?.cancel()
        wakeAutoDisarmTask = nil
        wakeMaxDurationTask?.cancel()
        wakeMaxDurationTask = nil
        wakeArmed = false
        recorder.onBuffer = nil
        wakeWordListener.stop()
    }

    /// Called when the user turns the feature off entirely in settings.
    func wakeWordEnabledChanged(to enabled: Bool) {
        wakeWordEnabled = enabled
        if !enabled { disarmWakeWord() }
    }

    private func handleWakeCommand(_ action: WakeWordListener.WakeAction) {
        guard wakeArmed, wakeWordEnabled else { return }

        switch action {
        case .start:
            // Ignore a start that lands while we're already recording/busy.
            guard pipeline.canStartRecording else { return }
            wakeInitiatedSession = true
            scheduleWakeAutoDisarm() // fresh activity — extend the window

            // Hand the mic from the idle listener to the recorder, then tee the
            // recorder's buffers back into the listener so it can hear "End
            // Comet" mid-recording — one engine live at a time.
            wakeWordListener.stop()
            recorder.onBuffer = { [weak self] buffer in
                self?.wakeWordListener.feed(buffer)
            }
            wakeWordListener.startAwaitingEnd()

            shortcutSessionController.beginManual(mode: .toggle)
            startDictation(triggerMode: .toggle)
            scheduleWakeMaxDuration()

        case .stop:
            guard wakeInitiatedSession, pipeline.canStopRecording else { return }
            stopDictation()
            // Buffer tee + listener restart happen when the pipeline returns to
            // idle (see observePipeline).

        case .keystroke(let command):
            // Keystroke commands (⌘A, ⌘Z, Return, …) only fire while idle, not
            // mid-recording — they act on the focused app, e.g. to send or edit
            // a message that was just dictated.
            guard pipeline.canStartRecording else { return }
            scheduleWakeAutoDisarm() // counts as activity
            let stroke = command.stroke
            Task { await TextInjector.pressKey(stroke.keyCode, flags: stroke.flags) }
        }
    }

    private func scheduleWakeAutoDisarm() {
        wakeAutoDisarmTask?.cancel()
        wakeAutoDisarmTask = Task { [weak self] in
            let nanos = UInt64(Self.wakeAutoDisarmInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            self?.disarmWakeWord()
        }
    }

    /// Safety net: if "End Comet" is never heard, stop the runaway recording
    /// after a hard cap so the mic doesn't stay open indefinitely.
    private func scheduleWakeMaxDuration() {
        wakeMaxDurationTask?.cancel()
        wakeMaxDurationTask = Task { [weak self] in
            let nanos = UInt64(Self.wakeMaxSessionDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            guard let self, self.wakeInitiatedSession, self.pipeline.canStopRecording else { return }
            self.stopDictation()
        }
    }

    func pasteLastTranscript() {
        guard let transcript = lastTranscriptPreview else { return }

        Task {
            await TextInjector.paste(transcript, preserveClipboard: preserveClipboard)
        }
    }

    func copyLastTranscript() {
        guard let transcript = lastTranscriptPreview else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    func requestMicrophoneAccess() {
        guard !microphoneAccessGranted else { return }

        Task {
            _ = await AudioRecorder.requestMicrophoneAccess()
            await MainActor.run {
                self.refreshPermissionSnapshot()
            }
        }
    }

    func requestAccessibilityAccess() {
        hotkeyManager.requestAccessibility()
        refreshPermissionSnapshot()
    }

    func openMicrophoneSettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func markOnboardingCompleted() {
        onboardingCompleted = true
    }

    func setHoldShortcut(_ binding: ShortcutBinding) {
        guard binding != toggleShortcut else { return }
        holdShortcut = binding
        persistShortcut(binding, forKey: "holdShortcut")
        hotkeyManager.holdBinding = binding
    }

    func setToggleShortcut(_ binding: ShortcutBinding?) {
        guard binding != holdShortcut else { return }
        toggleShortcut = binding
        persistShortcut(binding, forKey: "toggleShortcut")
        hotkeyManager.toggleBinding = binding
    }

    func hideSetupGuide() {
        showSetupGuide = false
    }

    func reopenSetupGuide() {
        showSetupGuide = true
    }

    func refreshPermissionSnapshot() {
        // Re-check Accessibility BEFORE the microphone update fires
        // objectWillChange — this way SwiftUI views observing AppState
        // re-render once and pick up both fresh values together.
        // Without this, granting Accessibility in System Settings and
        // switching back to the app would leave the UI showing
        // "Missing" for up to the polling interval.
        hotkeyManager.refreshAccessibilityStatus()
        microphoneAccessGranted = AudioRecorder.hasMicrophoneAccess
    }

    /// Re-emit HotkeyManager's `objectWillChange` from AppState so SwiftUI
    /// views observing `appState.hotkeyManager.isAccessibilityGranted`
    /// re-render the moment the underlying `@Published` flips. Without this
    /// bridge, HotkeyManager's publisher fires in isolation and Views
    /// observing AppState don't know to redraw — the badge stays "Missing"
    /// even after AXIsProcessTrusted() has flipped to true under the hood.
    private func observeHotkeyManager() {
        hotkeyManagerCancellable = hotkeyManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    private func setupHotkeys() {
        hotkeyManager.onEvent = { [weak self] event in
            guard let self else { return }

            Task { @MainActor in
                if case .cancelRequested = event {
                    self.cancelDictation()
                    return
                }

                let isBusy = !self.pipeline.canStartRecording && !self.pipeline.canStopRecording

                switch self.shortcutSessionController.handle(event: event, isBusy: isBusy) {
                case .start(let mode):
                    self.startDictation(triggerMode: mode)
                case .stop:
                    self.stopDictation()
                case .switchedToToggle:
                    self.shortcutSessionController.switchToToggleMode()
                    self.pipeline.updateTriggerMode(.toggle)
                case .none:
                    break
                }
            }
        }
    }

    func cancelDictation() {
        guard !pipeline.canStartRecording else { return }
        shortcutSessionController.reset()
        pipeline.cancel()
    }

    private func observePipeline() {
        // Use `sink` directly (no `receive(on:)`) so the cancel-watch flag
        // flips in the same turn as the phase change. The CGEvent tap reads
        // this flag from its own thread and can fire before any delayed
        // main-thread hop would complete, dropping ESC-to-cancel.
        phaseCancellable = pipeline.$phase
            .sink { [weak self] phase in
                guard let self else { return }

                switch phase {
                case .idle, .done, .error:
                    self.shortcutSessionController.reset()
                    self.hotkeyManager.cancelWatchEnabled = false
                    // A wake-initiated session just ended — stop teeing buffers
                    // and hand the mic back to the idle "Start Comet" listener.
                    if self.wakeInitiatedSession {
                        self.wakeInitiatedSession = false
                        self.wakeMaxDurationTask?.cancel()
                        self.wakeMaxDurationTask = nil
                        self.recorder.onBuffer = nil
                        self.wakeWordListener.stop()
                        if self.wakeArmed {
                            self.wakeWordListener.startAwaitingStart()
                        }
                    }
                default:
                    self.hotkeyManager.cancelWatchEnabled = true
                }

                if case .requestingMicrophonePermission = phase {
                    self.refreshPermissionSnapshot()
                }
            }
    }

    private func syncPipelineConfig() {
        pipeline.selectedSTT = selectedSTT
        pipeline.selectedLLM = selectedLLM
        pipeline.sttLanguageSelection = sttLanguageSelection
        pipeline.customVocabulary = VocabularyParser.parse(customVocabulary)
        pipeline.preserveClipboard = preserveClipboard
        pipeline.soundVolume = soundEnabled ? 1.0 : 0.0

        // `customSystemPrompt` is the rules-level override. When empty
        // we fall back to the built-in cleanup prompt. `customToneInstructions`
        // is then appended as a TONE OF VOICE section so the user's
        // style guidance composes with whichever rules-level prompt is
        // active — they can pick "default rules + my tone" without
        // having to copy the whole default prompt to add a paragraph.
        let basePrompt = customSystemPrompt.isEmpty ? Prompts.defaultCleanup : customSystemPrompt
        let trimmedTone = customToneInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTone.isEmpty {
            pipeline.systemPrompt = basePrompt
        } else {
            pipeline.systemPrompt = basePrompt + """


            TONE OF VOICE (user-supplied — apply to the cleaned output without altering content)

            \(trimmedTone)
            """
        }
    }

    var sttLanguageSelection: STTLanguageSelection {
        get { STTLanguageSelection(storageValue: sttLanguageSelectionStorage) }
        set {
            sttLanguageSelectionStorage = newValue.storageValue
            syncPipelineConfig()
        }
    }

    private func startPermissionMonitoring() {
        permissionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        permissionObservers.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let appCenter = NotificationCenter.default

        let activationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionSnapshot()
            }
        }

        let becomeActiveObserver = appCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionSnapshot()
            }
        }

        permissionObservers = [activationObserver, becomeActiveObserver]
    }

    deinit {
        permissionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func openSystemSettingsPane(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func loadShortcut(forKey key: String, fallback: ShortcutBinding) -> ShortcutBinding {
        guard let storedValue = UserDefaults.standard.string(forKey: key),
              let binding = ShortcutBinding(storageValue: storedValue) else {
            return fallback
        }
        return binding
    }

    private static func loadOptionalShortcut(forKey key: String, fallback: ShortcutBinding?) -> ShortcutBinding? {
        guard let storedValue = UserDefaults.standard.string(forKey: key) else {
            return fallback
        }

        guard storedValue != "off" else {
            return nil
        }

        return ShortcutBinding(storageValue: storedValue) ?? fallback
    }

    private func persistShortcut(_ binding: ShortcutBinding?, forKey key: String) {
        UserDefaults.standard.set(binding?.storageValue ?? "off", forKey: key)
    }

    /// Reconcile the OS login-item registration with the stored
    /// `launchAtLoginEnabled` preference. Called once at app launch
    /// (from AppDelegate) and again whenever the user toggles the
    /// setting in General Settings → Behavior.
    ///
    /// On first install with the preference defaulting ON, this fires
    /// `register()` and macOS surfaces the System Settings → General →
    /// Login Items approval prompt for the user to confirm.
    func applyLaunchAtLoginPreference() {
        let service = SMAppService.mainApp
        let want = launchAtLoginEnabled
        do {
            switch service.status {
            case .enabled:
                if !want { try service.unregister() }
            case .notRegistered, .notFound:
                if want { try service.register() }
            case .requiresApproval:
                // User has the registration but hasn't approved it in
                // System Settings yet. Nothing to force from here — the
                // OS handles the approval flow. Keep our preference
                // in sync with intent so a later approval lands in the
                // expected state.
                break
            @unknown default:
                break
            }
        } catch {
            // Non-fatal — log via os.Logger if we want diagnostics, but
            // there's nothing the user can do from here. Most failures
            // are System Settings approval-state edge cases.
        }
    }
}
