import AVFoundation
import CoreMedia
import SwiftUI
import Vision

/// Owns the capture session and Vision request, converts hand landmarks into
/// a single normalized distance, and drives a `PoseDetector`.
///
/// The gesture is the whole hand pursing toward the thumb, so the distance is
/// the mean over every fingertip that is confidently visible — not one pair.
/// That makes the measurement match the gesture, and it means a fingertip lost
/// behind the thumb costs a quarter of the signal rather than all of it.
///
/// Everything in the capture path runs on `queue`; only the `@Published`
/// values hop to main. Don't touch `detector` from outside.
public final class HandTracker: NSObject, ObservableObject {

    // Live values for the debug UI.
    @Published public private(set) var distance: Double?
    /// The finger that closed least. Displayed only — see `HandSample.altDistance`.
    @Published public private(set) var altDistance: Double?
    /// Fingertips contributing to `distance` this frame, out of four.
    @Published public private(set) var contributingFingers = 0
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

    /// How many fingertips must clear `tipConfidence` before the mean is worth
    /// handing to the detector.
    ///
    /// Two, not one: a "mean" over a single fingertip is just that fingertip,
    /// which is exactly the fragile single-pair measurement the aggregate
    /// exists to replace.
    public static let minimumContributingFingers = 2

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
    private var contributingSum = 0
    private var longestDropout: TimeInterval = 0
    private var visionFailures = 0
    private var lastGoodAt: TimeInterval?

    /// Distance distribution since the last reset. A fixed-bin histogram rather
    /// than a sample buffer: percentiles come out in one pass over 140 ints, the
    /// memory is constant however long you hold the pose, and 0.01 resolution is
    /// exactly the precision the threshold sliders offer anyway.
    private static let binWidth = 0.01
    private static let binCount = 140
    private var histogram = [Int](repeating: 0, count: HandTracker.binCount)
    private var histogramCount = 0
    private var distanceMin = Double.infinity
    private var distanceMax = -Double.infinity

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
            self.contributingSum = 0
            self.longestDropout = 0
            self.visionFailures = 0
            self.lastGoodAt = nil
            self.histogram = [Int](repeating: 0, count: Self.binCount)
            self.histogramCount = 0
            self.distanceMin = .infinity
            self.distanceMax = -.infinity
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

    /// Reads every landmark we care about once and reduces the hand to a single
    /// number: how far, on average, the fingertips sit from the thumb tip.
    ///
    /// Everything is divided by wrist-to-middle-MCP. The division makes it
    /// scale-invariant: leaning toward the camera changes both the fingertip
    /// gaps and the reference span equally, so the ratio holds.
    ///
    /// Two things can make this return no measurement at all. The thumb tip is
    /// the hub — lose it and there is nothing to measure distances *to*. And the
    /// scale pair sets the denominator, so losing the wrist or middle MCP is
    /// equally fatal. Individual fingertips are the forgiving part: any that
    /// fall below the confidence floor simply drop out of the average.
    private func sample(
        from observation: VNHumanHandPoseObservation,
        aspect: Double
    ) -> HandSample {
        func point(_ name: VNHumanHandPoseObservation.JointName) -> VNRecognizedPoint? {
            try? observation.recognizedPoint(name)
        }

        let thumbTip = point(.thumbTip)
        let indexTip = point(.indexTip)
        let middleTip = point(.middleTip)
        let ringTip = point(.ringTip)
        let littleTip = point(.littleTip)
        let wrist = point(.wrist)
        let middleMCP = point(.middleMCP)

        var result = HandSample()
        result.confidence.thumbTip = thumbTip?.confidence
        result.confidence.indexTip = indexTip?.confidence
        result.confidence.middleTip = middleTip?.confidence
        result.confidence.ringTip = ringTip?.confidence
        result.confidence.littleTip = littleTip?.confidence
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

        guard let scale, let thumbTip, thumbTip.confidence > Self.tipConfidence else {
            return result
        }

        var perFinger: [Double] = []
        for tip in [indexTip, middleTip, ringTip, littleTip] {
            guard let tip, tip.confidence > Self.tipConfidence else { continue }
            perFinger.append(gap(thumbTip, tip) / scale)
        }

        result.contributingFingers = perFinger.count
        guard perFinger.count >= Self.minimumContributingFingers else { return result }

        result.distance = perFinger.reduce(0, +) / Double(perFinger.count)
        result.altDistance = perFinger.max()
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
        // it usable as "was the hand closed when the landmarks vanished."
        if visionRan, detector.inContact {
            contactFrames += 1

            if measured.distance == nil {
                contactNilFrames += 1
                longestDropout = max(longestDropout, time - (lastGoodAt ?? time))
            } else {
                contributingSum += measured.contributingFingers
            }
        }
        // Deliberately not gated on `visionRan`: a frame Vision failed on is
        // still a frame with no measurement, so it does extend the blackout the
        // grace has to absorb. Rates attribute cause (failures excluded);
        // durations model consequence (failures included). Both are right.
        if measured.distance != nil { lastGoodAt = time }

        // Distribution, over every measured frame regardless of contact — you
        // need the open hand's spread as much as the closed one's.
        if let d = measured.distance {
            let bin = Swift.min(Swift.max(Int(d / Self.binWidth), 0), Self.binCount - 1)
            histogram[bin] += 1
            histogramCount += 1
            distanceMin = Swift.min(distanceMin, d)
            distanceMax = Swift.max(distanceMax, d)
        }

        let event = detector.update(distance: measured.distance, at: time)
        let snapshot = detector.state
        let recording = detector.isRecording
        let latched = detector.isLatched
        let fps = sampleFPS(at: time)

        var statsSnapshot = TrackingStats()
        statsSnapshot.contactFrames = contactFrames
        statsSnapshot.contactNilFrames = contactNilFrames
        statsSnapshot.contributingSum = contributingSum
        statsSnapshot.longestDropout = longestDropout
        statsSnapshot.visionFailures = visionFailures
        statsSnapshot.distance = summarizeDistances()

        DispatchQueue.main.async {
            self.distance = measured.distance
            self.altDistance = measured.altDistance
            self.contributingFingers = measured.contributingFingers
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

    /// Percentiles straight out of the histogram. Queue-confined, one pass over
    /// 140 bins, so it's cheap enough to run every frame.
    private func summarizeDistances() -> DistanceSummary {
        var summary = DistanceSummary()
        guard histogramCount > 0 else { return summary }

        summary.count = histogramCount
        summary.minimum = distanceMin
        summary.maximum = distanceMax

        func percentile(_ fraction: Double) -> Double {
            let target = Swift.max(Int((Double(histogramCount) * fraction).rounded()), 1)
            var cumulative = 0
            for (index, count) in histogram.enumerated() where count > 0 {
                cumulative += count
                if cumulative >= target {
                    // Bin centre: the value is known to 0.01, not exactly.
                    return (Double(index) + 0.5) * Self.binWidth
                }
            }
            return distanceMax
        }

        summary.p05 = percentile(0.05)
        summary.p50 = percentile(0.50)
        summary.p95 = percentile(0.95)
        return summary
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
