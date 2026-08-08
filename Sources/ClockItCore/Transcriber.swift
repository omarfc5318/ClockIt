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

    /// `WhisperKit` is a plain class and not `Sendable`, so it cannot be a
    /// `Task`'s Success type directly. This box carries it across that boundary;
    /// the instance inside is only ever touched from within this actor.
    private final class Loaded: @unchecked Sendable {
        let pipe: WhisperKit
        init(_ pipe: WhisperKit) { self.pipe = pipe }
    }

    /// The single in-flight load. Every caller awaits this same task rather than
    /// starting a second one or giving up.
    private var loadTask: Task<Loaded, Error>?

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

    /// One load, however many callers, whenever they arrive.
    ///
    /// The bug this replaces: `warmUp()` guarded on `.unloaded`, so a dictation
    /// arriving while the launch-time load was still running fell straight
    /// through that guard, found the pipeline still nil, and threw — destroying
    /// audio the user had already spoken. On a first run that window is a
    /// multi-hundred-megabyte download, so it was the common case, not an edge
    /// case, and it violated the one rule that matters: never lose a dictation
    /// someone has already said out loud.
    ///
    /// Actors are reentrant, which is exactly why the old `state` check couldn't
    /// work — the load suspends at its first `await` and lets everyone else
    /// straight past. Awaiting a shared `Task` is the thing that actually
    /// serialises them.
    private func pipeline() async throws -> WhisperKit {
        if let loadTask {
            return try await loadTask.value.pipe
        }

        // `modelName` is a local so the task captures a String rather than self.
        let modelName = model
        let task = Task<Loaded, Error> {
            let config = WhisperKitConfig(model: modelName, prewarm: true, download: true)
            return Loaded(try await WhisperKit(config))
        }
        loadTask = task
        state = .loading

        do {
            let loaded = try await task.value
            state = .ready
            return loaded.pipe
        } catch {
            state = .failed(error.localizedDescription)
            // Cleared so a later dictation can retry. One transient failure —
            // a dropped connection mid-download — shouldn't poison the app for
            // the rest of the session.
            loadTask = nil
            throw error
        }
    }

    /// Downloads and prewarms the model. Call at launch so the first dictation
    /// isn't a multi-minute surprise. Safe to call alongside `transcribe`.
    func warmUp() async {
        _ = try? await pipeline()
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        // Cheap rejection first. Whisper pads anything shorter than 30s anyway;
        // below ~0.4s it's a fumble, and a fumble shouldn't trigger a model
        // download or wait behind one.
        guard samples.count > Int(0.4 * 16_000) else { return "" }

        let pipe = try await pipeline()

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
