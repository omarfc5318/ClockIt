import Foundation

/// Per-landmark Vision confidences for one frame.
///
/// The detector only ever sees a single `Double?`. These exist so the tuning
/// harness can show *why* that Double was nil — which is the difference between
/// "my thresholds are wrong" and "the thumb is sitting on top of the middle
/// fingertip and no threshold will save me."
///
/// `nil` means Vision returned no point at all for that joint. A confidence of
/// 0.0 means it returned one and doesn't believe it. Both read as a dash in the
/// harness; neither is usable.
public struct LandmarkConfidence: Equatable, Sendable {
    public var thumbTip: Float?
    public var thumbIP: Float?
    public var middleTip: Float?
    public var middleDIP: Float?
    public var middlePIP: Float?
    public var wrist: Float?
    public var middleMCP: Float?

    public init() {}
}

/// One frame's worth of measurement.
public struct HandSample: Equatable, Sendable {
    /// Thumb tip to middle tip, normalized by wrist-to-middle-MCP.
    /// This is the only value the detector consumes.
    public var distance: Double?

    /// The same measurement taken one joint further down each finger:
    /// thumbIP to middlePIP, normalized identically.
    ///
    /// MEASURED AND DISPLAYED ONLY — never fed to `PoseDetector`. It is here to
    /// answer a single question before any state-machine work happens: when the
    /// thumb occludes the middle fingertip during contact, do the joints one
    /// segment back stay visible? If they do, this pair becomes the detector's
    /// input and the thresholds get retuned around it. If they don't, the tip
    /// pair stays and the occlusion theory is dead.
    public var altDistance: Double?

    public var confidence = LandmarkConfidence()

    public init() {}
}

/// Running occlusion telemetry, accumulated on the capture queue.
///
/// The denominator is "frames where the detector believed the fingers were
/// touching," not "all frames." Loss while the hand is nowhere near the pose is
/// uninteresting; loss *during contact* is the thing that truncates you
/// mid-sentence.
public struct TrackingStats: Equatable, Sendable {
    /// Frames on which Vision ran while `PoseDetector.inContact` was true.
    public var contactFrames = 0
    /// Of those, how many produced no usable tip-pair distance.
    public var contactNilFrames = 0
    /// Of those, how many produced no usable IP/PIP-pair distance.
    public var contactAltNilFrames = 0
    /// Longest unbroken tip-pair blackout during contact. Compare to
    /// `PoseConfig.trackingGrace` — anything longer would have ended a dictation.
    public var longestDropout: TimeInterval = 0
    /// Same, for the IP/PIP pair.
    public var longestAltDropout: TimeInterval = 0

    /// Frames where the Vision request itself threw. These are excluded from
    /// every count above, because a failed inference is not occlusion and
    /// folding it in would bias the nil rate upward — the opposite error from
    /// the stale-observation bug, but still an error.
    ///
    /// Surfaced rather than silently dropped: a shrinking denominator you can't
    /// see is how a sampling bug survives a measurement session. Expect 0.
    public var visionFailures = 0

    public var nilRate: Double {
        contactFrames == 0 ? 0 : Double(contactNilFrames) / Double(contactFrames)
    }

    public var altNilRate: Double {
        contactFrames == 0 ? 0 : Double(contactAltNilFrames) / Double(contactFrames)
    }

    public init() {}
}
