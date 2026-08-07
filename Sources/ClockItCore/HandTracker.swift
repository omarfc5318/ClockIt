import AVFoundation
import CoreMedia
import SwiftUI
import Vision

/// Owns the capture session and Vision request, converts hand landmarks into
/// a single normalized distance, and drives a `PoseDetector`.
///
/// Everything in the capture path runs on `queue`; only the `@Published`
/// values hop to main. Don't touch `detector` from outside.
public final class HandTracker: NSObject, ObservableObject {

    // Live values for the debug UI.
    @Published public private(set) var distance: Double?
    /// Thumb IP to middle PIP. Displayed only — see `HandSample.altDistance`.
    @Published public private(set) var altDistance: Double?
    @Published public private(set) var confidence = LandmarkConfidence()
    @Published public private(set) var stats = TrackingStats()
    @Published public private(set) var handPresent = false
    @Published public private(set) var state: PoseState = .open
    @Published public private(set) var isRecording = false
    @Published public private(set) var isLatched = false
    @Published public private(set) var effectiveFPS: Double = 0
    @Published public var errorMessage: String?

    /// Fired on the main queue for each dictation event.
    public var onEvent: ((GestureEvent) -> Void)?

    public let session = AVCaptureSession()

    /// Landmark confidence floors. Fingertips need to be solid; wrist and MCP
    /// only provide scale, so they can be looser.
    ///
    /// Public because the harness draws them as tick marks on the confidence
    /// bars — a bar you can't see the floor on tells you nothing.
    public static let tipConfidence: Float = 0.5
    public static let scaleConfidence: Float = 0.3

    private let detector = PoseDetector()
    private let queue = DispatchQueue(label: "hand-tracker", qos: .userInitiated)
    private let request = VNDetectHumanHandPoseRequest()
    private let output = AVCaptureVideoDataOutput()

    /// With no hand in frame we only run Vision every Nth frame. Vision
    /// inference is the expensive part, not the capture itself. At 15fps a skip
    /// of 3 means a 5fps idle scan — fast enough to notice a hand appearing,
    /// cheap enough to leave running all day.
    private let idleFrameSkip = 3
    private var frameIndex = 0
    private var framesSinceHand = 0
    private var lastFPSSample: TimeInterval = 0
    private var fpsCounter = 0

    // Occlusion telemetry. Queue-confined; snapshotted onto `stats` each frame.
    private var contactFrames = 0
    private var contactNilFrames = 0
    private var contactAltNilFrames = 0
    private var longestDropout: TimeInterval = 0
    private var longestAltDropout: TimeInterval = 0
    private var visionFailures = 0
    private var lastGoodAt: TimeInterval?
    private var lastAltGoodAt: TimeInterval?

    public override init() {
        super.init()
        request.maximumHandCount = 1
    }

    /// Update thresholds live from the debug sliders.
    public func applyConfig(_ config: PoseConfig) {
        queue.async { self.detector.config = config }
    }

    /// Clears the occlusion counters. Worth doing between deliberate trials —
    /// a lifetime average goes stale the moment you change how you hold your hand.
    public func resetStats() {
        queue.async {
            self.contactFrames = 0
            self.contactNilFrames = 0
            self.contactAltNilFrames = 0
            self.longestDropout = 0
            self.longestAltDropout = 0
            self.visionFailures = 0
            self.lastGoodAt = nil
            self.lastAltGoodAt = nil
            DispatchQueue.main.async { self.stats = TrackingStats() }
        }
    }

    public func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.errorMessage = "Camera access denied. Grant it in System Settings › Privacy & Security › Camera."
                }
                return
            }
            self.queue.async {
                self.configure()
                self.session.startRunning()
            }
        }
    }

    public func stop() {
        queue.async { self.session.stopRunning() }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.errorMessage = "No usable camera found." }
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        // 15fps is plenty for a held pose. The 60fps requirement belonged to
        // tap detection, where contact lasted only 60-120ms; sustained contact
        // just has to persist, so this buys back battery and thermal headroom.
        configureFrameRate(device, target: 15)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()
    }

    private func configureFrameRate(_ device: AVCaptureDevice, target: Double) {
        guard let format = device.formats.last(where: { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= target }
        }) else { return }

        guard (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(target))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    /// Reads every landmark we care about once, and derives two normalized
    /// distances from them: the tip pair the detector uses, and the IP/PIP pair
    /// we're evaluating as a replacement.
    ///
    /// Both are divided by wrist-to-middle-MCP. The division makes them
    /// scale-invariant: leaning toward the camera changes both distances
    /// equally, so the ratio holds. It also means the two are on the same scale
    /// and can be read off one axis in the harness.
    private func sample(
        from observation: VNHumanHandPoseObservation,
        aspect: Double
    ) -> HandSample {
        func point(_ name: VNHumanHandPoseObservation.JointName) -> VNRecognizedPoint? {
            try? observation.recognizedPoint(name)
        }

        let thumbTip = point(.thumbTip)
        let thumbIP = point(.thumbIP)
        let middleTip = point(.middleTip)
        let middleDIP = point(.middleDIP)
        let middlePIP = point(.middlePIP)
        let wrist = point(.wrist)
        let middleMCP = point(.middleMCP)

        var result = HandSample()
        result.confidence.thumbTip = thumbTip?.confidence
        result.confidence.thumbIP = thumbIP?.confidence
        result.confidence.middleTip = middleTip?.confidence
        result.confidence.middleDIP = middleDIP?.confidence
        result.confidence.middlePIP = middlePIP?.confidence
        result.confidence.wrist = wrist?.confidence
        result.confidence.middleMCP = middleMCP?.confidence

        // Vision returns normalized [0,1] coords, so x and y sit on different
        // real-world scales until we undo the frame's aspect ratio.
        func gap(_ a: VNRecognizedPoint, _ b: VNRecognizedPoint) -> Double {
            let dx = (a.location.x - b.location.x) * aspect
            let dy = a.location.y - b.location.y
            return (dx * dx + dy * dy).squareRoot()
        }

        var scale: Double?
        if let wrist, let middleMCP,
           wrist.confidence > Self.scaleConfidence,
           middleMCP.confidence > Self.scaleConfidence {
            let measured = gap(wrist, middleMCP)
            if measured > 0.001 { scale = measured }
        }

        func normalized(_ a: VNRecognizedPoint?, _ b: VNRecognizedPoint?) -> Double? {
            guard let a, let b, let scale,
                  a.confidence > Self.tipConfidence,
                  b.confidence > Self.tipConfidence else { return nil }
            return gap(a, b) / scale
        }

        result.distance = normalized(thumbTip, middleTip)
        result.altDistance = normalized(thumbIP, middlePIP)
        return result
    }
}

