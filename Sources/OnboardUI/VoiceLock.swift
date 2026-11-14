import AppKit
import Foundation
import Observation
import OnboardCore
import os

private let voiceLog = Logger(subsystem: "net.arshsingh.onboard", category: "voice")

/// Voice lock and always-listening, on Argmax SpeakerKit: Onboard learns the owner's voice from a few seconds of
/// speech, then only that voice can give it orders. With always-listening on, saying "Onboard, ..." starts a request
/// hands-free; anyone else saying it is ignored.
@MainActor @Observable final class VoiceLock {
    enum State: Equatable { case loading, unavailable, ready }
    var state = State.loading
    var enrolled = false
    var enrolling = false
    var enrollProgress = 0.0
    var enrollMessage = ""
    var lastHeard = ""                 // last thing always-listening heard, for the settings window
    var lockEnabled = UserDefaults.standard.object(forKey: "voiceLock") as? Bool ?? true { didSet { UserDefaults.standard.set(lockEnabled, forKey: "voiceLock") } }
    var alwaysListening = UserDefaults.standard.bool(forKey: "alwaysListening") {
        didSet { UserDefaults.standard.set(alwaysListening, forKey: "alwaysListening"); alwaysListening ? startListening() : stopListening() }
    }

    /// Wired by AppModel.
    @ObservationIgnored var ownerName: () -> String = { "Owner" }
    @ObservationIgnored var transcriber: () -> Transcriber? = { nil }
    @ObservationIgnored var canListen: () -> Bool = { true }          // false while Onboard speaks or push-to-talk records
    @ObservationIgnored var onCommand: ((String) -> Void)?
    @ObservationIgnored var onRejected: (() -> Void)?

    @ObservationIgnored private var spk: SpeakerIdentifier?
    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let vad = EnergyVAD(threshold: 0.006)
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var enrollSamples: [Float] = []
    @ObservationIgnored private let lock = NSLock()
    static let enrollSeconds = 8.0
    /// Cosine distance under which a voice counts as the owner (same speaker is typically 0.1 to 0.4, others 0.7+).
    static let ownerDistance: Float = 0.5
    static let store = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Onboard/owner_voice.json")

    func load(downloadBase: URL?) async {
        do {
            let sk = try await SpeakerKitLoader.load(downloadBase: downloadBase)
            let s = SpeakerIdentifier(sk: sk, storeURL: Self.store)
            spk = s
            enrolled = !s.people.isEmpty
            state = .ready
            if alwaysListening { startListening() }
        } catch { state = .unavailable }
    }

    /// True when the lock is off, nobody is enrolled yet, or the audio is the owner's voice.
    func isOwner(_ audio: [Float]) async -> Bool {
        guard lockEnabled, enrolled, let spk else { return true }
        guard let v = try? await spk.identify(audio) else { return false }
        voiceLog.notice("voice distance to owner: \(v.d1)")
        return v.d1 < Self.ownerDistance
    }

    // MARK: enrollment

