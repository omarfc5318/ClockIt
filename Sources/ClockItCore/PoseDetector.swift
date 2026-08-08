import Foundation

/// What the detector tells the session to do.
public enum GestureEvent: Equatable {
    /// Contact held long enough — begin dictation.
    case start
    /// Still held at `latchAfter` — lock the recording on so the hand can drop.
    case latch
    /// Released (unlatched), or contact re-formed (latched) — end dictation.
    case stop
}

public struct PoseConfig: Equatable {
    /// Enter contact when the normalized fingertip-to-thumb distance drops
    /// below this.
    ///
    /// Measured, not guessed: a closed O reads p95 0.36, an open hand reads
    /// p05 0.78. Enter sits above the closed p95 so a sloppy O still registers,
    /// exit sits below the open p05 so a real release registers at once, and the
    /// 0.20 between them is the hysteresis band — far wider than frame-to-frame
    /// jitter, which is the point.
    ///
    /// If you change these, `PoseDetectorTests.band` has to move with them or
    /// the hysteresis test silently stops testing hysteresis.
    public var contactEnter: Double = 0.45
    /// Leave contact above this. Must exceed `contactEnter` — the gap is what
    /// stops a wobbling hand from flickering the recording on and off.
    public var contactExit: Double = 0.65
    /// How long contact must hold before anything happens. Keeps a hand that
    /// merely passes through frame from starting a dictation.
    public var armingDuration: TimeInterval = 0.5
    /// Hold past this and the recording latches on.
    public var latchAfter: TimeInterval = 7.0
    /// Tolerance for lost landmarks. A rotating hand hides fingertips for a few
    /// frames; without this, a flicker truncates you mid-sentence.
    public var trackingGrace: TimeInterval = 0.6

    public init() {}
}

public enum PoseState: Equatable {
    /// Nothing happening.
    case open
    /// Contact seen, waiting out `armingDuration`.
    case arming(since: TimeInterval)
    /// Recording, hand still holding. Release stops it.
    case active(since: TimeInterval)
    /// Latched, but the hand hasn't let go yet. Must fully release before a new
    /// contact can stop the recording — otherwise you'd latch and immediately
    /// stop in one motion.
    case latchedHolding
    /// Latched and the hand is free. Tracking loss here is expected, not a fault.
    case latched
    /// Latched and contact re-formed, waiting out `armingDuration` to stop.
    case stopArming(since: TimeInterval)
    /// Stopped, but the hand hasn't opened yet.
    ///
    /// The mirror of `latchedHolding`, on the other edge. Ending a latched
    /// recording means holding the O for `armingDuration`, and you will not let
    /// go the instant it fires — so without this the still-closed hand
    /// immediately re-registers as contact and arms a fresh dictation about half
    /// a second later. A new recording has to begin with a new gesture, which
    /// means the hand that ended the last one must actually open first.
    case closedAfterStop
}

/// Consumes a normalized "how closed is the hand" distance and emits dictation
/// events. Knows nothing about cameras, Vision, audio, or which joints produced
/// the number — feed it recorded distance sequences in tests and assert on the
/// event stream.
///
/// That opacity is load-bearing: the gesture changed from a thumb-to-middle
/// pinch to the whole hand pursing toward the thumb, and nothing in this file
/// moved. Keep it that way.
public final class PoseDetector {
    public var config: PoseConfig
    public private(set) var state: PoseState = .open

    /// Exposed read-only so the tuning harness can attribute a lost landmark to
    /// "the fingers were touching when it vanished" rather than "the hand was
    /// somewhere else." Nothing outside this file may set it.
    public private(set) var inContact = false

    private var lastKnownAt: TimeInterval?

    public init(config: PoseConfig = PoseConfig()) {
        self.config = config
    }

    public func reset() {
        state = .open
        inContact = false
        lastKnownAt = nil
    }

    /// True while a recording is running, latched or not. Drives the pill.
    public var isRecording: Bool {
        switch state {
        case .open, .arming, .closedAfterStop: false
        case .active, .latchedHolding, .latched, .stopArming: true
        }
    }

    public var isLatched: Bool {
        switch state {
        case .latchedHolding, .latched, .stopArming: true
        case .open, .arming, .active, .closedAfterStop: false
        }
    }

    /// - Parameters:
    ///   - distance: normalized fingertip-to-thumb distance, or `nil` when the
    ///     landmarks aren't confidently visible.
    ///   - now: monotonic timestamp in seconds. Use the sample buffer's
    ///     presentation time, not `Date()`.
    @discardableResult
    public func update(distance: Double?, at now: TimeInterval) -> GestureEvent? {
        guard let d = distance else { return handleLostTracking(at: now) }
        lastKnownAt = now

        // Hysteresis: different thresholds entering and leaving contact.
        if !inContact, d < config.contactEnter {
            inContact = true
        } else if inContact, d > config.contactExit {
            inContact = false
        }

        switch state {

        case .open:
            if inContact { state = .arming(since: now) }

        case .arming(let since):
            if !inContact {
                state = .open
            } else if now - since >= config.armingDuration {
                state = .active(since: now)
                return .start
            }

        case .active(let since):
            if !inContact {
                state = .open
                return .stop
            } else if now - since >= config.latchAfter {
                state = .latchedHolding
                return .latch
            }

        case .latchedHolding:
            // Wait for a full release before arming the stop gesture.
            if !inContact { state = .latched }

        case .latched:
            if inContact { state = .stopArming(since: now) }

        case .stopArming(let since):
            if !inContact {
                state = .latched
            } else if now - since >= config.armingDuration {
                // NOT `.open` with `inContact = false`. Clearing the flag while
                // the fingers are still closed is precisely what let the next
                // frame re-register contact and start a phantom dictation.
                // Hand off to `closedAfterStop` and let the release clear it.
                state = .closedAfterStop
                return .stop
            }

        case .closedAfterStop:
            if !inContact { state = .open }
        }

        return nil
    }

    /// Landmarks lost. What that means depends entirely on the state: mid-hold
    /// it's a problem, but while latched the hand is *supposed* to be gone.
    private func handleLostTracking(at now: TimeInterval) -> GestureEvent? {
        switch state {
        case .latched, .latchedHolding:
            // Expected. A latched recording survives the hand leaving frame.
            if case .latchedHolding = state { state = .latched }
            return nil

        case .open:
            return nil

        case .arming, .active, .stopArming, .closedAfterStop:
            // `closedAfterStop` is here so a hand that leaves frame still closed
            // and comes back still closed isn't stuck waiting for a release it
            // already made off-camera. After the grace it falls back to `.open`
            // with the flag cleared, and a fresh gesture can start normally.
            guard let last = lastKnownAt, now - last > config.trackingGrace else { return nil }
            let wasRecording = isRecording
            let wasLatched = isLatched
            inContact = false
            state = wasLatched ? .latched : .open
            return (wasRecording && !wasLatched) ? .stop : nil
        }
    }
}