extension HandTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Presentation time, not Date() — it's monotonic and matches the frame.
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let aspect = height > 0 ? width / height : 1

        var measured = HandSample()
        var sawHand = false
        var visionRan = false

        frameIndex += 1
        // Two seconds of grace at 15fps before dropping back to the idle scan.
        let recentlySawHand = framesSinceHand < 30
        if recentlySawHand || frameIndex % idleFrameSkip == 0 {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)

            // The error is NOT discardable. `request` is reused across frames
            // and holds its last results, so on a throw `request.results` still
            // contains the PREVIOUS frame's observation. Reading it would report
            // a phantom hand at a stale distance — and would count as a
            // successful measurement, biasing the nil rate downward. That is the
            // one direction of error that reads as a false all-clear.
            do {
                try handler.perform([request])
                visionRan = true
                if let observation = request.results?.first {
                    sawHand = true
                    measured = sample(from: observation, aspect: aspect)
                }
            } catch {
                // No measurement at all this frame. `measured` stays empty, so
                // the detector sees nil and `trackingGrace` absorbs it — which
                // is the honest outcome: we don't know where the hand is.
                //
                // Excluded from the occlusion counters via `visionRan`, since a
                // failed inference isn't occlusion, but counted separately so a
                // shrinking denominator can't hide.
                visionFailures += 1
            }

            framesSinceHand = sawHand ? 0 : framesSinceHand + 1
        }

        // Sampled BEFORE update() so `inContact` still reflects the last
        // confident measurement rather than this frame's verdict. On a nil
        // frame update() doesn't touch it at all, which is exactly what makes
        // it usable as "were the fingers touching when the landmarks vanished."
        if visionRan, detector.inContact {
            contactFrames += 1

            if measured.distance == nil {
                contactNilFrames += 1
                longestDropout = max(longestDropout, time - (lastGoodAt ?? time))
            }
            if measured.altDistance == nil {
                contactAltNilFrames += 1
                longestAltDropout = max(longestAltDropout, time - (lastAltGoodAt ?? time))
            }
        }
        // Deliberately not gated on `visionRan`: a frame Vision failed on is
        // still a frame with no measurement, so it does extend the blackout the
        // grace has to absorb. Rates attribute cause (failures excluded);
        // durations model consequence (failures included). Both are right.
        if measured.distance != nil { lastGoodAt = time }
        if measured.altDistance != nil { lastAltGoodAt = time }

        let event = detector.update(distance: measured.distance, at: time)
        let snapshot = detector.state
        let recording = detector.isRecording
        let latched = detector.isLatched
        let fps = sampleFPS(at: time)

        var statsSnapshot = TrackingStats()
        statsSnapshot.contactFrames = contactFrames
        statsSnapshot.contactNilFrames = contactNilFrames
        statsSnapshot.contactAltNilFrames = contactAltNilFrames
        statsSnapshot.longestDropout = longestDropout
        statsSnapshot.longestAltDropout = longestAltDropout
        statsSnapshot.visionFailures = visionFailures

        DispatchQueue.main.async {
            self.distance = measured.distance
            self.altDistance = measured.altDistance
            self.confidence = measured.confidence
            self.stats = statsSnapshot
            self.handPresent = sawHand
            self.state = snapshot
            self.isRecording = recording
            self.isLatched = latched
            if let fps { self.effectiveFPS = fps }
            if let event { self.onEvent?(event) }
        }
    }

    private func sampleFPS(at time: TimeInterval) -> Double? {
        fpsCounter += 1
        if lastFPSSample == 0 { lastFPSSample = time; return nil }
        let elapsed = time - lastFPSSample
        guard elapsed >= 1 else { return nil }
        let fps = Double(fpsCounter) / elapsed
        fpsCounter = 0
        lastFPSSample = time
        return fps
    }
}
