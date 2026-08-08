import Foundation

/// Per-landmark Vision confidences for one frame.
///
/// The detector only ever sees a single `Double?`. These exist so the tuning
/// harness can show *why* that Double was nil, and which fingers are carrying
/// the measurement when it isn't.
///
/// `nil` means Vision returned no point at all for that joint. A confidence of
/// 0.0 means it returned one and doesn't believe it. Both read as a dash in the
/// harness; neither is usable.
public struct LandmarkConfidence: Equatable, Sendable {
    /// The hub of the gesture. If this is lost there is no measurement at all,
    /// no matter how well the fingertips are tracking.
    public var thumbTip: Float?

    public var indexTip: Float?
    public var middleTip: Float?
    public var ringTip: Float?
    public var littleTip: Float?

    public var wrist: Float?
    public var middleMCP: Float?

    public init() {}
}

/// One frame's worth of measurement.
public struct HandSample: Equatable, Sendable {
    /// Mean normalized distance from the thumb tip to each fingertip that
    /// cleared the confidence floor. This is the only value the detector
    /// consumes.
    ///
    /// The gesture is the whole hand pursing toward the thumb, so the whole
    /// hand is what gets measured. Averaging rather than taking a single pair
    /// also means a fingertip lost behind the thumb costs a quarter of the
    /// signal instead of all of it.
    public var distance: Double?

    /// The largest of those same per-finger distances — the finger that closed
    /// least. MEASURED AND DISPLAYED ONLY; never fed to `PoseDetector`.
    ///
    /// Useful for reading the spread while setting thresholds: a mean of 0.35
    /// with a worst of 0.9 means three fingers closed and one didn't, which
    /// looks nothing like a mean of 0.35 with a worst of 0.4.
    public var altDistance: Double?

    /// How many fingertips cleared the confidence floor and contributed to
    /// `distance`, out of four.
    ///
    /// Essential rather than decorative: a mean over one finger and a mean over
    /// four are the same number with very different trustworthiness, and
    /// without this you cannot tell them apart.
    public var contributingFingers = 0

    public var confidence = LandmarkConfidence()

    public init() {}
}

/// Where the measured distance actually sat over a window of frames.
///
/// A live readout at 15fps is unreadable, and a range eyeballed off a flickering
/// number is a range built from whatever your eye happened to catch. Percentiles
/// are what thresholds should be set from: `contactEnter` wants to clear the p95
/// of your closed hand, `contactExit` wants to sit under the p05 of your open
/// one, and the distance between those two is the hysteresis you have to spend.
///
/// Min and max are shown too, but treat them as outlier-sensitive — a single bad
/// frame moves them and shouldn't move your thresholds.
public struct DistanceSummary: Equatable, Sendable {
    public var count = 0
    public var minimum: Double = 0
    public var maximum: Double = 0
    public var p05: Double = 0
    public var p50: Double = 0
    public var p95: Double = 0

    public init() {}
}

/// Running occlusion telemetry, accumulated on the capture queue.
///
/// The denominator is "frames where the detector believed the hand was closed",
/// not "all frames". Loss while the hand is nowhere near the pose is
/// uninteresting; loss *during* the gesture is what truncates you mid-sentence.
public struct TrackingStats: Equatable, Sendable {
    /// Frames on which Vision ran while `PoseDetector.inContact` was true.
    public var contactFrames = 0

    /// Of those, how many produced no usable distance — meaning the thumb tip
    /// was lost, the scale pair was lost, or fewer than
    /// `HandTracker.minimumContributingFingers` fingertips survived.
    public var contactNilFrames = 0

    /// Sum of `contributingFingers` over the contact frames that DID produce a
    /// measurement. Divided out into a mean for display.
    public var contributingSum = 0

    /// Longest unbroken blackout during contact. Compare to
    /// `PoseConfig.trackingGrace` — anything longer would have ended a dictation.
    ///
    /// NOTE: this figure is censored. Counting stops when the detector drops
    /// contact, which is exactly what happens once a blackout exceeds the
    /// grace, so a value at the grace means "hit the ceiling and the recording
    /// was terminated", not "the blackout was precisely this long". Treat it as
    /// a lower bound.
    public var longestDropout: TimeInterval = 0

    /// Distribution of the measured distance since the last reset, over every
    /// frame that produced one — closed or open, contact or not. This is the
    /// thing you read thresholds off.
    public var distance = DistanceSummary()

    /// Frames where the Vision request itself threw. Excluded from every count
    /// above, because a failed inference is not occlusion — but surfaced rather
    /// than silently dropped, since a shrinking denominator you can't see is how
    /// a sampling bug survives a measurement session. Expect 0.
    public var visionFailures = 0

    public var nilRate: Double {
        contactFrames == 0 ? 0 : Double(contactNilFrames) / Double(contactFrames)
    }

    /// Average fingertips contributing, over contact frames that measured.
    /// Four is perfect; below about three means the aggregate is running on
    /// fewer fingers than the gesture implies.
    public var meanContributing: Double {
        let measured = contactFrames - contactNilFrames
        return measured <= 0 ? 0 : Double(contributingSum) / Double(measured)
    }

    public init() {}
}
