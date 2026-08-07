import AVFoundation

/// Captures microphone audio as the 16 kHz mono Float array Whisper expects,
/// and keeps a rolling pre-roll buffer so the first word isn't clipped.
///
/// Pre-roll matters more with a gesture trigger than with a key: the gesture
/// takes `armingDuration` to complete and your hand is still settling when you
/// start talking. The engine runs continuously; `start()` only marks the point
/// from which samples are kept.
final class AudioRecorder {

    /// Seconds of audio retained from *before* the trigger fired.
    var preRoll: TimeInterval = 2.0

    private(set) var isCapturing = false

    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16_000
    private let lock = NSLock()

    private var ring: [Float] = []
    private var captured: [Float] = []
    private var converter: AVAudioConverter?

    private var ringCapacity: Int { Int(preRoll * sampleRate) }

    /// Resolves microphone permission. MUST complete, and return true, before
    /// `prepare()` is called.
    ///
    /// This is not optional politeness. Until TCC resolves,
    /// `engine.inputNode.outputFormat(forBus: 0)` reports 0 Hz and 0 channels,
    /// and `installTap` on a zero-channel format raises an Objective-C
    /// exception — which no Swift `try` can catch, so the app dies at launch
    /// with a stack trace nowhere near the cause. The quieter version of the
    /// same bug is `AVAudioConverter(from:to:)` returning nil and every
    /// dictation silently transcribing to empty string.
    ///
    /// Static on purpose: it touches no instance state, so the caller can await
    /// it from the main actor without handing a non-Sendable recorder across an
    /// isolation boundary.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Begins the always-on engine. Call once at launch, not per dictation —
    /// spinning the engine up per recording adds latency and loses the pre-roll.
    ///
    /// Bundled, this needs `NSMicrophoneUsageDescription` in Info.plist or TCC
    /// kills the process outright. Run from `swift run` the binary has no
    /// Info.plist at all and inherits your terminal's grant instead, which is
    /// why the packaging script belongs before the first real run.
    func prepare() throws {
        guard !engine.isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Belt and braces. Access can be granted and the device still be
        // unusable — no built-in mic, a disconnected interface, a format the
        // engine hasn't settled on yet.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw RecorderError.inputUnavailable
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.formatUnavailable }

        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.ingest(buffer, target: target)
        }

        engine.prepare()
        try engine.start()
    }

    func start() {
        lock.lock()
        // Seed with the pre-roll so speech that began during the gesture survives.
        captured = ring
        isCapturing = true
        lock.unlock()
    }

    /// Returns everything captured since `start()`, including the pre-roll.
    func stop() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        isCapturing = false
        let result = captured
        captured = []
        return result
    }

    /// Root mean square of the most recent block, for the pill's level meter.
    func currentLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let tail = ring.suffix(1024)
        guard !tail.isEmpty else { return 0 }
        let sum = tail.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(tail.count)).squareRoot()
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        guard !samples.isEmpty else { return }

        lock.lock()
        ring.append(contentsOf: samples)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        if isCapturing {
            captured.append(contentsOf: samples)
        }
        lock.unlock()
    }

    enum RecorderError: Error {
        /// The user said no, or said no previously.
        case microphoneAccessDenied
        /// Access granted but the input node has no usable format.
        case inputUnavailable
        case formatUnavailable
        case converterUnavailable
    }
}
