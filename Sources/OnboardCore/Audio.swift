import Foundation
import AVFoundation
import WhisperKit

/// Everything in Onboard is 16 kHz mono Float32.
public let SR = 16000

public func now() -> Double { CFAbsoluteTimeGetCurrent() }
public func fmt(_ s: Double) -> String { String(format: "%.2fs", s) }

/// Repeat `a` (with 0.2 s gaps) until it is at least `secs` long. SpeakerKit centroids are
/// only stable when the diarized clip is about 30 s, so every utterance is tiled before embedding.
public func tileAudio(_ a: [Float], to secs: Float) -> [Float] {
    guard secs > 0, !a.isEmpty else { return a }
    var out = a
    while Float(out.count) / Float(SR) < secs { out += [Float](repeating: 0, count: 3200) + a }
    return out
}

public func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    return 1 - dot / (sqrt(na) * sqrt(nb) + 1e-9)
}

public func floatBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return buf
}

public func resampleTo16k(_ samples: [Float], from rate: Int) -> [Float] {
    if rate == SR { return samples }
    let buf = floatBuffer(samples, sampleRate: Double(rate))
    guard let out = AudioProcessor.resampleAudio(fromBuffer: buf, toSampleRate: Double(SR), channelCount: 1) else { return samples }
    return AudioProcessor.convertBufferToArray(buffer: out)
}

public func loadAudio16k(_ url: URL) throws -> [Float] {
    try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
}

public func writeWav16k(_ samples: [Float], to url: URL) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(SR), AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: floatBuffer(samples, sampleRate: Double(SR)))
}

/// Simple latency accumulator.
public struct Stat: Sendable {
    public var xs: [Double] = []
    public init() {}
    public mutating func add(_ x: Double) { xs.append(x) }
    public var count: Int { xs.count }
    public var mean: Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    public var p95: Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[min(Int((Double(s.count - 1) * 0.95).rounded()), s.count - 1)] }
    public var last: Double { xs.last ?? 0 }
    public var line: String { xs.isEmpty ? "n=0" : String(format: "n=%-3d mean %.2fs  p95 %.2fs  max %.2fs", xs.count, mean, p95, xs.max()!) }
}
