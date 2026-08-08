import XCTest
@testable import ClockItCore

/// The detector takes numbers and returns events, so it tests without a camera,
/// a hand, or a Mac with a lens. Add a failing case here every time a real
/// gesture misbehaves.
final class PoseDetectorTests: XCTestCase {

    private let apart = 0.90
    private let together = 0.15
    /// Between contactEnter (0.45) and contactExit (0.65) — the hysteresis band.
    ///
    /// Only meaningful relative to the config. At 0.38 — where it sat when
    /// enter/exit were 0.30/0.45 — it now falls *below* contactEnter, so
    /// testHysteresisAbsorbsWobble would still pass while testing nothing:
    /// contact would hold with or without hysteresis. Keep it between the two.
    private let band = 0.55

    /// Feeds `(duration, distance)` segments at 15fps and collects events.
    /// A `nil` distance simulates lost or low-confidence landmarks.
    private func run(
        _ segments: [(Double, Double?)],
        config: PoseConfig = PoseConfig()
    ) -> [GestureEvent] {
        let detector = PoseDetector(config: config)
        let step = 1.0 / 15.0
        var t = 0.0
        var events: [GestureEvent] = []

        for (duration, distance) in segments {
            var elapsed = 0.0
            while elapsed < duration {
                if let event = detector.update(distance: distance, at: t) { events.append(event) }
                t += step
                elapsed += step
            }
        }
        return events
    }

    // MARK: - Short dictation (hold to talk)

    func testHeldContactStartsThenReleaseStops() {
        let events = run([
            (1.0, apart),
            (3.0, together),   // past armingDuration (0.5), short of latchAfter (7)
            (1.0, apart),
        ])
        XCTAssertEqual(events, [.start, .stop])
    }

    /// A hand passing through frame must not start a dictation.
    func testBriefContactDoesNotStart() {
        let events = run([
            (1.0, apart),
            (0.3, together),   // under armingDuration
            (1.0, apart),
        ])
        XCTAssertEqual(events, [])
    }

    /// Without hysteresis, a wobbling hand flickers the recording on and off.
    func testHysteresisAbsorbsWobble() {
        let events = run([
            (1.0, apart),
            (1.0, together),
            (1.0, band),       // drifts up but not past contactExit
            (1.0, together),
            (1.0, apart),
        ])
        XCTAssertEqual(events, [.start, .stop])
    }

    // MARK: - Long dictation (latch)

    func testHoldingPastSevenSecondsLatches() {
        let events = run([
            (1.0, apart),
            (8.0, together),
            (1.0, apart),      // releasing a latched recording must NOT stop it
        ])
        XCTAssertEqual(events, [.start, .latch])
    }

    func testLatchedRecordingEndsOnSecondContact() {
        let events = run([
            (1.0, apart),
            (8.0, together),   // start + latch
            (2.0, apart),      // hand drops
            (1.0, together),   // re-formed, held past armingDuration
            (1.0, apart),
        ])
        XCTAssertEqual(events, [.start, .latch, .stop])
    }

    /// The contact that caused the latch must fully open first, or you'd latch
    /// and stop in a single unbroken motion.
    func testHoldingThroughTheLatchDoesNotImmediatelyStop() {
        let events = run([
            (1.0, apart),
            (15.0, together),  // hold well past the latch, never releasing
        ])
        XCTAssertEqual(events, [.start, .latch])
    }

    /// A brush of contact while latched shouldn't end a dictation.
    func testBriefContactWhileLatchedDoesNotStop() {
        let events = run([
            (1.0, apart),
            (8.0, together),
            (2.0, apart),
            (0.3, together),   // under armingDuration
            (2.0, apart),
        ])
        XCTAssertEqual(events, [.start, .latch])
    }

    // MARK: - Tracking loss

    /// A rotating hand hides the middle fingertip for a few frames. That must
    /// not truncate you mid-sentence.
    func testBriefTrackingLossDoesNotStopRecording() {
        let events = run([
            (1.0, apart),
            (2.0, together),
            (0.4, nil),        // under trackingGrace (0.6)
            (2.0, together),
            (1.0, apart),
        ])
        XCTAssertEqual(events, [.start, .stop])
    }

    /// Hand actually leaves frame during an unlatched recording — end it rather
    /// than leaving the mic open.
    func testSustainedTrackingLossStopsUnlatchedRecording() {
        let events = run([
            (1.0, apart),
            (2.0, together),
            (2.0, nil),        // well past trackingGrace
        ])
        XCTAssertEqual(events, [.start, .stop])
    }

    /// While latched the hand is *supposed* to be gone. Losing it is expected,
    /// not a fault, and must never end the recording.
    func testTrackingLossWhileLatchedIsHarmless() {
        let events = run([
            (1.0, apart),
            (8.0, together),
            (10.0, nil),       // hand away for ages
            (1.0, together),
            (1.0, apart),
        ])
        XCTAssertEqual(events, [.start, .latch, .stop])
    }

    /// Ending a latched dictation must not immediately start another one.
    ///
    /// Stopping a latched recording means holding the O for `armingDuration`,
    /// and nobody releases the instant it fires. The detector used to clear
    /// `inContact` while the hand was still closed, so contact re-registered on
    /// the very next frame and armed a fresh dictation about half a second
    /// later — you'd get a phantom recording of whatever you said next.
    ///
    /// The 1.0s segment in `testLatchedRecordingEndsOnSecondContact` missed this
    /// by about 0.15s: 1.1s still passed, 1.2s produced the phantom. 2.0s is a
    /// realistic hold and comfortably clear of the boundary.
    func testEndingALatchedRecordingDoesNotStartANewOne() {
        let events = run([
            (1.0, apart),
            (8.0, together),   // start + latch
            (2.0, apart),      // hand drops
            (2.0, together),   // re-formed and held well past armingDuration
            (1.0, apart),
        ])
        XCTAssertEqual(events, [.start, .latch, .stop])
    }

    // MARK: - Config

    func testLatchThresholdIsConfigurable() {
        var config = PoseConfig()
        config.latchAfter = 3.0
        let events = run([
            (1.0, apart),
            (4.0, together),
            (1.0, apart),
        ], config: config)
        XCTAssertEqual(events, [.start, .latch])
    }
}
