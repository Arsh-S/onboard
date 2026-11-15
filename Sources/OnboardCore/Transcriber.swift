import Foundation
import WhisperKit

/// WhisperKit wrapper. Enrolled names are passed as the decoding prompt so Whisper spells them right.
public final class Transcriber: @unchecked Sendable {
    public let wk: WhisperKit
    public let modelName: String
    private var names: [String] = []
    private var promptTokens: [Int]? = nil

    public init(model: String = "base.en", downloadBase: URL? = nil) async throws {
        modelName = model
        wk = try await WhisperKit(model: model, downloadBase: downloadBase, verbose: false, logLevel: .none, prewarm: true, load: true)
    }

    public func setNames(_ names: [String]) {
        self.names = names
        guard let tok = wk.tokenizer, !names.isEmpty else { promptTokens = nil; return }
        // Whisper's prompt is "previous context"; a plain list of the names at the table works.
        promptTokens = tok.encode(text: " " + names.joined(separator: ", ") + ".")
    }

    /// Recent caption text, appended after the names in the prompt so Whisper hears each line in context.
    /// Kept short: a long prompt makes Whisper repeat it on near-silent audio.
    public var useContext = true

    func prompt(context: String?) -> [Int]? {
        guard let tok = wk.tokenizer else { return promptTokens }
        var p = names.isEmpty ? "" : " " + names.joined(separator: ", ") + "."
        if useContext, let c = context?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            p += " " + String(c.split(separator: " ").suffix(24).joined(separator: " "))
        }
        return p.isEmpty ? nil : tok.encode(text: p)
    }

    public var decodeOptions: DecodingOptions {
        var o = DecodingOptions(task: .transcribe, language: "en", withoutTimestamps: true)
        o.promptTokens = promptTokens
        return o
    }

    public func transcribe(_ audio: [Float], context: String? = nil) async throws -> String {
        var o = decodeOptions
        o.promptTokens = prompt(context: context)
        let r = try await wk.transcribe(audioArray: Self.padded(audio), decodeOptions: o)
        return r.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// WhisperKit returns nothing for clips of about half a second (a lone "Onboard"), so short audio gets
    /// silence on both sides up to 1.5 s.
    static func padded(_ audio: [Float]) -> [Float] {
        let want = SR * 3 / 2
        guard !audio.isEmpty, audio.count < want else { return audio }
        let pad = (want - audio.count + 1) / 2
        return [Float](repeating: 0, count: pad) + audio + [Float](repeating: 0, count: pad)
    }

    public struct Word: Sendable { public let text: String; public let start: Float; public let end: Float }

    /// One pass over the whole utterance with word timings, so a turn split hands each speaker their words
    /// without transcribing short pieces on their own (a lone half-second word is what Whisper mishears).
    public func transcribeWords(_ audio: [Float], context: String? = nil) async throws -> (text: String, words: [Word]) {
        var o = decodeOptions
        o.promptTokens = prompt(context: context)
        o.withoutTimestamps = false
        o.wordTimestamps = true
        let r = try await wk.transcribe(audioArray: audio, decodeOptions: o)
        let words = r.flatMap { $0.segments }.flatMap { $0.words ?? [] }
            .map { Word(text: $0.word, start: $0.start, end: $0.end) }
        let text = r.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, words)
    }

    /// Words whose midpoint falls in [start, end), joined back into text.
    public static func words(_ w: [Word], from start: Float, to end: Float) -> String {
        w.filter { ($0.start + $0.end) / 2 >= start && ($0.start + $0.end) / 2 < end }
            .map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First CoreML call is slow; run one dummy transcription at startup.
    public func warm() async throws {
        _ = try await transcribe([Float](repeating: 0, count: SR) )
    }
}
