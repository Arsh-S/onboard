import Foundation
import WhisperKit

/// Energy VAD over a stream of 16 kHz chunks. 100 ms frames; speech when RMS > threshold;
/// an utterance ends after 0.6 s of silence. Fragments shorter than `minUtterance` are not
/// dropped: they are carried and prepended to the next utterance if it starts within
/// `carryWindow` seconds (a dropped "Arsh," cost an addressed-to-user verdict in the spike).
public final class EnergyVAD {
    public let frame = SR / 10
    public var threshold: Float
    public let minSilence = 6
    /// Once an utterance is at least `pauseCutAfter` seconds long, a pause of `pauseCut` frames also ends it.
    /// Fast turn-taking leaves gaps of 0.2 to 0.4 s; waiting for 0.6 s glues two speakers into one caption.
    public var pauseCut = 3
    public var pauseCutAfter: Float = 1.5
    public var minUtterance: Float = 0.8
    public let carryWindow: Double = 2.5
    public let preRoll = 2, postRoll = 2

    private var buffer: [Float] = []
    private var bufferStart = 0
    private var framesSeen = 0
    private var inSpeech = false
    private var speechStartFrame = 0
    private var silentRun = 0
    private var lastSpeechFrame = 0
    private var pending: [Float] = []
    private var carry: Utterance?

    public init(threshold: Float = 0.006) { self.threshold = threshold }

    public struct Utterance: Sendable {
        public var audio: [Float]
        public var start: Double
        public var end: Double
        public var duration: Double { end - start }
    }

    /// Current input level (RMS of the last frame), for a level meter.
    public private(set) var level: Float = 0
    public private(set) var speaking = false

    public func feed(_ chunk: [Float]) -> [Utterance] {
        buffer += chunk
        pending += chunk
        var out: [Utterance] = []
        while pending.count >= frame {
            let f = Array(pending[0..<frame]); pending.removeFirst(frame)
            let rms = AudioProcessor.calculateAverageEnergy(of: f)
            level = rms
            let speech = rms > threshold
            if speech {
                if !inSpeech { inSpeech = true; speechStartFrame = framesSeen; speaking = true }
                lastSpeechFrame = framesSeen; silentRun = 0
            } else if inSpeech {
                silentRun += 1
                let spoken = Float(lastSpeechFrame + 1 - speechStartFrame) * Float(frame) / Float(SR)
                if silentRun >= minSilence || (silentRun >= pauseCut && spoken >= pauseCutAfter) {
                    inSpeech = false; speaking = false
                    let s = max(speechStartFrame - preRoll, 0), e = lastSpeechFrame + 1 + postRoll
                    let a = max(s * frame - bufferStart, 0), b = min(e * frame - bufferStart, buffer.count)
                    var u = Utterance(audio: Array(buffer[a..<b]), start: Double(speechStartFrame) * 0.1, end: Double(lastSpeechFrame + 1) * 0.1)
                    if let c = carry, u.start - c.end <= carryWindow {
                        u.audio = c.audio + [Float](repeating: 0, count: 1600) + u.audio
                        u.start = c.start
                    }
                    carry = nil
                    if Float(lastSpeechFrame + 1 - speechStartFrame) * Float(frame) / Float(SR) >= minUtterance || u.duration >= Double(minUtterance) {
                        out.append(u)
                    } else {
                        carry = u
                    }
                }
            }
            framesSeen += 1
        }
        let keepFrom = (inSpeech ? max(speechStartFrame - preRoll, 0) : max(framesSeen - 10, 0)) * frame
        if keepFrom > bufferStart { buffer.removeFirst(min(keepFrom - bufferStart, buffer.count)); bufferStart = keepFrom }
        return out
    }

    /// Flush any carried fragment (end of stream).
    public func flush() -> [Utterance] {
        defer { carry = nil }
        return carry.map { [$0] } ?? []
    }
}
