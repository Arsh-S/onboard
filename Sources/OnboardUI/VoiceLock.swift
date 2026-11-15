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
    @ObservationIgnored var accurate: () -> Transcriber? = { nil }     // the large model, for the request itself
    @ObservationIgnored var canListen: () -> Bool = { true }          // false while Onboard speaks or push-to-talk records
    @ObservationIgnored var onCommand: ((String) -> Void)?
    @ObservationIgnored var onRejected: (() -> Void)?
    /// "Cancel" said while Onboard is working (hands-free stop).
    @ObservationIgnored var isWorking: () -> Bool = { false }
    @ObservationIgnored var onCancel: (() -> Void)?
    /// A request ends after this long a pause (a lone word like "Onboard" or "cancel" still registers after 0.6 s).
    static let requestPause = 1.4

    @ObservationIgnored private var spk: SpeakerIdentifier?
    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let vad = EnergyVAD(threshold: 0.006)
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var enrollSamples: [Float] = []
    @ObservationIgnored private let lock = NSLock()
    static let enrollSeconds = 8.0
    /// Cosine distance under which a voice counts as the owner (same speaker is typically 0.1 to 0.4, others 0.7+).
    static let ownerDistance: Float = 0.62
    /// Distance of the last voice checked, and the clip if it was turned away (so the owner can say "that was me").
    var lastDistance: Float?
    var canLearnLast = false
    @ObservationIgnored private var lastRejected: [Float]?
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
        lastDistance = v.d1
        let ok = v.d1 < Self.ownerDistance
        if ok {
            canLearnLast = false; lastRejected = nil
            // Keep learning: every accepted clip sharpens the profile a little.
            if v.d1 > 0.25 { try? await spk.addSample(name: ownerName(), audio: audio, weight: 0.5) }
        } else { lastRejected = audio; canLearnLast = true }
        return ok
    }

    // MARK: enrollment

    static let trainPrompts = [
        "Say:  Onboard", "Again:  Onboard", "Once more:  Onboard", "A bit quieter:  Onboard", "From further back:  Onboard",
        "Say:  Onboard, what's on my calendar today?", "Say:  Onboard, remind me to call back tomorrow.",
        "Now talk normally for a few seconds, about anything.",
    ]
    @ObservationIgnored private var trainStep = 0
    @ObservationIgnored private var trainVAD: EnergyVAD?
    @ObservationIgnored private var trainFresh = true

    /// Guided training: the wake word several ways, two full requests, and some free speech. Each one becomes a sample.
    func enroll() {
        guard !enrolling, state == .ready, spk != nil else { return }
        stopListening()
        enrolling = true; enrollProgress = 0; trainStep = 0; trainFresh = true
        enrollMessage = Self.trainPrompts[0]
        let tv = EnergyVAD(threshold: max(0.006, vad.threshold)); tv.minUtterance = 0.3
        trainVAD = tv
        capture.onChunk = { [weak self] chunk in
            guard let self else { return }
            for u in tv.feed(chunk) { Task { @MainActor in await self.trainSample(u) } }
        }
        do { try capture.start() } catch { enrolling = false; enrollMessage = "Microphone unavailable"; return }
        Task {   // give up politely if nothing is heard for a long time
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            if enrolling { finishTraining(message: trainStep > 0 ? "Saved \(trainStep) samples." : "I did not hear anything. Try again.") }
        }
    }

    private func trainSample(_ u: EnergyVAD.Utterance) async {
        guard enrolling, u.duration >= 0.3, let spk else { return }
        let prompt = Self.trainPrompts[min(trainStep, Self.trainPrompts.count - 1)]
        if let t = transcriber(), let text = try? await t.transcribe(u.audio), Self.isNoise(text) {             // a cough or a click is not a sample
            voiceLog.notice("training: clip of \(u.duration) s was noise")
            if enrolling { enrollMessage = "I did not catch that.  " + prompt }
            return
        }
        guard enrolling else { return }
        let name = ownerName()
        // The old profile is only replaced once a new sample has actually been taken.
        do {
            let fresh = trainFresh
            if fresh { for p in spk.names { try? spk.remove(name: p) } }
            try await spk.addSample(name: name, audio: u.audio, weight: u.duration > 2 ? 2 : 1)
            trainFresh = false
        } catch {
            voiceLog.notice("training: clip of \(u.duration) s gave no voice print: \(String(describing: error), privacy: .public)")
            if enrolling { enrollMessage = "A little longer or louder.  " + prompt }
            return
        }
        trainStep += 1
        enrolled = true
        enrollProgress = Double(trainStep) / Double(Self.trainPrompts.count)
        if trainStep >= Self.trainPrompts.count { finishTraining(message: "Trained on \(trainStep) samples. Onboard knows your voice.") }
        else { enrollMessage = Self.trainPrompts[trainStep] }
    }

    private func finishTraining(message: String) {
        capture.stop(); trainVAD = nil
        enrolling = false; enrollMessage = message
        canLearnLast = false; lastRejected = nil
        if alwaysListening { startListening() }
    }

    /// "That was me": add the clip that was just turned away to the profile.
    func learnLastRejected() {
        guard let audio = lastRejected, let spk else { return }
        canLearnLast = false; lastRejected = nil
        Task {
            try? await spk.addSample(name: ownerName(), audio: audio, weight: 2)
            enrolled = true
            enrollMessage = "Got it. I added that to your voice."
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
        vad.silenceAfterSpeech = Int(Self.requestPause * 10)
        capture.onChunk = { [weak self] chunk in
            guard let self else { return }
            self.calibrate(chunk)
            for u in self.vad.feed(chunk) {
                Task { @MainActor in await self.handle(u) }
            }
        }
        capture.onLevel = { [weak self] rms in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, Date() < self.armedUntil else { return }
                self.onLevel?(rms)
            } }
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
    /// Mic level while Onboard waits for the request after the wake word, so the pill's bars move as they do for push to talk.
    @ObservationIgnored var onLevel: ((Float) -> Void)?

    /// "cancel", "stop", "never mind", with or without the wake word in front. Only ever a short phrase on its own.
    static func isCancel(_ text: String) -> Bool {
        let rest = command(in: text) ?? text
        let words = rest.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return false }
        let phrase = words.joined(separator: " ")
        return ["cancel", "cancel that", "cancel it", "stop", "stop that", "stop it", "never mind", "nevermind", "abort", "no stop", "no cancel"].contains(phrase)
    }

    private func handle(_ u: EnergyVAD.Utterance) async {
        // While Onboard works it takes no new orders, but its owner can still call it off.
        if isWorking() {
            guard u.duration >= 0.3, u.duration < 3, let t = transcriber(), let text = try? await t.transcribe(u.audio), Self.isCancel(text) else { return }
            guard await isOwner(u.audio) else { voiceLog.notice("cancel from another voice, ignored"); return }
            voiceLog.notice("cancel heard")
            armedUntil = .distantPast
            if isWorking() { onCancel?() }
            return
        }
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
        // The small model only had to spot the wake word. The request itself is read again by the accurate one.
        if let a = accurate(), let better = try? await a.transcribe(u.audio), !Self.isNoise(better) {
            if let rest = Self.command(in: better) { if rest.count >= 3 { request = rest } } else if armed { request = better }
        }
        let owner = armed ? true : await isOwner(u.audio)               // an armed request was already checked on the wake word
        voiceLog.notice("request heard, owner=\(owner): \(request, privacy: .public)")
        guard owner else { onRejected?(); return }
        guard canListen() else { return }
        request = request.trimmingCharacters(in: CharacterSet(charactersIn: " ,.") )
        onCommand?(request)
    }
}
