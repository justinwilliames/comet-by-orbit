import AVFoundation
import Foundation
import os
import Speech

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "WakeWord")

/// The hands-free phrase that *starts* dictation. The *stop* phrase ("End
/// Comet") is shared across choices.
enum WakePhrase: String, CaseIterable, Identifiable {
    case startComet
    case comet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .startComet: "“Start Comet”"
        case .comet: "“Comet”"
        }
    }

    var shortLabel: String {
        switch self {
        case .startComet: "Start Comet"
        case .comet: "Comet"
        }
    }

    /// Normalized (lowercase, alphanumeric-split) phrases that START recording.
    /// "Start Comet" carries a few near-mishears because the two-word phrase
    /// keeps them safe; bare "Comet" is kept tight — every extra variant there
    /// is another false start waiting to happen.
    var startTargets: [String] {
        switch self {
        case .startComet: ["start comet", "star comet", "start komet", "start comit"]
        case .comet: ["comet", "komet"]
        }
    }

    /// Phrases that END recording — shared regardless of the start phrase.
    var endTargets: [String] { ["end comet", "end komet", "end comit"] }

    /// Bare single words mishear and false-trigger far more often. Drives the
    /// warning shown in settings.
    var isHighFalsePositive: Bool { self == .comet }
}

/// Always-on (while armed) voice-command detector built on Apple's
/// **on-device** speech recognizer. Audio never leaves the machine.
///
/// It runs in one of two modes, never both, so only one audio engine is ever
/// live:
///  - `.awaitingStart`: owns a lightweight engine, listens for the start
///    phrase while Comet is idle.
///  - `.awaitingEnd`: owns no engine — the dictation recorder tees its buffers
///    in via `feed(_:)` — and listens for the stop phrase mid-recording.
///
/// Callbacks are always delivered on the main queue.
final class WakeWordListener {
    enum Command { case start, end }
    enum Mode { case awaitingStart, awaitingEnd }

    /// Delivered on the main queue when a command phrase is detected.
    var onCommand: ((Command) -> Void)?
    /// Delivered on the main queue if listening can't start.
    var onUnavailable: ((String) -> Void)?

    var phrase: WakePhrase = .startComet
    var localeID: String = "en-US"

    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var mode: Mode = .awaitingStart
    private var usesOwnEngine = true
    private var isActive = false

    private var lastFireTimes: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 2.5

    // MARK: - Public control

    /// Begin listening for the start phrase (idle). Owns its own mic engine.
    func startAwaitingStart() {
        ensureAuthorized { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.emitUnavailable("Speech recognition isn't authorized. Enable it in System Settings ▸ Privacy & Security ▸ Speech Recognition.")
                return
            }
            self.beginSession(mode: .awaitingStart, useOwnEngine: true)
        }
    }

    /// Begin listening for the stop phrase during recording. Does NOT own an
    /// engine — the caller pumps audio in with `feed(_:)`.
    func startAwaitingEnd() {
        // Authorization is guaranteed by this point (we only reach here after a
        // successful start-phrase session).
        beginSession(mode: .awaitingEnd, useOwnEngine: false)
    }

    /// Feed a captured buffer (from the dictation recorder) to the recognizer.
    /// Safe to call from the audio thread. Appends an independent deep copy so
    /// the recorder's buffer — and therefore the recording that transcription
    /// reads — is never shared with the recognizer's async processing.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        guard let request else { return }
        request.append(buffer.wakeWordCopy() ?? buffer)
    }

    /// Stop listening and release the engine/recognizer.
    func stop() {
        teardown()
        isActive = false
    }

    // MARK: - Authorization

    private func ensureAuthorized(_ completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Recognition session

    private func beginSession(mode: Mode, useOwnEngine: Bool) {
        teardown()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            emitUnavailable("Speech recognizer unavailable for \(localeID).")
            return
        }
        // Privacy-critical: an always-listening feature must run fully offline.
        // If the OS can't recognize this locale on-device, refuse to stream
        // continuous audio to Apple's servers and disable the feature instead.
        guard recognizer.supportsOnDeviceRecognition else {
            emitUnavailable("On-device speech recognition isn't available for \(localeID) on this Mac, so the wake word can't run privately. Try a different language or use the shortcut.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .search

        if useOwnEngine {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                emitUnavailable("No audio input available for the wake word.")
                return
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                emitUnavailable("Couldn't start the wake-word audio engine: \(error.localizedDescription)")
                return
            }
            lock.lock(); audioEngine = engine; lock.unlock()
        }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.checkForCommand(in: result.bestTranscription.formattedString)
            }
            // On-device continuous recognition ends itself (~1 min cap) or
            // errors out; restart in the same mode to keep listening.
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async { self.restartIfActive() }
            }
        }

        lock.lock()
        self.recognizer = recognizer
        self.request = request
        self.task = task
        lock.unlock()
        self.mode = mode
        self.usesOwnEngine = useOwnEngine
        self.isActive = true
        logger.info("Wake listening: mode=\(String(describing: mode), privacy: .public) ownEngine=\(useOwnEngine, privacy: .public) phrase=\(self.phrase.rawValue, privacy: .public)")
    }

    private func restartIfActive() {
        guard isActive else { return }
        let mode = self.mode
        let ownEngine = self.usesOwnEngine
        beginSession(mode: mode, useOwnEngine: ownEngine)
    }

    private func teardown() {
        lock.lock()
        let engine = audioEngine
        let task = self.task
        let request = self.request
        self.audioEngine = nil
        self.task = nil
        self.request = nil
        self.recognizer = nil
        lock.unlock()

        task?.cancel()
        request?.endAudio()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Matching

    private func checkForCommand(in transcript: String) {
        let words = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return }

        // Only inspect the tail so a phrase from a while ago can't re-match.
        let tail = words.suffix(5).joined(separator: " ")
        let targets = mode == .awaitingStart ? phrase.startTargets : phrase.endTargets
        for target in targets where tail.contains(target) {
            fire(mode == .awaitingStart ? .start : .end)
            return
        }
    }

    private func fire(_ command: Command) {
        let key = command == .start ? "start" : "end"
        let now = Date()
        lock.lock()
        let last = lastFireTimes[key] ?? .distantPast
        let allowed = now.timeIntervalSince(last) > debounceInterval
        if allowed { lastFireTimes[key] = now }
        lock.unlock()
        guard allowed else { return }

        logger.info("Wake command detected: \(key, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onCommand?(command) }
    }

    private func emitUnavailable(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onUnavailable?(message) }
    }
}

private extension AVAudioPCMBuffer {
    /// A format-agnostic independent deep copy of this buffer's audio, so a
    /// downstream reader can't affect the source buffer.
    func wakeWordCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0 ..< min(source.count, destination.count) {
            guard let src = source[index].mData, let dst = destination[index].mData else { continue }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        return copy
    }
}
