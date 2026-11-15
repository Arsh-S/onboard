import Foundation
import TTSKit

/// TTSKit (Qwen3-TTS 0.6b) wrapper. `speak` streams straight to the speakers.
public final class SpeechOut: @unchecked Sendable {
    public let tts: TTSKit
    public var voice: Qwen3Speaker = .ryan      // a man's voice (the others: aiden, eric, dylan)
    public static let voices: [Qwen3Speaker] = Qwen3Speaker.allCases

    /// `downloadBase` mirrors the Hugging Face cache layout (<base>/models/<org>/<repo>). The Qwen tokenizer is
    /// resolved from that same tree when it is present locally, so an app bundle never has to touch ~/Documents.
    public init(downloadBase: URL? = nil) async throws {
        var tokenizerFolder: URL? = nil
        if let b = downloadBase {
            let t = b.appendingPathComponent("models/Qwen/Qwen3-0.6B")
            if FileManager.default.fileExists(atPath: t.appendingPathComponent("tokenizer.json").path) { tokenizerFolder = t }
        }
        tts = try await TTSKit(TTSKitConfig(model: .qwen3TTS_0_6b, downloadBase: downloadBase, tokenizerFolder: tokenizerFolder, verbose: false, logLevel: .none, seed: 42))
        try await tts.loadModels()
    }

    private var halted = false

    /// Stop talking now: generation ends at the next chunk and what is already queued is dropped.
    public func stop() async {
        halted = true
        await tts.audioOutput.stopPlayback(waitForCompletion: false)
    }

    public var options: GenerationOptions { GenerationOptions(temperature: 0.7, concurrentWorkerCount: 1) }

    /// Returns time to first audio buffer and total generation time.
    @discardableResult
    public func speak(_ text: String) async throws -> (firstAudio: Double, total: Double) {
        let t0 = now()
        final class Box: @unchecked Sendable { var first: Double? }
        let box = Box()
        halted = false
        _ = try await tts.play(text: text, speaker: voice, language: .english, options: options) { [weak self] p in
            if box.first == nil, !p.audio.isEmpty { box.first = now() - t0 }
            return !(self?.halted ?? false)
        }
        return (box.first ?? 0, now() - t0)
    }

    /// Generate without playing (used by the CLI and for tests).
    public func synthesize(_ text: String, voice: Qwen3Speaker? = nil) async throws -> (audio: [Float], sampleRate: Int, firstAudio: Double, total: Double) {
        let t0 = now()
        final class Box: @unchecked Sendable { var first: Double? }
        let box = Box()
        let r = try await tts.generate(text: text, speaker: voice ?? self.voice, language: .english, options: options) { p in
            if box.first == nil, !p.audio.isEmpty { box.first = now() - t0 }
            return true
        }
        return (r.audio, r.sampleRate, box.first ?? 0, now() - t0)
    }

    public func warm() async throws { _ = try await synthesize("Ready.") }
}
