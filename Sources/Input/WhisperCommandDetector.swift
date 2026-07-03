import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "WhisperCommand")

/// Detects "Comet …" voice commands by transcribing short spoken snippets
/// through the user's own Whisper provider (Groq/OpenAI/Deepgram/…) — the same
/// accurate engine that powers dictation — instead of Apple's on-device
/// recognizer.
///
/// Energy-based voice-activity detection accumulates audio from speech onset,
/// ends the snippet ~1s after you stop, and sends just that snippet to the
/// provider. Matches the returned text against the command table.
///
/// Two modes:
///  - `.idle`: owns a mic engine; matches the start phrase + keystroke commands.
///  - `.recording`: no engine — the dictation recorder tees buffers in via
///    `feed(_:)`; matches only the stop phrase.
///
/// THREADING: all detection state is confined to `queue`. Control methods
/// (start/stop) manage the AVAudioEngine on the caller's thread and flip state
/// via `queue`. Tap/fed buffers are deep-copied (they're only valid during the
/// callback) and handed to `queue`. Callbacks (`onCommand`/`onUnavailable`/
/// `onTranscriptionError`) are always delivered on the main queue.
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
    /// Delivered on the main queue (debounced) when snippet transcription keeps
    /// failing — so a bad key / offline provider isn't a silent dead end.
    var onTranscriptionError: ((String) -> Void)?
    /// Transcribes a 16 kHz mono WAV via the user's provider. Set by the owner.
    var transcribe: ((URL) async throws -> String)?

    // Tuning.
    private let onsetThreshold: Float = 0.006     // RMS that starts/sustains a capture (tuned for quiet mics)
    private let endSilenceSeconds: Double = 0.7   // silence after speech that ends the snippet (shorter = snappier commands; the rolling context window re-joins a split "Comet… start")
    private let maxCaptureSeconds: Double = 4.0    // safety cap
    private let minUtteranceSeconds: Double = 0.4  // ignore transient blips
    private let commandMaxSeconds: Double = 2.5    // don't upload utterances longer than this — commands are short, so longer audio is ordinary speech/dictation, never a command. Skipping it protects the shared provider quota (the top cause of 429s that drop real commands).
    private let debounce: TimeInterval = 2.0        // per-command re-fire guard
    private let minUploadInterval: TimeInterval = 1.0 // rate cap: don't start uploads faster than this
    private let errorSignalInterval: TimeInterval = 20 // debounce the user-facing error signal

    private let queue = DispatchQueue(label: "team.yourorbit.OrbitDictation.whisper-cmd", qos: .userInitiated)

    // Engine — created/started/stopped on the control (main) thread only.
    private var audioEngine: AVAudioEngine?

    // ── All state below is QUEUE-CONFINED ──────────────────────────────────
    private var isActive = false
    private var mode: Mode = .idle
    /// Bumped on every start/stop so a buffer or transcription result from a
    /// superseded session can't act in the wrong mode.
    private var session = 0

    private var utteranceFile: AVAudioFile?
    private var utteranceURL: URL?
    private var utteranceFormat: AVAudioFormat?
    private var utteranceFrames: AVAudioFramePosition = 0
    private var capturing = false
    private var trailingSilence: Double = 0

    private var transcribing = false          // single in-flight upload (rate/cost guard)
    private var lastUploadAt = Date.distantPast
    private var lastErrorSignalAt = Date.distantPast

    private var lastFire: [String: Date] = [:]
    private var recentSnippets: [(date: Date, text: String)] = []
    private let contextWindow: TimeInterval = 4.0

    // MARK: - Control (caller thread)

    /// Listen on our own mic for the start phrase + keystroke commands (idle).
    func startIdle() {
        queue.async {
            self.isActive = true
            self.mode = .idle
            self.session &+= 1
            self.resetUtterance()
        }
        startOwnEngine()
    }

    /// Listen for the stop phrase from recorder-fed buffers (during recording).
    func startRecording() {
        stopEngine()
        queue.async {
            self.isActive = true
            self.mode = .recording
            self.session &+= 1
            self.resetUtterance()
        }
    }

    /// Feed a captured buffer from the dictation recorder (recording mode).
    func feed(_ buffer: AVAudioPCMBuffer) {
        ingest(buffer)
    }

    func stop() {
        stopEngine()
        queue.async {
            self.isActive = false
            self.session &+= 1
            self.discardUtterance()
        }
    }

    // MARK: - Engine (caller thread)

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
        logger.info("Voice-command detector listening")
    }

    private func stopEngine() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    // MARK: - Capture → utterance (queue-confined)

    /// Deep-copy the buffer on the audio thread (it's only valid during the
    /// callback), then process on our serial queue.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.commandDetectorCopy() else { return }
        queue.async { self.handle(copy) }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard isActive else { return }
        let rms = Self.rms(buffer)
        let sampleRate = buffer.format.sampleRate
        let bufferDuration = sampleRate > 0 ? Double(buffer.frameLength) / sampleRate : 0

        if capturing {
            writeUtterance(buffer)
            if rms >= onsetThreshold {
                trailingSilence = 0
            } else {
                trailingSilence += bufferDuration
                if trailingSilence >= endSilenceSeconds {
                    finalizeUtterance()
                    return
                }
            }
            if sampleRate > 0, Double(utteranceFrames) / sampleRate >= maxCaptureSeconds {
                finalizeUtterance()
            }
        } else if rms >= onsetThreshold {
            openUtterance(format: buffer.format)
            if utteranceFile != nil {
                capturing = true
                trailingSilence = 0
                writeUtterance(buffer)
            }
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
        } catch {
            logger.error("Failed to open utterance file: \(error.localizedDescription, privacy: .public)")
            // Leave no half-open state behind.
            utteranceFile = nil
            utteranceURL = nil
            utteranceFormat = nil
            capturing = false
            trailingSilence = 0
            try? FileManager.default.removeItem(at: url)
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
        capturing = false
        trailingSilence = 0
    }

    private func discardUtterance() {
        if let url = utteranceURL { try? FileManager.default.removeItem(at: url) }
        resetUtterance()
    }

    private func finalizeUtterance() {
        let url = utteranceURL
        let format = utteranceFormat
        let frames = utteranceFrames
        let capturedMode = mode
        let capturedSession = session
        utteranceFile = nil // flush/close
        resetUtterance()

        guard let url, let format else { return }
        let duration = format.sampleRate > 0 ? Double(frames) / format.sampleRate : 0
        guard duration >= minUtteranceSeconds else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Commands are short. A longer utterance is ordinary speech or
        // dictation-length audio — never a command — so don't spend the shared
        // provider quota transcribing it. This is the biggest source of the
        // rate-limit 429s that were silently dropping real commands.
        guard duration <= commandMaxSeconds else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Rate/cost guard: at most one upload in flight, and not faster than
        // minUploadInterval. Drop excess snippets rather than storm the provider
        // (which shares a key/quota with real dictation).
        let now = Date()
        guard !transcribing, now.timeIntervalSince(lastUploadAt) >= minUploadInterval else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        transcribing = true
        lastUploadAt = now
        Task { await self.transcribeAndMatch(url: url, mode: capturedMode, session: capturedSession) }
    }

    private func transcribeAndMatch(url: URL, mode: Mode, session: Int) async {
        defer {
            try? FileManager.default.removeItem(at: url)
            queue.async { self.transcribing = false }
        }
        guard let transcribe else { return }

        let wavURL: URL
        do {
            wavURL = try AudioNormalization.normalize(url)
        } catch {
            logger.error("Snippet normalize failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        do {
            let text = try await Self.transcribeWithRateLimitRetry(wavURL, using: transcribe)
            queue.async { self.match(text, mode: mode, session: session) }
        } catch {
            // No transcript content in logs (it can be bystander speech).
            logger.error("Snippet transcription failed")
            signalTranscriptionError()
        }
    }

    /// Transcribe, retrying ONCE on a rate-limit (429). Command snippets share
    /// the provider's per-minute quota with dictation, so a burst can 429 a
    /// real command — which, before this, dropped it silently and forced the
    /// user to repeat. A single short-backoff retry recovers it. Non-rate-limit
    /// errors are not retried (a bad key or offline provider would just fail
    /// again, and the debounced error signal already surfaces those).
    private static func transcribeWithRateLimitRetry(
        _ url: URL,
        using transcribe: (URL) async throws -> String
    ) async throws -> String {
        do {
            return try await transcribe(url)
        } catch {
            guard isRateLimited(error) else { throw error }
            try? await Task.sleep(for: .seconds(2))
            return try await transcribe(url)
        }
    }

    private static func isRateLimited(_ error: Error) -> Bool {
        if case let STTError.apiError(_, _, code) = error, code == 429 { return true }
        let description = error.localizedDescription.lowercased()
        return description.contains("429") || description.contains("rate limit")
    }

    // MARK: - Matching (queue-confined)

    private func match(_ transcript: String, mode: Mode, session: Int) {
        guard isActive, session == self.session else { return }
        let snippet = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !snippet.isEmpty else { return }

        // Short rolling context so a natural pause between the keyword and the
        // action ("Comet… copy") still matches as "comet copy".
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
        // Async to main so the handler (which calls back into stop()/
        // startRecording()) never unwinds our own call stack.
        DispatchQueue.main.async { [weak self] in self?.onCommand?(action) }
    }

    private func signalTranscriptionError() {
        queue.async {
            let now = Date()
            guard now.timeIntervalSince(self.lastErrorSignalAt) >= self.errorSignalInterval else { return }
            self.lastErrorSignalAt = now
            DispatchQueue.main.async { [weak self] in
                self?.onTranscriptionError?("Voice commands can't reach your speech provider — check its API key in Settings ▸ Providers.")
            }
        }
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

private extension AVAudioPCMBuffer {
    /// A format-agnostic independent deep copy, so a tap/fed buffer stays valid
    /// after the audio callback returns. Copies raw bytes per audio-buffer, so
    /// it works for interleaved and non-interleaved, float and int formats.
    func commandDetectorCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0 ..< source.count {
            guard let src = source[index].mData, let dst = destination[index].mData else { return nil }
            let bytes = Int(min(source[index].mDataByteSize, destination[index].mDataByteSize))
            memcpy(dst, src, bytes)
        }
        return copy
    }
}
