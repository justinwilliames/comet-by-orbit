import AVFoundation
import Foundation
import os
import Speech

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "WakeWord")

/// The wake phrases Comet recognizes. Any accepted verb combined with any
/// accepted noun matches, so the user never has to remember one exact wording:
/// "Start Comet", "Hey Comet", "Start Dictation", "Hey Dictation" all start;
/// "Stop Comet", "End Comet", "Stop Dictation", "End Dictation" all stop.
enum WakePhrases {
    /// User-facing description of the accepted phrasings.
    static let startDescription = "“Start Comet” / “Hey Comet” (or “Start/Hey Dictation”)"
    static let stopDescription = "“Stop Comet” / “End Comet” (or “Stop/End Dictation”)"

    private static let startVerbs = ["start", "hey", "star"] // "star" = common mishear of "start"
    private static let stopVerbs = ["stop", "end"]
    /// The noun, plus how the on-device recognizer commonly mishears
    /// "comet" / "dictation".
    private static let nouns = [
        "comet", "komet", "comit", "comett", "comment", "commit",
        "dictation", "diction", "dictating",
    ]

    /// Normalized (lowercase, alphanumeric-split) phrases that START recording.
    static let start: [String] = phrases(from: startVerbs)
    /// Normalized phrases that STOP recording.
    static let stop: [String] = phrases(from: stopVerbs)
    /// Phrases that inject a Return keypress into the focused app — recognized
    /// while armed and idle (e.g. to send a just-pasted message). Two-word
    /// phrases only, so a stray "send"/"return" doesn't fire a Return into
    /// whatever's focused.
    static let returnKey = [
        "press return", "press enter", "hit return", "hit enter",
        "new line", "send message", "send dictation",
    ]

    private static func phrases(from verbs: [String]) -> [String] {
        verbs.flatMap { verb in nouns.map { "\(verb) \($0)" } }
    }
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
    enum Command { case start, end, pressReturn }
    enum Mode { case awaitingStart, awaitingEnd }

    /// Delivered on the main queue when a command phrase is detected.
    var onCommand: ((Command) -> Void)?
    /// Delivered on the main queue if listening can't start.
    var onUnavailable: ((String) -> Void)?

    var localeID: String = "en-US"

    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var mode: Mode = .awaitingStart
    private var usesOwnEngine = true
    private var isActive = false

    /// Bumped on every teardown. A recognition task's completion handler fires
    /// asynchronously and can arrive AFTER we've already torn its session down;
    /// gating restarts on a matching generation stops those stale callbacks
    /// from relaunching — the feedback loop (teardown → endAudio → isFinal →
    /// restart → teardown …) that pinned the recognizer at ~10 restarts/sec.
    private var generation = 0
    /// Restart timestamps (main-thread only) for the runaway circuit breaker.
    private var restartTimes: [Date] = []

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
        // Captured AFTER teardown bumped the counter — this is THIS session's id.
        let myGeneration = currentGeneration()

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
            // Ignore callbacks from a session we've already superseded. This is
            // what breaks the restart feedback loop: our own teardown() calls
            // endAudio(), which makes the OLD task deliver a final result — and
            // without this guard that final result would schedule yet another
            // restart, forever.
            guard self.currentGeneration() == myGeneration else { return }

            if let result {
                self.checkForCommand(in: result.bestTranscription.formattedString)
            }
            if let error {
                logger.error("Wake recognition error: \(error.localizedDescription, privacy: .public)")
            }
            // On-device continuous recognition ends itself (~1 min cap) or
            // errors out; restart (backed off + rate-limited) to keep listening.
            if error != nil || (result?.isFinal ?? false) {
                self.scheduleRestart(generation: myGeneration)
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
        logger.info("Wake listening: mode=\(String(describing: mode), privacy: .public) ownEngine=\(useOwnEngine, privacy: .public)")
    }

    private func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// Restart the session after a small backoff, but only if it's still the
    /// current generation and we haven't been thrashing. All main-thread.
    private func scheduleRestart(generation gen: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.currentGeneration() == gen else { return }

            // Circuit breaker: if sessions keep dying immediately (e.g. a
            // virtual/aggregate audio device the recognizer can't hold), stop
            // looping and report it instead of thrashing the mic.
            let now = Date()
            self.restartTimes.append(now)
            self.restartTimes.removeAll { now.timeIntervalSince($0) > 10 }
            if self.restartTimes.count > 8 {
                logger.error("Wake recognition restarting too often — disabling to avoid a loop")
                self.restartTimes.removeAll()
                self.emitUnavailable("The wake word kept losing the microphone — this can happen with virtual or aggregate audio devices. Turn it off and on to retry, or use the shortcut.")
                self.stop()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.isActive, self.currentGeneration() == gen else { return }
                self.beginSession(mode: self.mode, useOwnEngine: self.usesOwnEngine)
            }
        }
    }

    private func teardown() {
        lock.lock()
        generation &+= 1 // invalidates the outgoing session's async callbacks
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
        switch mode {
        case .awaitingStart:
            // Idle: either start dictation, or press Return in the focused app.
            if Self.matches(tail, WakePhrases.start) { fire(.start) }
            else if Self.matches(tail, WakePhrases.returnKey) { fire(.pressReturn) }
        case .awaitingEnd:
            // Recording: only the stop phrase is meaningful.
            if Self.matches(tail, WakePhrases.stop) { fire(.end) }
        }
    }

    private static func matches(_ tail: String, _ targets: [String]) -> Bool {
        targets.contains { tail.contains($0) }
    }

    private func fire(_ command: Command) {
        let key = String(describing: command)
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