    func enroll() {
        guard !enrolling, state == .ready, let spk else { return }
        let wasListening = listening
        stopListening()
        enrolling = true; enrollProgress = 0; enrollMessage = "Listening… say a few sentences"
        enrollSamples = []
        capture.onChunk = { [weak self] c in
            guard let self else { return }
            self.lock.lock(); self.enrollSamples += c; let n = self.enrollSamples.count; self.lock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.enrollProgress = min(1, Double(n) / Double(SR) / Self.enrollSeconds) } }
        }
        do { try capture.start() } catch { enrolling = false; enrollMessage = "Microphone unavailable"; return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.enrollSeconds * 1e9))
            capture.stop()
            lock.lock(); let audio = enrollSamples; enrollSamples = []; lock.unlock()
            let name = ownerName()
            do {
                for p in spk.names { try? spk.remove(name: p) }
                _ = try await spk.enroll(name: name, audio: audio)
                try? spk.save()
                enrolled = true; enrollMessage = "Voice saved. Only \(name) can give orders now."
            } catch { enrollMessage = "I could not hear enough speech. Try again a bit closer." }
            enrolling = false
            if wasListening || alwaysListening { startListening() }
        }
    }

    func forget() {
        guard let spk else { return }
        for p in spk.names { try? spk.remove(name: p) }
        try? spk.save()
        enrolled = false; enrollMessage = "Voice forgotten."
    }

    // MARK: always listening

    /// "Onboard, open my notes" / "Hey Onboard ..." (Whisper often writes "on board").
    /// Returns the request after the wake word, or "" when only the wake word was said, or nil when it was not said.
    static func command(in text: String) -> String? {
        // Whisper spells the name many ways: Onboard, on board, On-board, Unboard, Onbord, aboard, on bored, Hey Onboard.
        let pattern = #"^\W*(?:(?:hey|hi|ok|okay|yo|so|and)\W+)?(?:on[\s-]?boa?r[de]{1,2}|on[\s-]?bored|un[\s-]?board|aboard|on[\s-]?bord|on[\s-]?ward)\b\W*"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) else { return nil }
        return text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper's labels for noise and silence.
    static func isNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) || (t.hasPrefix("*") && t.hasSuffix("*"))
    }

    func startListening() {
        guard alwaysListening, !listening, !enrolling, state == .ready else { return }
        listening = true
        capture.onChunk = { [weak self] chunk in
            guard let self else { return }
            self.calibrate(chunk)
            for u in self.vad.feed(chunk) {
                Task { @MainActor in await self.handle(u) }
            }
        }
        do { try capture.start(); voiceLog.notice("always listening started") } catch { listening = false; voiceLog.error("always listening could not start the mic") }
    }

    /// Continuous calibration: the speech threshold follows the room. It sits a little above the quietest recent level,
    /// so a silent room hears soft speech and a noisy one (music, a fan) stops triggering on the background.
    final class Levels: @unchecked Sendable { var recent: [Float] = []; let lock = NSLock() }
    @ObservationIgnored private let levels = Levels()
    private nonisolated func calibrate(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        var sq: Float = 0; for v in chunk { sq += v * v }
        let rms = (sq / Float(chunk.count)).squareRoot()
        levels.lock.lock()
        levels.recent.append(rms); if levels.recent.count > 24 { levels.recent.removeFirst() }    // about 12 s of half-second chunks
        let floor = levels.recent.sorted()[levels.recent.count / 5]                               // 20th percentile = the room's noise floor
        levels.lock.unlock()
        vad.threshold = min(0.03, max(0.004, floor * 2.2))
        vad.minUtterance = 0.35                                                                   // "Onboard" on its own is short
    }

    func stopListening() {
        guard listening else { return }
        listening = false
        capture.stop()
    }

    /// Set when "Onboard" was said on its own: the next thing said within a few seconds is the request.
    @ObservationIgnored private var armedUntil = Date.distantPast
    @ObservationIgnored var onArmed: (() -> Void)?

    private func handle(_ u: EnergyVAD.Utterance) async {
        guard canListen() else { return }
        guard u.duration >= 0.4, u.duration < 20, let t = transcriber() else { return }
        guard let text = try? await t.transcribe(u.audio), !Self.isNoise(text) else { return }
        lastHeard = text
        let armed = Date() < armedUntil
        var request: String
        if let rest = Self.command(in: text) {
            if rest.count < 3 {
                // Just the name: check it is the owner, then wait for the request.
                guard await isOwner(u.audio) else { voiceLog.notice("wake word from another voice"); onRejected?(); return }
                armedUntil = Date().addingTimeInterval(7)
                voiceLog.notice("wake word alone: armed")
                onArmed?()
                return
            }
            request = rest
        } else if armed {
            request = text
        } else {
            voiceLog.notice("heard, no wake word: \(text, privacy: .public)")
            return                                                      // not addressed to Onboard: ignored, not kept
        }
        armedUntil = .distantPast
        let owner = armed ? true : await isOwner(u.audio)               // an armed request was already checked on the wake word
        voiceLog.notice("request heard, owner=\(owner): \(request, privacy: .public)")
        guard owner else { onRejected?(); return }
        guard canListen() else { return }
        request = request.trimmingCharacters(in: CharacterSet(charactersIn: " ,.") )
        onCommand?(request)
    }
}
