import AVFoundation
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "AudioRecorder")

/// Records microphone input to a temporary file using `AVAudioEngine`.
///
/// The engine writes buffers in the input node's native format. The pipeline
/// normalizes that file to 16 kHz mono WAV before sending it to STT.
final class AudioRecorder: ObservableObject {
    @Published var audioLevel: Float = 0
    @Published private(set) var isRecording = false

    /// Fires once when the first non-silent buffer arrives.
    var onRecordingReady: (() -> Void)?

    /// Optional tee of every captured buffer, called on the audio thread.
    /// Used by the wake word to listen for the "End Comet" stop phrase while
    /// recording, without opening a second microphone engine.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private let fileQueue = DispatchQueue(label: "team.yourorbit.OrbitDictation.audio-file", qos: .userInitiated)

    private var readyFired = false
    private var smoothedLevel: Float = 0
    /// Level updates are throttled to ~30 Hz on the main thread; the tap
    /// callback runs at ~47 Hz so publishing every sample is wasteful.
    private var lastLevelPublishTime: CFAbsoluteTime = 0

    private var metricSampleRate: Double = 0
    private var metricTotalFrames: Int64 = 0
    private var bufferMetrics: [BufferMetric] = []

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func startRecording() throws {
        guard !isRecording else { return }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioError.noInputDevice
        }

        cleanup()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noInputDevice
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        let file = try AVAudioFile(forWriting: tempURL, settings: inputFormat.settings)

        readyFired = false
        smoothedLevel = 0
        audioLevel = 0
        audioEngine = engine
        audioFile = file
        tempFileURL = tempURL
        metricSampleRate = inputFormat.sampleRate
        metricTotalFrames = 0
        bufferMetrics.removeAll(keepingCapacity: true)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleIncomingBuffer(buffer)
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioEngine = nil
            audioFile = nil
            tempFileURL = nil
            throw AudioError.recordingFailed("Audio engine failed to start: \(error.localizedDescription)")
        }

        isRecording = true
        logger.info(
            "Recording started. sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)"
        )
    }

    func stopRecording() -> (url: URL, metrics: RecordingMetrics)? {
        guard isRecording else { return nil }

        isRecording = false

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Drain pending async work on the serial `fileQueue`, then read the
        // metrics and release the file handle inside the same barrier. This
        // guarantees every buffer's write + metric append has landed AND that
        // `bufferMetrics`/`metricTotalFrames` are read with no data race
        // against an audio-thread callback (`removeTap` stops future callbacks
        // but doesn't join an in-flight one — the queue barrier does).
        let metrics: RecordingMetrics = fileQueue.sync {
            audioFile = nil
            return RecordingMetrics(
                sampleRate: metricSampleRate,
                totalFrames: metricTotalFrames,
                buffers: bufferMetrics
            )
        }

        readyFired = false
        smoothedLevel = 0
        audioLevel = 0
        lastLevelPublishTime = 0

        logger.info("Recording stopped")
        guard let url = tempFileURL else { return nil }
        return (url, metrics)
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempFileURL = nil
        audioFile = nil
    }

    private func handleIncomingBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        let rms = rmsLevel(for: buffer)
        let frameCount = Int(buffer.frameLength)

        if !readyFired && rms > 0 {
            readyFired = true
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingReady?()
            }
        }

        // Write the buffer AND record its metrics on the serial `fileQueue`.
        // The write goes async so the audio tap callback never stalls on disk
        // I/O; the metric mutations (`metricTotalFrames`, `bufferMetrics`) live
        // here too because `stopRecording` reads them — confining every
        // mutation and the read to one serial queue removes a real data race.
        // `bufferMetrics` is an Array whose `append` can reallocate its backing
        // store; a concurrent main-thread read during that reallocation is heap
        // corruption, not just a torn value. `removeTap` does NOT join an
        // in-flight tap callback, so the queue barrier — not tap removal — is
        // what makes the read safe. The recording is still written first, so
        // nothing downstream can delay or alter transcription's only input.
        fileQueue.async { [weak self] in
            guard let self else { return }
            self.metricTotalFrames &+= Int64(frameCount)
            self.bufferMetrics.append(BufferMetric(frameCount: frameCount, rms: rms))
            if let audioFile = self.audioFile {
                do {
                    try audioFile.write(from: buffer)
                } catch {
                    logger.error("Failed to write audio buffer: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Only AFTER the recording is safely queued do we tee the buffer to the
        // wake-word listener (to hear "End Comet"). The listener deep-copies it
        // and runs a separate on-device recognizer — it never writes to the
        // audio file, mutates this buffer, or touches the input device, so
        // transcription is byte-for-byte unaffected. `onBuffer` is nil for
        // every non-wake dictation, so the normal path is completely unchanged.
        onBuffer?(buffer)

        let scaledLevel = min(rms * 12, 1)
        if scaledLevel > smoothedLevel {
            smoothedLevel = (smoothedLevel * 0.25) + (scaledLevel * 0.75)
        } else {
            smoothedLevel = (smoothedLevel * 0.7) + (scaledLevel * 0.3)
        }

        // Throttle UI publishes to ~30 Hz. The tap fires at ~47 Hz; the
        // waveform and level meter can't visually distinguish anything
        // faster, so batching cuts main-thread dispatch overhead.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelPublishTime >= 1.0 / 30.0 {
            lastLevelPublishTime = now
            let published = smoothedLevel
            DispatchQueue.main.async { [weak self] in
                self?.audioLevel = published
            }
        }
    }

    private func rmsLevel(for buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            var sum: Float = 0
            for frame in 0..<frameCount {
                let sample = channelData[0][frame]
                sum += sample * sample
            }
            return sqrt(sum / Float(frameCount))
        }

        if let channelData = buffer.int16ChannelData {
            var sum: Float = 0
            for frame in 0..<frameCount {
                let sample = Float(channelData[0][frame]) / Float(Int16.max)
                sum += sample * sample
            }
            return sqrt(sum / Float(frameCount))
        }

        return 0
    }
}

/// Per-buffer RMS captured during recording.
struct BufferMetric {
    let frameCount: Int
    let rms: Float
}

/// Raw voice-activity data collected while recording. Used by the pipeline to
/// decide whether the recording contains enough real speech to send to STT.
struct RecordingMetrics {
    let sampleRate: Double
    let totalFrames: Int64
    let buffers: [BufferMetric]

    var totalDurationSeconds: Double {
        sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }
}

enum AudioError: LocalizedError {
    case noInputDevice
    case recordingFailed(String)
    case microphoneNotAuthorized

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone input device is available."
        case .recordingFailed(let message):
            return message
        case .microphoneNotAuthorized:
            return "Microphone access is not authorized."
        }
    }
}
