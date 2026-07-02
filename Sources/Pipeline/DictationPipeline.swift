import AppKit
import AVFoundation
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "Pipeline")

@MainActor
final class DictationPipeline: ObservableObject {
    static let waveformSampleCount = 28

    @Published private(set) var phase: PipelinePhase = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var audioSamples: [Float] = Array(repeating: 0, count: DictationPipeline.waveformSampleCount)
    @Published private(set) var lastResult: PipelineResult?
    @Published private(set) var activeTriggerMode: RecordingTriggerMode = .hold
    /// True when we haven't heard audible input for ~1.3s while recording.
    /// Use this to prompt the user to check their mic/input device.
    @Published private(set) var isHearingSilence: Bool = false

    private var silentSampleCount: Int = 0
    private static let silenceLevelThreshold: Float = 0.05
    private static let silenceTickThreshold: Int = 60  // ~1.3s at ~47Hz

    // Voice-activity gate thresholds (applied to raw per-buffer RMS captured
    // by AudioRecorder). STT providers — Whisper especially — hallucinate
    // confident-sounding text on silent audio ("Thanks for watching!"), so
    // we skip STT entirely when a recording doesn't contain enough speech.
    //
    // The gate combines three signals so a single loud click or steady hum
    // doesn't get mistaken for speech:
    //   1. Total duration must exceed `minRecordingSeconds`.
    //   2. An adaptive threshold is derived from the quietest observed
    //      buffer (noise floor) so quiet rooms and noisy cafés are handled
    //      differently. `absoluteFloorRMS` prevents a dead channel from
    //      passing via 0 × multiplier == 0.
    //   3. The cumulative time spent above that threshold must exceed
    //      `minVoicedSeconds`; a single spike can beat the threshold once
    //      but not for long enough to be speech.
    private static let minRecordingSeconds: Double = 0.3
    private static let minVoicedSeconds: Double = 0.3
    private static let noiseFloorMultiplier: Float = 3.0
    private static let absoluteFloorRMS: Float = 0.005

    private let recorder: AudioRecorder
    private let registry: ProviderRegistry
    private let historyStore: PipelineHistoryStore
    private let httpClient: ProviderHTTPClient?

    var selectedSTT: STTProviderID = .apple
    var selectedLLM: LLMProviderID = .anthropic
    var sttLanguageSelection: STTLanguageSelection = .auto
    /// Normalized phrases to strip from the end of a transcript — set by the
    /// wake word so a captured "End Comet" doesn't get pasted.
    var trailingStripPhrases: [String] = []
    var customVocabulary: [String] = []
    var systemPrompt: String = Prompts.defaultCleanup
    var preserveClipboard: Bool = true
    var soundVolume: Float = 1.0

    /// Fires with the final pasted text right after `TextInjector.paste`
    /// returns. Used by the learning module to snapshot the focused field
    /// before the user starts editing.
    var onPasteCompleted: ((String) -> Void)?

    private var audioLevelCancellable: AnyCancellable?
    private var microphoneRequestTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?

    init(
        recorder: AudioRecorder,
        registry: ProviderRegistry,
        historyStore: PipelineHistoryStore,
        httpClient: ProviderHTTPClient? = nil
    ) {
        self.recorder = recorder
        self.registry = registry
        self.historyStore = historyStore
        self.httpClient = httpClient
    }

    var canStartRecording: Bool {
        switch phase {
        case .idle, .done, .error:
            return true
        default:
            return false
        }
    }

    var canStopRecording: Bool {
        switch phase {
        case .starting, .recording:
            return true
        default:
            return false
        }
    }

    var statusTitle: String {
        switch phase {
        case .idle:
            return "Ready to Dictate"
        case .requestingMicrophonePermission:
            return "Waiting for Microphone Access"
        case .starting:
            return "Starting Recorder"
        case .recording:
            return activeTriggerMode == .hold ? "Listening" : "Recording"
        case .normalizingAudio:
            return "Normalizing Audio"
        case .transcribing:
            return "Transcribing"
        case .cleaningTranscript:
            return "Cleaning Transcript"
        case .pasting:
            return "Pasting Text"
        case .done:
            return "Finished"
        case .error:
            return "Error"
        }
    }

