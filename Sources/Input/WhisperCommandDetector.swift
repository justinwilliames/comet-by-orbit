import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "WhisperCommand")

/// Detects "Comet …" voice commands by transcribing short spoken snippets
/// through the user's own Whisper provider (Groq/OpenAI/Deepgram/…) — the same
/// accurate engine that powers dictation — instead of Apple's on-device
/// recognizer.
///
/// It runs simple energy-based voice-activity detection: it accumulates audio
/// while you're speaking and, when you pause, sends just that snippet to the
/// provider and matches the returned text against the command table.
///
/// Two modes, driven by the owner:
///  - `.idle`: owns a mic engine; matches the start phrase + keystroke commands.
///  - `.recording`: no engine — the dictation recorder tees its buffers in via
///    `feed(_:)`; matches only the stop phrase, so you can end explicitly with
///    "Comet stop" and a thinking-pause never stops you.
final class WhisperCommandDetector {
    enum WakeAction {
        case start
        case stop
        case keystroke(VoiceCommand)
    }
    enum Mode { case idle, recording }

    /// Delivered on the main queue when a command is recognized.
    var onCommand: ((WakeAction) -> Void)?
    /// Delivered on the main queue if the mic can't start.
    var onUnavailable: ((String) -> Void)?
    /// Transcribes a 16 kHz mono WAV via the user's provider. Set by the owner.
    var transcribe: ((URL) async throws -> String)?

    // Tuning.
    private let speechThreshold: Float = 0.012   // RMS above this = speech
    private let endSilenceSeconds: Double = 0.7  // pause that ends an utterance
    private let maxUtteranceSeconds: Double = 6.0
    private let minUtteranceSeconds: Double = 0.25
    private let debounce: TimeInterval = 2.0

    private let queue = DispatchQueue(label: "team.yourorbit.OrbitDictation.whisper-cmd", qos: .userInitiated)
    private var audioEngine: AVAudioEngine?
    private var mode: Mode = .idle
    private var isActive = false

    // Utterance accumulation — confined to `queue`.
    private var utteranceFile: AVAudioFile?
    private var utteranceURL: URL?
    private var utteranceFormat: AVAudioFormat?
    private var utteranceFrames: AVAudioFramePosition = 0
    private var hadSpeech = false
    private var trailingSilence: Double = 0
    private var bufferCount = 0        // queue-confined, for level logging
    private var peakRMS: Float = 0     // queue-confined

    private var lastFire: [String: Date] = [:] // main-thread only
    private var recentSnippets: [(date: Date, text: String)] = [] // main-thread only
    private let contextWindow: TimeInterval = 4.0

    // MARK: - Control

    /// Listen on our own mic for the start phrase + keystroke commands (idle).
    func startIdle() {
        mode = .idle
        isActive = true
        startOwnEngine()
    }

    /// Listen for the stop phrase from recorder-fed buffers (during recording).
    func startRecording() {
        stopEngine()
        mode = .recording
        isActive = true
        queue.async { self.resetUtterance() }
    }

