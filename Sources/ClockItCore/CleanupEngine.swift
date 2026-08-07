import Foundation

/// Phase 1: pass-through. Whisper already returns punctuated text, so the app
/// is fully usable without an LLM.
///
/// This exists as a stub rather than being absent so the call site in
/// `SessionController` is written, wired, and proven before Phase 2 swaps the
/// implementation. The real MLX version lives in `Phase2/CleanupEngine.swift`
/// and matches this interface exactly — dropping it in is a file copy plus one
/// dependency line in Package.swift.
///
/// Keep this signature stable. If Phase 2 needs a different shape, change it
/// HERE first and let the stub keep working, so you never debug a new
/// interface and a new dependency at the same time.
actor CleanupEngine {

    enum State: Equatable {
        case unloaded
        case loading
        case ready
        case failed(String)
    }

    /// Phase 1 has nothing to load, so it is always ready.
    private(set) var state: State = .ready

    /// Menu-bar toggle reads this to decide whether to show the option at all.
    static let isAvailable = false

    init() {}

    func warmUp() async {}

    func clean(_ transcript: String) async -> String {
        transcript
    }
}