    var statusDetail: String? {
        switch phase {
        case .idle:
            return "Use the menu bar to start and stop dictation."
        case .requestingMicrophonePermission:
            return "Approve microphone access to begin recording."
        case .starting:
            return activeTriggerMode == .hold
                ? "Preparing a hold-to-talk recording."
                : "Preparing a toggle recording."
        case .recording:
            return activeTriggerMode == .hold
                ? "Speak now, then release your shortcut to stop."
                : "Speak now, then use your shortcut again or press Stop."
        case .normalizingAudio:
            return "Converting the captured audio to 16 kHz mono WAV."
        case .transcribing:
            return "Sending the recording to \(selectedSTT.displayName)."
        case .cleaningTranscript:
            return "Polishing the raw transcript before paste."
        case .pasting:
            return "Injecting the transcript into the active app."
        case .done(let text):
            return text
        case .error(let message):
            return message
        }
    }

    func startRecording(triggerMode: RecordingTriggerMode = .hold) {
        guard canStartRecording else { return }

        cancelResetTask()
        if case .done = phase { phase = .idle }
        if case .error = phase { phase = .idle }
        activeTriggerMode = triggerMode

        microphoneRequestTask?.cancel()
        microphoneRequestTask = Task { [weak self] in
            await self?.requestMicrophoneAccessAndBeginRecording()
        }
    }

    func updateTriggerMode(_ triggerMode: RecordingTriggerMode) {
        activeTriggerMode = triggerMode
    }

