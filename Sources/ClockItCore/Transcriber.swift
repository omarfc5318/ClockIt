import Foundation
import WhisperKit

/// Thin wrapper over WhisperKit. Loads the model once, lazily, on first use.
///
/// API verified against WhisperKit v1.1.0, which now ships inside the
/// `argmax-oss-swift` package. `WhisperKitConfig(model:prewarm:download:)`,
/// `DecodingOptions(task:language:detectLanguage:skipSpecialTokens:withoutTimestamps:)`
/// and `transcribe(audioArray:decodeOptions:) async throws -> [TranscriptionResult]`
/// all still have this shape there. If you bump the dependency past 1.1.x,
/// re-check those three.
actor Transcriber {

    enum State {
        case unloaded
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .unloaded
    private var pipe: WhisperKit?

    /// Turbo by default rather than `large-v3`.
    ///
    /// `openai_whisper-large-v3` is ~3 GB resident, which is most of a 16 GB
    /// machine's comfortable budget before phase 2's LLM asks for its share.
    /// The turbo variant is ~630 MB for a workload that is one speaker, close
    /// mic, a few seconds at a time — the accuracy that matters for dictation
    /// is punctuation and proper nouns, and it holds up there.
    ///
    /// Other names that exist in argmaxinc/whisperkit-coreml, if you want to
    /// A/B: "openai_whisper-large-v3-v20240930_turbo" (unquantized),
    /// "distil-whisper_distil-large-v3_turbo_600MB", "openai_whisper-large-v3",
    /// and "openai_whisper-base" (seconds to load, for iterating).
    private let model: String

    /// `nil` auto-detects per dictation. Set to "en" to pin and skip the
    /// detection pass, which is a little faster and can't guess wrong.
    private let language: String?

    init(
        model: String = "openai_whisper-large-v3-v20240930_turbo_632MB",
        language: String? = nil
    ) {
        self.model = model
        self.language = language
    }

    /// Downloads and prewarms the model. Call at launch so the first dictation
    /// isn't a multi-minute surprise.
    func warmUp() async {
        guard case .unloaded = state else { return }
        state = .loading
        do {
            let config = WhisperKitConfig(model: model, prewarm: true, download: true)
            pipe = try await WhisperKit(config)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        if pipe == nil { await warmUp() }
        guard let pipe else { throw TranscriberError.modelUnavailable }

        // Whisper pads anything shorter than 30s anyway; below ~0.4s it's a fumble.
        guard samples.count > Int(0.4 * 16_000) else { return "" }

        let options = DecodingOptions(
            task: .transcribe,             // never .translate — keep the spoken language
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum TranscriberError: Error {
        case modelUnavailable
    }
}
