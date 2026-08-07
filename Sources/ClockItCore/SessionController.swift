import Foundation

/// The idle → recording → transcribing machine from the diagram.
/// Everything else is a collaborator; this file owns the state.
@MainActor
public final class SessionController: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    @Published public private(set) var phase: Phase = .idle
    /// True once the recording has locked on and the hand is free.
    @Published public private(set) var isLatched = false
    @Published public private(set) var lastTranscript: String = ""
    @Published public private(set) var statusMessage: String?

    /// Runaway guard. Less critical than it was under toggle — an unlatched
    /// recording ends the moment you relax your hand — but a latched one will
    /// happily run until you come back to it.
    public var maxDuration: TimeInterval = 180

    private let gesture = GestureTrigger()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let cleanup = CleanupEngine()

    /// Toggle from the menu bar. Off falls back to the raw Whisper transcript.
    ///
    /// Left ON in phase 1 even though `CleanupEngine` is a pass-through — the
    /// point of the stub is that the async call path is exercised now, so
    /// phase 2 swaps an implementation rather than debugging new wiring.
    public var cleanupEnabled = true

    private var maxDurationTask: Task<Void, Never>?

    public init() {}

    public func start() {
        gesture.onEvent = { [weak self] event in self?.handle(event) }
        gesture.start()

        // Microphone setup waits for TCC before it is allowed to look at the
        // input node's format at all. See AudioRecorder.requestMicrophoneAccess().
        Task { [weak self] in
            guard let self else { return }
            guard await AudioRecorder.requestMicrophoneAccess() else {
                self.statusMessage = "Microphone access denied. Grant it in System Settings › Privacy & Security › Microphone."
                return
            }
            do {
                try self.recorder.prepare()
            } catch {
                self.statusMessage = Self.describe(error)
            }
        }

        if !TextInjector.hasAccessibilityPermission {
            TextInjector.requestAccessibilityPermission()
        }

        // Pull models down at launch rather than mid-dictation.
        Task { await transcriber.warmUp() }
        Task { await cleanup.warmUp() }
    }

    public func stop() {
        gesture.stop()
        maxDurationTask?.cancel()
    }

    private static func describe(_ error: Error) -> String {
        guard let recorderError = error as? AudioRecorder.RecorderError else {
            return "Microphone unavailable: \(error.localizedDescription)"
        }
        switch recorderError {
        case .microphoneAccessDenied:
            return "Microphone access denied. Grant it in System Settings › Privacy & Security › Microphone."
        case .inputUnavailable:
            return "No usable microphone input — check System Settings › Sound › Input."
        case .formatUnavailable, .converterUnavailable:
            return "Could not set up 16 kHz mono capture from this input device."
        }
    }

    private func handle(_ event: GestureEvent) {
        // Gestures are ignored entirely while the model is working.
        guard phase != .transcribing else { return }

        switch event {
        case .start:
            guard phase == .idle else { return }
            beginRecording()
        case .latch:
            guard phase == .recording else { return }
            isLatched = true
        case .stop:
            guard phase == .recording else { return }
            endRecording()
        }
    }

    private func beginRecording() {
        recorder.start()
        phase = .recording
        isLatched = false
        statusMessage = nil

        maxDurationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.maxDuration))
            guard !Task.isCancelled, self.phase == .recording else { return }
            self.statusMessage = "Stopped at the \(Int(self.maxDuration))s limit"
            self.endRecording()
        }
    }

    private func endRecording() {
        maxDurationTask?.cancel()
        maxDurationTask = nil

        let samples = recorder.stop()
        phase = .transcribing
        isLatched = false

        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.transcriber.transcribe(samples)
                let text = self.cleanupEnabled ? await self.cleanup.clean(raw) : raw
                self.deliver(text)
            } catch {
                self.statusMessage = "Transcription failed: \(error.localizedDescription)"
            }
            self.phase = .idle
        }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else { return }
        lastTranscript = text
        if !TextInjector.deliver(text) {
            statusMessage = "Copied to clipboard — grant Accessibility to type automatically"
        }
    }

    // Surfaced for the menu bar UI.
    public var micLevel: Float { recorder.currentLevel() }
    public var handPresent: Bool { gesture.handPresent }

    public func applyGestureConfig(_ config: PoseConfig) { gesture.applyConfig(config) }
    public var cameraError: String? { gesture.errorMessage }
}