    func stopAndProcess() {
        guard canStopRecording else { return }

        cancelResetTask()
        microphoneRequestTask?.cancel()
        microphoneRequestTask = nil

        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        audioLevel = 0

        recorder.onRecordingReady = nil

        guard let stopped = recorder.stopRecording() else {
            resetAudioSamples()
            presentError("No audio was captured.")
            return
        }

        playSound(.pop)

        resetAudioSamples()
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.processRecording(at: stopped.url, metrics: stopped.metrics)
        }
    }

    func cancel() {
        microphoneRequestTask?.cancel()
        microphoneRequestTask = nil

        processingTask?.cancel()
        processingTask = nil

        cancelResetTask()

        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        recorder.onRecordingReady = nil
        _ = recorder.stopRecording()
        recorder.cleanup()

        audioLevel = 0
        resetAudioSamples()
        activeTriggerMode = .hold
        phase = .idle
    }

    func presentError(_ message: String) {
        logger.error("Pipeline error: \(message, privacy: .public)")
        phase = .error(message)
        scheduleResetToIdle()
    }

    private func requestMicrophoneAccessAndBeginRecording() async {
        defer {
            microphoneRequestTask = nil
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            beginRecording()
        case .notDetermined:
            phase = .requestingMicrophonePermission
            // The system permission dialog can linger indefinitely if the user
            // ignores it. Cap the wait so the pipeline can recover instead of
            // hanging forever in `.requestingMicrophonePermission`.
            let granted = await withTaskGroup(of: Bool?.self, returning: Bool?.self) { group in
                group.addTask { await AudioRecorder.requestMicrophoneAccess() }
                group.addTask {
                    try? await Task.sleep(for: .seconds(30))
                    return nil
                }
                defer { group.cancelAll() }
                return await group.next() ?? nil
            }
            guard !Task.isCancelled else { return }

            switch granted {
            case .some(true):
                beginRecording()
            case .some(false):
                presentError("Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone.")
            case .none:
                presentError("Microphone permission request timed out. Try again or grant access in System Settings > Privacy & Security > Microphone.")
            }
        case .restricted, .denied:
            presentError("Microphone access is unavailable. Enable it in System Settings > Privacy & Security > Microphone.")
        @unknown default:
            presentError("Comet could not determine microphone permissions.")
        }
    }

    private func beginRecording() {
        guard !recorder.isRecording else { return }

        // Move out of `.idle` before touching the recorder so stop events are
        // never dropped even if the user stops immediately.
        phase = .starting

        recorder.onRecordingReady = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard case .starting = self.phase else { return }

                self.phase = .recording
                self.playSound(.dictationChime)
            }
        }

        do {
            try recorder.startRecording()
        } catch {
            presentError(error.localizedDescription)
            return
        }

        resetAudioSamples()
        audioLevelCancellable = recorder.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self else { return }
                self.audioLevel = level
                self.pushAudioSample(level)
            }

        logger.info("Recording session started")
    }

    private func processRecording(at recordedURL: URL, metrics: RecordingMetrics) async {
        defer {
            processingTask = nil
        }

        defer {
            recorder.cleanup()
        }

        // Skip STT entirely if the recording doesn't contain enough speech.
        // See `minRecordingSeconds` / `noiseFloorMultiplier` comments above for
        // rationale. Providers hallucinate confidently on silent audio, so
        // gating aggressively here saves both a request and a bad paste.
        if !recordingHasSpeech(metrics: metrics) {
            try? FileManager.default.removeItem(at: recordedURL)
            dismissForNoSpeech()
            return
        }

        do {
            phase = .normalizingAudio
            let wavURL = try await Task.detached(priority: .userInitiated) {
                try AudioNormalization.normalize(recordedURL)
            }.value
            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }

            phase = .transcribing
            guard let sttProvider = registry.makeSTTProvider(for: selectedSTT) else {
                throw STTError.missingAPIKey(provider: selectedSTT)
            }

            // Warm the LLM connection in parallel with STT. By the time the
            // transcript lands, the TLS handshake to the cleanup endpoint is
            // already done, which saves ~200–500 ms on cold paths.
            if let client = httpClient,
               let llmProvider = registry.makeLLMProvider(for: selectedLLM),
               let origin = llmProvider.endpointOrigin {
                client.warmConnection(to: origin)
            }

            let transcribedText = try await sttProvider.transcribe(
                fileURL: wavURL,
                language: sttLanguageSelection,
                vocabulary: customVocabulary
            )
            // Drop a trailing wake stop-phrase (e.g. "End Comet") that the
            // recorder captured before the session was stopped.
            let rawTranscript = Self.strippingTrailingPhrases(trailingStripPhrases, from: transcribedText)
            guard let normalizedRawTranscript = normalizedTranscriptText(from: rawTranscript) else {
                dismissForNoSpeech()
                return
            }

            var cleanedTranscript = normalizedRawTranscript
            var llmModel: String?

            // Skip LLM cleanup for too-short transcripts — they're almost always noise
            // and an LLM will hallucinate conversational replies instead of cleaning text.
            let wordCount = normalizedRawTranscript.split { $0.isWhitespace }.count
            let looksLikeSpeech = normalizedRawTranscript.count >= 8 && wordCount >= 2

            if looksLikeSpeech, let llmProvider = registry.makeLLMProvider(for: selectedLLM) {
                phase = .cleaningTranscript

                // Dynamic max_tokens cap based on input length. Proper cleanup
                // produces output close to the input length — at most a modest
                // expansion when numerals replace words, punctuation gets
                // added, or a list with a header gets bulleted. Capping
                // max_tokens prevents runaway expansion loops where the model
                // paraphrases into long second-person prose or repeats the
                // same sentence.
                //
                // ~4 chars/token average × 0.5 = chars/2 tokens for the
                // cleaned output. Floor at 180 so short utterances aren't
                // truncated mid-sentence after bulleting. Tight by design;
                // the bullet-aware expansion guardrail catches any output
                // that slips through.
                let inputChars = normalizedRawTranscript.count
                let dynamicMaxTokens = max(180, inputChars / 2 + 80)

                do {
                    let response = try await llmProvider.complete(
                        request: LLMRequest(
                            systemPrompt: buildSystemPrompt(vocabulary: customVocabulary),
                            userMessage: normalizedRawTranscript,
                            maxTokens: dynamicMaxTokens
                        )
                    )

                    // Diagnostic logging — surfaces what the model actually
                    // emitted so the in-app Live Logs panel can show whether
                    // it's following the <analysis>/<output> format and what
                    // its reasoning concluded.
                    logger.info(
                        "LLM raw (first 400): \(response.text.prefix(400), privacy: .public)"
                    )

                    // Extract the cleaned text from the structured response.
                    // The system prompt instructs the model to emit
                    // <analysis>…</analysis><output>…</output>; the analysis
                    // block is reasoning we strip before paste so only the
                    // <output> content reaches the user. If the model didn't
                    // use the tags (older provider, prompt drift), fall back
                    // to the whole response text.
                    var extractedText = Self.extractCleanedOutput(from: response.text)

                    // Programmatic list-format safety net. The LLM is
                    // unreliable at bulleting on short list-shaped inputs
                    // (it sometimes treats them as already clean and echoes
                    // them back as prose). When the input has clear list
                    // signals — a list-cue word like "groceries" / "list of"
                    // plus 2+ commas — and the model's output lacks bullets,
                    // re-format programmatically rather than ship a comma jam.
                    if Self.hasListSignals(in: normalizedRawTranscript)
                        && !Self.outputContainsBullets(extractedText) {
                        if let formatted = Self.formatAsList(extractedText) {
                            logger.info(
                                "List-format safety net fired: input had list signals, LLM output didn't — applied deterministic bulletisation"
                            )
                            extractedText = formatted
                        }
                    }

                    if let normalizedCleanedTranscript = normalizedTranscriptText(from: extractedText) {
                        // Output-length sanity check. Catches runaway LLM
                        // expansion (paraphrasing into long second-person
                        // prose, sentence loops, etc.) AND the inverse —
                        // weak fallback models (Groq 8B after 70B rate-
                        // limits) compressing 47-word inputs into 5-word
                        // replies. Plus a framing-text + person-shift
                        // detector for the same fallback class, which
                        // tends to wrap output in "I've cleaned the
                        // input. Here is the output:" or refuse with
                        // "I don't have the ability to…".
                        let rawWords = normalizedRawTranscript.split { $0.isWhitespace }.count
                        let cleanedWords = normalizedCleanedTranscript.split { $0.isWhitespace }.count
                        let wordRatio = Double(cleanedWords) / Double(max(1, rawWords))
                        let charRatio = Double(normalizedCleanedTranscript.count) / Double(max(1, normalizedRawTranscript.count))
                        let outputIsBulleted = Self.outputContainsBullets(normalizedCleanedTranscript)

                        let expansionTripped: Bool
                        if outputIsBulleted {
                            expansionTripped = charRatio > 3.0
                        } else {
                            expansionTripped = wordRatio > 1.5 || charRatio > 2.0
                        }

                        // Compression guardrail. Triggered when raw is
                        // long enough to be substantive (≥10 words) and
                        // cleaned is under half its length — the failure
                        // mode where a weak model drops content. Skip on
                        // bulleted output (legitimate restructuring can
                        // tighten word count modestly) and on very short
                        // inputs (filler-only utterances legitimately
                        // collapse to nothing).
                        let compressionTripped = !outputIsBulleted
                            && rawWords >= 10
                            && wordRatio < 0.5

                        // Framing / refusal detector. The 8B fallback in
                        // particular tends to: (a) wrap its output in
                        // "I've cleaned the input. Here is the output: …",
                        // (b) refuse with "I don't have the ability to …",
                        // (c) reply meta to the speaker ("It's asking you,
                        // not me."). All produce output that does NOT
                        // start with the speaker's words.
                        let framingTripped = Self.outputLooksLikeFramingOrRefusal(normalizedCleanedTranscript)

                        if expansionTripped || compressionTripped || framingTripped {
                            let reason: String
                            if framingTripped {
                                reason = "framing/refusal pattern"
                            } else if compressionTripped {
                                reason = "compression (weak fallback model dropping content)"
                            } else {
                                reason = "expansion"
                            }
                            logger.warning(
                                "LLM cleanup guardrail tripped — \(reason, privacy: .public) (\(cleanedWords, privacy: .public)w / \(rawWords, privacy: .public)w, charRatio \(String(format: "%.2f", charRatio), privacy: .public), bulleted=\(outputIsBulleted ? "true" : "false", privacy: .public)) — using raw transcript instead"
                            )
                            cleanedTranscript = normalizedRawTranscript
                        } else {
                            cleanedTranscript = normalizedCleanedTranscript
                        }
                    } else {
                        cleanedTranscript = ""
                    }

                    llmModel = response.model
                } catch {
                    logger.warning("LLM cleanup failed, using raw transcript: \(error.localizedDescription, privacy: .public)")
                }
            }

            guard let finalTranscript = normalizedTranscriptText(from: cleanedTranscript) else {
                dismissForNoSpeech()
                return
            }

            guard !Task.isCancelled else { throw CancellationError() }

            phase = .pasting
            await TextInjector.paste(finalTranscript, preserveClipboard: preserveClipboard)

            guard !Task.isCancelled else { throw CancellationError() }

            // Mirror the start chime now that the transcript is in the
            // user's text field. Same sound bookends the dictation cycle.
            playSound(.dictationChime)

            onPasteCompleted?(finalTranscript)

            let result = PipelineResult(
                rawTranscript: normalizedRawTranscript,
                cleanedText: finalTranscript,
                sttProvider: selectedSTT,
                llmProvider: selectedLLM,
                llmModel: llmModel,
                timestamp: Date()
            )

            lastResult = result
            historyStore.add(result)

            phase = .done(finalTranscript)
            scheduleResetToIdle(after: .milliseconds(1200))

            logger.info("Pipeline finished successfully")
        } catch is CancellationError {
            logger.info("Pipeline processing cancelled")
            phase = .idle
        } catch {
            // URLSession throws URLError.cancelled when its Task is cancelled
            // mid-request; treat it as a clean cancel rather than surfacing
            // a misleading "cancelled" error banner.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                logger.info("Pipeline processing cancelled")
                phase = .idle
            } else {
                presentError(error.localizedDescription)
            }
        }
    }

    private func buildSystemPrompt(vocabulary: [String]) -> String {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return systemPrompt }
        let joined = terms.joined(separator: ", ")
        return systemPrompt + """


        Preserve these proper nouns / terms exactly as spelled when they appear \
        (do not paraphrase, translate, or correct them): \(joined).
        """
    }

    /// List-cue words that, when combined with comma-separated items in the
    /// input, are a strong signal the user wanted a bulleted list.
    private static let listCueWords: Set<String> = [
        "list", "lists",
        "groceries", "grocery",
        "shopping",
        "items",
        "to-do", "todo", "to do",
        "agenda",
        "checklist",
        "options",
        "priorities",
    ]

    /// Returns `true` if the input has the structural signals of a list:
    /// a list-cue word AND at least two commas (i.e. 3+ items).
    static func hasListSignals(in input: String) -> Bool {
        let lowered = input.lowercased()
        let hasCue = listCueWords.contains { lowered.contains($0) }
        guard hasCue else { return false }
        let commaCount = input.filter { $0 == "," }.count
        return commaCount >= 2
    }

    /// `true` if any line in `output` starts with a bullet glyph (`•`, `-`, `*`)
    /// followed by a space — the markers our list rule and rich-text paste
    /// recognise.
    static func outputContainsBullets(_ output: String) -> Bool {
        output.components(separatedBy: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
        }
    }

    /// `true` if `output` looks like model meta-commentary or a refusal —
    /// i.e. the model addressed the speaker instead of cleaning their
    /// transcript. Tightly-scoped phrase match: only flag opens that
    /// almost never appear at the start of a real dictated transcript.
    /// The Groq llama-3.1-8b fallback is the dominant source after
    /// Sir's Groq daily-token cap kicks in.
    static func outputLooksLikeFramingOrRefusal(_ output: String) -> Bool {
        let lowered = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lowered.isEmpty else { return false }

        // Phrases that almost certainly indicate the model is talking
        // ABOUT the cleanup rather than producing it. Each is a prefix
        // match on the cleaned output's first few words.
        let badPrefixes: [String] = [
            "i've cleaned",
            "i have cleaned",
            "here is the output",
            "here is the cleaned",
            "here's the cleaned",
            "here's the output",
            "the cleaned text",
            "the cleaned output",
            "i don't have the ability",
            "i cannot ",
            "i can't ",
            "i'm not able",
            "i am not able",
            "as an ai",
            "as a language model",
            "i apologize",
            "i'm sorry",
            "sorry, i ",
            "it's asking you, not me",
            "it is asking you, not me",
        ]
        return badPrefixes.contains(where: { lowered.hasPrefix($0) })
    }

    /// Deterministically reformat `text` as a bulleted list, parsing a
    /// header (anything before the first `.` or `:` that contains a list cue
    /// word) and items (whatever follows, split on commas and the conjunction
    /// "and"). Returns `nil` if the parser can't find at least 3 short items
    /// — caller should leave the text alone in that case.
    ///
    /// Designed as a safety net for when the LLM fails to bullet despite
    /// clear list signals in the input. Not a general Markdown parser.
    static func formatAsList(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try to peel off a header: text before the first `.` or `:` if it
        // contains a list cue and is reasonably short (≤ 6 words).
        var header: String? = nil
        var body = trimmed

        let separatorIndex = trimmed.firstIndex { char in
            char == "." || char == ":"
        }

        if let separatorIndex {
            let beforeSep = String(trimmed[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let afterSep = String(trimmed[trimmed.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespaces)
            let beforeLower = beforeSep.lowercased()
            let beforeWordCount = beforeSep.split { $0.isWhitespace }.count
            let containsCue = listCueWords.contains { beforeLower.contains($0) }
            if containsCue && beforeWordCount <= 6 && !afterSep.isEmpty {
                header = beforeSep
                body = afterSep
            }
        }

        // Strip terminal punctuation so the last item doesn't carry it.
        let bodyClean = body.trimmingCharacters(in: CharacterSet(charactersIn: ".!?;"))

        // Split on commas first; for each comma-segment, also split on
        // " and " / " & " to pick up the final-conjunction case
        // ("apples, bananas, and cherries").
        let rawItems = bodyClean
            .components(separatedBy: ",")
            .flatMap { segment -> [String] in
                segment.replacingOccurrences(of: " & ", with: " and ")
                    .components(separatedBy: " and ")
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Items should be short noun phrases — drop anything looking like a
        // sentence (more than 6 words). Bail entirely if too few survive.
        let items = rawItems.filter { $0.split { $0.isWhitespace }.count <= 6 }
        guard items.count >= 3 else { return nil }

        var lines: [String] = []
        if let header {
            // Use a colon header even if the source ended with a period.
            let headerClean = header.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            lines.append("\(headerClean):")
            lines.append("")
        }
        for item in items {
            lines.append("• " + capitaliseFirst(item))
        }
        return lines.joined(separator: "\n")
    }

    private static func capitaliseFirst(_ str: String) -> String {
        guard let first = str.first else { return str }
        return String(first).uppercased() + str.dropFirst()
    }

    /// Extract the cleaned text from an LLM response that follows the
    /// reflect-then-act format (`<analysis>…</analysis><output>…</output>`).
    ///
    /// The system prompt instructs the model to write a brief reasoning
    /// block before producing the cleaned text. The reasoning is for the
    /// model's own benefit (better adherence to list / person / length
    /// rules) and is stripped before paste so only the `<output>` content
    /// reaches the user.
    ///
    /// Robustness: if the response doesn't contain `<output>` tags (older
    /// provider, prompt drift, model that doesn't follow the format), the
    /// whole response is returned unchanged so the pipeline degrades to
    /// pre-reflect behaviour rather than failing. If `<output>` opens but
    /// never closes (truncation under the max_tokens cap), use everything
    /// after `<output>` to the end.
    static func extractCleanedOutput(from response: String) -> String {
        guard let openRange = response.range(of: "<output>") else {
            // No tag at all — assume the model produced raw cleaned text.
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let afterOpen = response[openRange.upperBound...]

        if let closeRange = afterOpen.range(of: "</output>") {
            return String(afterOpen[..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // <output> opened but closing tag truncated by the token cap. Use
        // everything after the open tag rather than dropping the whole
        // response.
        return String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes trailing stop-phrases (e.g. "Comet stop dictation") from a
    /// transcript. Matches on alphanumeric-normalized tokens so punctuation /
    /// casing don't defeat it, and LOOPS — recognition latency means the user
    /// often says the stop phrase two or three times before recording actually
    /// stops, so all trailing copies must be trimmed, not just one.
    static func strippingTrailingPhrases(_ phrases: [String], from text: String) -> String {
        guard !phrases.isEmpty else { return text }

        func normalized(_ s: String) -> String {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        let targets = phrases
            .map { $0.split { $0.isWhitespace }.map { normalized(String($0)) }.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
        guard !targets.isEmpty else { return text }

        var words = text.split { $0.isWhitespace }.map(String.init)
        var stripping = true
        while stripping {
            stripping = false
            let normalizedTail = words.map(normalized)
            for target in targets where target.count <= normalizedTail.count {
                if Array(normalizedTail.suffix(target.count)) == target {
                    words.removeLast(target.count)
                    stripping = true
                    break
                }
            }
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTranscriptText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.uppercased() != "EMPTY" else { return nil }
        if isKnownSilenceHallucination(trimmed) { return nil }
        return trimmed
    }

    /// Whisper (and other STT providers trained on subtitled video) confidently
    /// emit a small set of canned phrases when given silence or near-silence —
    /// "Thanks for watching!", "[Music]", "Subtitles by the Amara.org community".
    /// If the *entire* transcript matches one of these, treat it as silence.
    /// Matching is whole-transcript only so real speech that happens to contain
    /// "thank you" mid-sentence still passes through.
    private static let knownSilenceHallucinations: Set<String> = [
        "thank you for watching",
        "thanks for watching",
        "thank you for watching!",
        "thanks for watching!",
        "thank you",
        "thank you so much",
        "thank you so much for watching",
        "thanks",
        "you",
        "bye",
        "goodbye",
        "please subscribe",
        "like and subscribe",
        "don't forget to subscribe",
        "thanks for listening",
        "thank you for listening",
        "subtitles by the amara.org community",
        "music",
        "applause",
        "silence",
    ]

    private func isKnownSilenceHallucination(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let stripped = String(lowered.unicodeScalars.filter { allowed.contains($0) })
        let collapsed = stripped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return false }
        return Self.knownSilenceHallucinations.contains(collapsed)
    }

    /// Decide whether a finished recording is worth sending to STT.
    ///
    /// Three gates, all must pass: total duration, per-buffer adaptive
    /// threshold, cumulative voiced time. The noise floor is the minimum RMS
    /// observed across the recording (excluding the very first buffer, which
    /// can be a zero-fill during engine warm-up). In a silent room this is
    /// near zero; in a café it's the ambient hum, so the threshold adapts.
    private func recordingHasSpeech(metrics: RecordingMetrics) -> Bool {
        guard metrics.totalDurationSeconds >= Self.minRecordingSeconds else {
            logger.info("Skipping STT: recording too short (\(metrics.totalDurationSeconds)s)")
            return false
        }

        let series = metrics.buffers.dropFirst()
        guard !series.isEmpty, metrics.sampleRate > 0 else {
            logger.info("Skipping STT: no buffer metrics available")
            return false
        }

        let noiseFloor = series.map(\.rms).min() ?? 0
        let threshold = max(noiseFloor * Self.noiseFloorMultiplier, Self.absoluteFloorRMS)

        let voicedFrames = series.reduce(Int64(0)) { acc, buffer in
            buffer.rms > threshold ? acc + Int64(buffer.frameCount) : acc
        }
        let voicedSeconds = Double(voicedFrames) / metrics.sampleRate

        if voicedSeconds < Self.minVoicedSeconds {
            logger.info(
                "Skipping STT: voiced=\(voicedSeconds)s threshold=\(threshold) noiseFloor=\(noiseFloor)"
            )
            return false
        }
        return true
    }

    /// Close the overlay immediately and play a soft chime when the
    /// recording had no speech. Distinct from the tink→pop start/stop cues
    /// so the user knows the trigger registered but nothing was pasted.
    private func dismissForNoSpeech() {
        playSound(.bottle)
        cancelResetTask()
        activeTriggerMode = .hold
        phase = .idle
    }

    private func playSound(_ sound: NSSound?) {
        guard soundVolume > 0 else { return }
        sound?.stop()
        sound?.volume = soundVolume
        sound?.play()
    }

    private func scheduleResetToIdle(after duration: Duration = .seconds(3)) {
        cancelResetTask()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            await MainActor.run {
                guard let self else { return }

                switch self.phase {
                case .done, .error:
                    self.activeTriggerMode = .hold
                    self.phase = .idle
                default:
                    break
                }
            }
        }
    }

    private func cancelResetTask() {
        resetTask?.cancel()
        resetTask = nil
    }

    private func resetAudioSamples() {
        audioSamples = Array(repeating: 0, count: Self.waveformSampleCount)
        silentSampleCount = 0
        isHearingSilence = false
    }

    /// Append one sample to the rolling waveform buffer, dropping the oldest.
    /// Log-scales the input so quiet speech still moves the bars.
    private func pushAudioSample(_ level: Float) {
        let clamped = max(0, min(1, level))
        // log10(1 + 9x) maps [0,1] → [0,1] with a gentle low-end boost.
        let shaped = log10(1 + 9 * clamped)
        var samples = audioSamples
        samples.removeFirst()
        samples.append(shaped)
        audioSamples = samples

        if case .recording = phase {
            if clamped < Self.silenceLevelThreshold {
                silentSampleCount += 1
                if silentSampleCount >= Self.silenceTickThreshold && !isHearingSilence {
                    isHearingSilence = true
                }
            } else {
                silentSampleCount = 0
                if isHearingSilence {
                    isHearingSilence = false
                }
            }
        }
    }
}

enum PipelinePhase: Equatable {
    case idle
    case requestingMicrophonePermission
    case starting
    case recording
    case normalizingAudio
    case transcribing
    case cleaningTranscript
    case pasting
    case done(String)
    case error(String)
}

struct PipelineResult: Identifiable, Codable {
    let id: UUID
    let rawTranscript: String
    let cleanedText: String
    let sttProvider: STTProviderID
    let llmProvider: LLMProviderID
    let llmModel: String?
    let timestamp: Date

    init(
        rawTranscript: String,
        cleanedText: String,
        sttProvider: STTProviderID,
        llmProvider: LLMProviderID,
        llmModel: String?,
        timestamp: Date
    ) {
        self.id = UUID()
        self.rawTranscript = rawTranscript
        self.cleanedText = cleanedText
        self.sttProvider = sttProvider
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.timestamp = timestamp
    }
}