    /// Feed a captured buffer from the dictation recorder (recording mode).
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard isActive, mode == .recording else { return }
        ingest(buffer)
    }

    func stop() {
        isActive = false
        stopEngine()
        queue.async { self.discardUtterance() }
    }

    // MARK: - Engine

    private func startOwnEngine() {
        stopEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            emitUnavailable("No audio input available for voice commands.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            emitUnavailable("Couldn't start the voice-command microphone: \(error.localizedDescription)")
            return
        }
        audioEngine = engine
        queue.async { self.resetUtterance() }
        logger.info("Whisper command detector listening (idle)")
    }

    private func stopEngine() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    // MARK: - Capture → utterance (queue-confined)

    /// Hand the raw buffer to our serial queue, exactly as `AudioRecorder`
    /// hands buffers to its writer queue (tap buffers survive this in practice).
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard isActive else { return }
        queue.async { self.handle(buffer) }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard isActive else { return }
        let rms = Self.rms(buffer)
        let sampleRate = buffer.format.sampleRate
        let bufferDuration = sampleRate > 0 ? Double(buffer.frameLength) / sampleRate : 0

        // Level diagnostics: log the peak RMS roughly once a second so we can
        // see whether audio is arriving and tune the speech threshold.
        bufferCount += 1
        peakRMS = max(peakRMS, rms)
        if bufferCount >= 48 {
            logger.info("audio level: peakRMS=\(String(format: "%.4f", self.peakRMS), privacy: .public) (threshold \(String(format: "%.4f", self.speechThreshold), privacy: .public))")
            bufferCount = 0
            peakRMS = 0
        }

        if rms >= speechThreshold {
            if utteranceFile == nil { openUtterance(format: buffer.format) }
            hadSpeech = true
            trailingSilence = 0
            writeUtterance(buffer)
        } else if utteranceFile != nil {
            // Inside an utterance — keep a little trailing silence, then end it.
            writeUtterance(buffer)
            trailingSilence += bufferDuration
            if hadSpeech, trailingSilence >= endSilenceSeconds {
                finalizeUtterance()
                return
            }
        }

        if let format = utteranceFormat, format.sampleRate > 0,
           Double(utteranceFrames) / format.sampleRate >= maxUtteranceSeconds {
            finalizeUtterance()
        }
    }

    private func openUtterance(format: AVAudioFormat) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        do {
            utteranceFile = try AVAudioFile(forWriting: url, settings: format.settings)
            utteranceURL = url
            utteranceFormat = format
            utteranceFrames = 0
            hadSpeech = false
            trailingSilence = 0
        } catch {
            logger.error("Failed to open utterance file: \(error.localizedDescription, privacy: .public)")
            utteranceFile = nil
        }
    }

    private func writeUtterance(_ buffer: AVAudioPCMBuffer) {
        guard let file = utteranceFile else { return }
        do {
            try file.write(from: buffer)
            utteranceFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            logger.error("Utterance write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resetUtterance() {
        utteranceFile = nil
        utteranceURL = nil
        utteranceFormat = nil
        utteranceFrames = 0
        hadSpeech = false
        trailingSilence = 0
    }

    private func discardUtterance() {
        if let url = utteranceURL { try? FileManager.default.removeItem(at: url) }
        resetUtterance()
    }

    private func finalizeUtterance() {
        guard let url = utteranceURL, let format = utteranceFormat else {
            resetUtterance()
            return
        }
        let duration = format.sampleRate > 0 ? Double(utteranceFrames) / format.sampleRate : 0
        let hadSpeech = self.hadSpeech
        let currentMode = mode
        utteranceFile = nil // flush/close
        resetUtterance()

        guard hadSpeech, duration >= minUtteranceSeconds else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        logger.info("Utterance captured (\(Int(duration * 1000), privacy: .public) ms) → transcribing")
        Task { await self.transcribeAndMatch(url: url, mode: currentMode) }
    }

    private func transcribeAndMatch(url: URL, mode: Mode) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let transcribe else { return }

        let wavURL: URL
        do {
            wavURL = try AudioNormalization.normalize(url)
        } catch {
            logger.error("Snippet normalize failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let text: String
        do {
            text = try await transcribe(wavURL)
        } catch {
            logger.error("Snippet transcription failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        DispatchQueue.main.async { [weak self] in self?.match(text, mode: mode) }
    }

    // MARK: - Matching (main thread)

    private func match(_ transcript: String, mode: Mode) {
        guard isActive else { return }
        let snippet = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        logger.info("Snippet heard: “\(transcript, privacy: .public)” → normalized “\(snippet, privacy: .public)”")
        guard !snippet.isEmpty else { return }

        // Keep a short rolling context so a natural pause between the keyword
        // and the action ("Comet… copy") still matches as "comet copy".
        let now = Date()
        recentSnippets.append((now, snippet))
        recentSnippets.removeAll { now.timeIntervalSince($0.date) > contextWindow }
        let phrase = recentSnippets.map(\.text).joined(separator: " ")

        switch mode {
        case .recording:
            if Self.contains(phrase, VoiceCommands.stopPhrases) {
                recentSnippets.removeAll()
                fire(.stop, key: "stop")
            }
        case .idle:
            if Self.contains(phrase, VoiceCommands.startPhrases) {
                recentSnippets.removeAll()
                fire(.start, key: "start")
                return
            }
            for command in VoiceCommands.keystroke where Self.contains(phrase, command.phrases) {
                recentSnippets.removeAll()
                fire(.keystroke(command), key: command.id)
                return
            }
        }
    }

    private static func contains(_ phrase: String, _ targets: [String]) -> Bool {
        targets.contains { phrase.contains($0) }
    }

    private func fire(_ action: WakeAction, key: String) {
        let now = Date()
        if let last = lastFire[key], now.timeIntervalSince(last) <= debounce { return }
        lastFire[key] = now
        logger.info("Voice command: \(key, privacy: .public)")
        onCommand?(action)
    }

    private func emitUnavailable(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onUnavailable?(message) }
    }

    // MARK: - RMS

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        if let data = buffer.floatChannelData {
            var sum: Float = 0
            for i in 0 ..< count { let s = data[0][i]; sum += s * s }
            return (sum / Float(count)).squareRoot()
        }
        if let data = buffer.int16ChannelData {
            var sum: Float = 0
            for i in 0 ..< count { let s = Float(data[0][i]) / Float(Int16.max); sum += s * s }
            return (sum / Float(count)).squareRoot()
        }
        return 0
    }
}

