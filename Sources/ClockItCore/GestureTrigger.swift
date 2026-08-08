import Foundation

/// Wraps `HandTracker` so `SessionController` sees one callback and no state.
///
/// There's no lockout here anymore. The double-tap version needed one because
/// four quick taps emitted two events; the hold state machine can't produce a
/// spurious pair — `latchedHolding` forces a full release before a new contact
/// counts.
public final class GestureTrigger {

    /// Called on the main queue for each dictation event.
    public var onEvent: ((GestureEvent) -> Void)?

    private let tracker = HandTracker()

    public init() {
        tracker.onEvent = { [weak self] event in
            self?.onEvent?(event)
        }
    }

    /// Unlike a hotkey tap, this can't fail synchronously — camera permission
    /// resolves asynchronously. Watch `errorMessage` for denial.
    public func start() { tracker.start() }
    public func stop() { tracker.stop() }

    public func applyConfig(_ config: PoseConfig) { tracker.applyConfig(config) }

    /// Resynchronise the pose machine after the session has ended a recording on
    /// its own initiative. See `HandTracker.reset()` for when NOT to call it.
    public func reset() { tracker.reset() }

    public var errorMessage: String? { tracker.errorMessage }
    public var handPresent: Bool { tracker.handPresent }
    public var isLatched: Bool { tracker.isLatched }
}
