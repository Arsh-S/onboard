import Foundation
import AVFoundation
import os

public let captureLog = Logger(subsystem: "net.arshsingh.onboard", category: "capture")

/// Microphone capture via AVAudioEngine, converted to 16 kHz mono Float, delivered in ~0.5 s chunks.
public final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SR), channels: 1, interleaved: false)!
    private var acc: [Float] = []
    private let chunk = SR / 2
    private let lock = NSLock()
    public var onChunk: (([Float]) -> Void)?
    /// RMS of every input buffer (~80 ms), for a live level meter.
    public var onLevel: ((Float) -> Void)?
    public private(set) var running = false
    private var chunksDelivered = 0
    private var configObserver: NSObjectProtocol?

    public init() {}

    public static func requestPermission() async -> Bool {
        if #available(macOS 14.0, *) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        }
        return true
    }

    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw OnboardError("no audio input device") }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self, let conv = self.converter else { return }
            let ratio = Double(SR) / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: cap) else { return }
            var err: NSError?
            var consumed = false
            conv.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buf
            }
            guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            if let onLevel = self.onLevel, !samples.isEmpty {
                var sum: Float = 0; for x in samples { sum += x * x }
                onLevel(sqrt(sum / Float(samples.count)))
            }
            self.lock.lock()
            self.acc += samples
            var ready: [[Float]] = []
            while self.acc.count >= self.chunk { ready.append(Array(self.acc[0..<self.chunk])); self.acc.removeFirst(self.chunk) }
            self.lock.unlock()
            for c in ready {
                self.chunksDelivered += 1
                if self.chunksDelivered % 40 == 1 { captureLog.notice("chunk \(self.chunksDelivered) delivered (\(inFormat.sampleRate) Hz in)") }
                self.onChunk?(c)
            }
        }
        // The engine stops silently when the audio route or sample rate changes (headphones, TTS playback
        // on some devices). Restart the tap when that happens.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self, self.running else { return }
            captureLog.warning("audio engine configuration changed; restarting capture")
            self.engine.inputNode.removeTap(onBus: 0)
            self.running = false
            try? self.start()
        }
        engine.prepare()
        try engine.start()
        running = true
        captureLog.notice("capture started: \(inFormat.sampleRate) Hz, \(inFormat.channelCount) ch")
    }

    public func stop() {
        guard running else { return }
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        lock.lock(); acc.removeAll(); lock.unlock()
    }
}

/// Collects raw 16 kHz audio for enrollment (N seconds of the person reading a sentence).
public final class Recorder: @unchecked Sendable {
    private let capture = AudioCapture()
    private var samples: [Float] = []
    private let lock = NSLock()
    public var onLevel: ((Float, Double) -> Void)?
    public init() {}

    public func start() throws {
        samples = []
        capture.onChunk = { [weak self] c in
            guard let self else { return }
            self.lock.lock(); self.samples += c; let n = self.samples.count; self.lock.unlock()
            _ = n
        }
        // Level for the waveform comes from every input buffer (about 80 ms), not from the half-second chunks.
        capture.onLevel = { [weak self] rms in
            guard let self else { return }
            self.lock.lock(); let n = self.samples.count; self.lock.unlock()
            self.onLevel?(rms, Double(n) / Double(SR))
        }
        try capture.start()
    }

    public func stop() -> [Float] {
        capture.stop()
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}
