import AppKit
import AVFoundation
import Network
import Observation
import OnboardCore
import OnboardOverlay

enum LoadState: Equatable {
    case loading, ready
    case failed(String)
}

enum PillState: Equatable { case idle, listening, thinking, speaking, done }

enum VoiceMode { case talk, dictate }

/// Everything the UI shows, and the glue between the hotkeys, the microphone, the agent and the speaker.
@MainActor @Observable
final class AppModel {
    // Settings (UserDefaults).
    var owner: String { didSet { UserDefaults.standard.set(owner, forKey: Keys.owner); agent.owner = owner.isEmpty ? "you" : owner; applyNames() } }
    var speakAnswers: Bool { didSet { UserDefaults.standard.set(speakAnswers, forKey: Keys.speak) } }

    /// Voice lock and always-listening (Argmax SpeakerKit).
    let voice = VoiceLock()

    // Core objects.
    let bonsai: Bonsai
    let memory: MemoryIndex
    let agent: Agent
    let memoryFolder: URL
    @ObservationIgnored private(set) var transcriber: Transcriber?
    /// The large Whisper model, for what is said on purpose (push to talk, dictation, a request after the wake word).
    /// The small one stays for the always-on wake word check, where speed matters and the words do not.
    @ObservationIgnored private(set) var accurate: Transcriber?
    static let accurateModel = "large-v3-v20240930_626MB"
    @ObservationIgnored private(set) var speech: SpeechOut?
    @ObservationIgnored private let recorder = Recorder()
    @ObservationIgnored private let audioQ = DispatchQueue(label: "net.arshsingh.onboard.audio")
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    // Status.
    var hearing = LoadState.loading
    var speaking = LoadState.loading
    var thinking = LoadState.loading
    var tokPerSec = 0.0
    var online = false
    var notes = 0
    var indexing = false
    var axTrusted = Screen.trusted
    var eyesGranted = Eyes.permitted
    var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var hotkeyFailures: Set<UInt32> = []

    // Command bar.
    var query = ""
    var compact = false
    var showTurn = false            // the bar shows the agent's steps and answer for the current turn
    var answer = ""
    var replySecs: Double?
    var focusToken = 0
    @ObservationIgnored var targetApp: NSRunningApplication?

    // Voice pill.
    var pill = PillState.idle
    var levels: [Float] = Array(repeating: 0, count: 5)   // newest first; bar i reads the level |i - 4| samples ago
    var liveTranscript = ""
    private(set) var recording: VoiceMode?
    private(set) var speakingNow = false

    // Wired by the app delegate.
    @ObservationIgnored var onShowCompact: (() -> Void)?
    @ObservationIgnored var onTurnEnded: (() -> Void)?
    @ObservationIgnored var onReleaseKeyboard: (() -> Void)?
    @ObservationIgnored var onNeedSettings: (() -> Void)?

    @ObservationIgnored private var runStart = 0.0
    @ObservationIgnored private var gotReply = false
    @ObservationIgnored private var pillToken = 0
    @ObservationIgnored private var voiceTarget: NSRunningApplication?
    @ObservationIgnored private var timer: Timer?

    private enum Keys { static let owner = "owner", speak = "speakAnswers", launched = "launchedBefore" }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [Keys.owner: "Arsh", Keys.speak: true])
        let support = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Onboard")
        memoryFolder = support.appendingPathComponent("memory")
        try? FileManager.default.createDirectory(at: memoryFolder, withIntermediateDirectories: true)
        bonsai = Bonsai()
        memory = MemoryIndex(folders: [memoryFolder], store: support.appendingPathComponent("memory_index.json"))
        agent = Agent(bonsai: bonsai, memory: memory)
        owner = d.string(forKey: Keys.owner) ?? "Arsh"
        speakAnswers = d.bool(forKey: Keys.speak)
        agent.owner = owner.isEmpty ? "you" : owner
        agent.stage = OverlayStage.shared
        notes = memory.fileCount
    }

    var bonsaiReachable: Bool { if case .failed = thinking { return false }; return true }

    var firstLaunch: Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: Keys.launched) { return false }
        d.set(true, forKey: Keys.launched)
        return true
    }

    // MARK: launch

    func start() {
        OverlayStage.shared.onSpeak = { [weak self] text in await self?.say(text) }
        loadModels()
        reindex()
        Eyes.warm()
        Task { await checkBonsai(measure: true) }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.online = up } }
        }
        pathMonitor.start(queue: DispatchQueue(label: "net.arshsingh.onboard.path"))
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var ticks = 0
    private func tick() {
        ticks += 1
        let ax = Screen.trusted
        if ax != axTrusted { axTrusted = ax }
        if ticks % 5 == 0 { let e = Eyes.permitted; if e != eyesGranted { eyesGranted = e } }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if mic != micGranted { micGranted = mic }
        // Keep trying to find LM Studio until it is there (cheap), without disturbing a running turn.
        if thinking != .ready, !agent.running, ticks % 3 == 0 { Task { await checkBonsai(measure: true) } }
    }

    private func loadModels() {
        let shared = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Tableside/huggingface")
        let base: URL? = FileManager.default.fileExists(atPath: shared.path) ? shared : nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let t = try await Transcriber(downloadBase: base)
                try? await t.warm()
                await self?.hearingLoaded(t)
                // The accurate model takes longer to load (much longer the first time); until then the small one does everything.
                if let big = try? await Transcriber(model: AppModel.accurateModel, downloadBase: base) {
                    try? await big.warm()
                    await self?.accurateLoaded(big)
                }
            } catch { await self?.setHearing(.failed("Could not load")) }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                await MainActor.run { [weak self] in self?.wireVoice(base: base) }
                let s = try await SpeechOut(downloadBase: base)
                try? await s.warm()
                await self?.speechLoaded(s)
            } catch { await self?.setSpeaking(.failed("Could not load")) }
        }
    }

    private func hearingLoaded(_ t: Transcriber) { transcriber = t; hearing = .ready; applyNames() }
    private func speechLoaded(_ s: SpeechOut) { speech = s; speaking = .ready }
    private func setHearing(_ s: LoadState) { hearing = s }
    private func setSpeaking(_ s: LoadState) { speaking = s }
    private func accurateLoaded(_ t: Transcriber) { accurate = t; applyNames(); captureLog.notice("accurate speech model loaded: \(AppModel.accurateModel, privacy: .public)") }
    private func applyNames() {
        let names = (owner.isEmpty ? [] : [owner]) + ["Onboard"]
        transcriber?.setNames(names)                               // the wake word check keeps a short list
        accurate?.setNames(names + Self.vocabulary())              // deliberate speech gets the full word bank
    }

    /// Words Whisper should know how to spell: one per line in Application Support/Onboard/vocabulary.txt.
    /// The file is created with a starter list and can be edited by hand; it is read at launch.
    static let vocabularyFile = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Onboard/vocabulary.txt")
    static let starterVocabulary = ["Claude Code", "Claude", "cmux", "LM Studio", "Bonsai", "Whisper", "Xcode", "GitHub", "TextEdit", "Finder", "Safari", "Arc",
                                    "Notion", "Spotify", "Messages", "Slack", "Discord", "Terminal", "Raycast", "Cornell", "Bilal", "text-to-speech", "hands-free"]
    static func vocabulary() -> [String] {
        if !FileManager.default.fileExists(atPath: vocabularyFile.path) {
            try? FileManager.default.createDirectory(at: vocabularyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? starterVocabulary.joined(separator: "\n").write(to: vocabularyFile, atomically: true, encoding: .utf8)
        }
        let lines = (try? String(contentsOf: vocabularyFile, encoding: .utf8))?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } ?? starterVocabulary
        return Array(lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.prefix(60))      // a very long list makes Whisper invent words
    }

    func checkBonsai(measure: Bool) async {
        guard let models = try? await bonsai.models() else { thinking = .failed("LM Studio is not running"); return }
        if let missing = [bonsai.big, bonsai.small].first(where: { m in !models.contains(m) }) {
            thinking = .failed("\(missing) not found"); return
        }
        thinking = .ready
        if measure, tokPerSec == 0, !agent.running, let s = await bonsai.speed() { tokPerSec = s }
    }

    func reindex() {
        guard !indexing else { return }
        indexing = true
        let m = memory
        Task.detached { [weak self] in
            await m.refresh()
            let n = m.fileCount
            await self?.indexed(n)
        }
    }
    private func indexed(_ n: Int) { notes = n; indexing = false }

    // MARK: permissions

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        axTrusted = Screen.trusted
    }

    /// Screen Recording lets Onboard take a picture of a window: a backup sense, and the visual check of its own work.
    func requestEyes() {
        if !Eyes.requestPermission(), let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
        eyesGranted = Eyes.permitted
    }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied,
           let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(u); return
        }
        Task { micGranted = await AudioCapture.requestPermission() }
    }

    func openMemoryFolder() { NSWorkspace.shared.open(memoryFolder) }
    func openSource(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    // MARK: running a turn

    /// Run the agent on `text` against `app` (the app the user was in before Onboard showed anything).
    func run(_ text: String, app: NSRunningApplication?) {
        let req = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty, !agent.running else { return }
        query = ""; answer = ""; showTurn = true; gotReply = false
        runStart = CFAbsoluteTimeGetCurrent()
        setPill(.thinking)
        // What was heard shows for a moment, then the pill goes back to plain dots for the rest of the run.
        let token = pillToken
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if pillToken == token { liveTranscript = "" }
        }
        onShowCompact?()
        Task {
            await agent.run(req, app: app)
            turnEnded()
        }
    }

    func submit() { run(query, app: targetApp) }

    func stop() { agent.cancel(); clearScreen() }
    /// Wired by the app: closes the command bar when a run is called off by voice.
    @ObservationIgnored var onCancelled: (() -> Void)?

    /// Option-Space sends Onboard away: the cursor overlay and the pill go at once, not when the current step returns.
    func clearScreen() {
        OverlayStage.shared.dismiss()
        if speakingNow, let s = speech { speakingNow = false; setPill(.idle); Task { await s.stop() } }      // stop talking too
        if recording == nil, pill != .speaking { setPill(.idle); liveTranscript = "" }
    }

    private func turnEnded() {
        // The footer keeps the measured generation speed; per-request figures include prompt reading and would understate it.
        if answer.isEmpty { answer = agent.answer }
        if !gotReply { replySecs = CFAbsoluteTimeGetCurrent() - runStart }
        if pill == .thinking { setPill(.idle) }
        notes = memory.fileCount
        onTurnEnded?()
    }

    /// The agent's voice: show the text, and speak it when speaking is on. Recording never overlaps this.
    private func say(_ text: String) async {
        answer = text
        if !gotReply { replySecs = CFAbsoluteTimeGetCurrent() - runStart; gotReply = true }
        guard speakAnswers, let s = speech else { finishPill(); return }
        // Speak in the background: the turn ends as soon as the answer is on screen, so the bar can be closed right away.
        abandonRecording()
        speakingNow = true
        setPill(.speaking)
        Task { [weak self] in
            _ = try? await s.speak(text)
            guard let self, self.speakingNow else { return }      // cut short by cancel: the pill is already cleared
            self.speakingNow = false
            self.finishPill()
        }
    }

    // MARK: voice

    func beginVoice(_ mode: VoiceMode, target: NSRunningApplication? = nil) {
        guard recording == nil, !speakingNow, pill != .speaking else { return }      // never record while speaking
        if mode == .talk, agent.running { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { requestMicrophone(); onNeedSettings?(); return }
        voiceTarget = target ?? Screen.targetApp(excluding: Bundle.main.bundleIdentifier)
        recording = mode
        liveTranscript = ""
        levels = Array(repeating: 0, count: levels.count)
        setPill(.listening)
        let rec = recorder
        rec.onLevel = { [weak self] level, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pushLevel(level) } }
        }
        audioQ.async { [weak self] in
            do { try rec.start() } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.voiceFailed("Microphone unavailable") } }
            }
        }
    }

    /// fn was held first and control joined a moment later: keep the same recording, treat it as dictation.
    func switchToDictate() {
        guard recording == .talk else { return }
        recording = .dictate
    }

    func endVoice(_ mode: VoiceMode) {
        guard recording == mode else { return }
        recording = nil
        setPill(.thinking)
        let rec = recorder, t = accurate ?? transcriber
        audioQ.async { [weak self] in
            Thread.sleep(forTimeInterval: 0.25)      // the key usually comes up while the last word is still being said
            let samples = rec.stop()
            Task {
                var text = ""
                if samples.count > 4000, let t { text = ((try? await t.transcribe(samples)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                // Voice lock: a request (not dictation) must come from the owner's voice.
                if mode == .talk, !text.isEmpty, let self, await !self.voice.isOwner(samples) { await self.notOwner(); return }
                await self?.heard(text, mode: mode, modelReady: t != nil)
            }
        }
    }

    /// Mic button in the command bar: click to start, click again to send.
    func toggleBarMic() {
        if recording == .talk { endVoice(.talk) } else { beginVoice(.talk, target: targetApp) }
    }

    private func pushLevel(_ level: Float) {
        guard recording != nil || pill == .listening else { return }      // push to talk, or waiting for a request after the wake word
        // Loudness in decibels mapped to 0...1 (quiet room about -55 dB, normal speech -35 to -15 dB), with a fast
        // attack and a slower release so the bars jump with each syllable and settle smoothly.
        let db = 20 * log10(max(level, 0.00001))
        let target = min(max((db + 52) / 34, 0), 1)
        let previous = levels.first ?? 0
        let smoothed = target > previous ? previous + (target - previous) * 0.85 : previous + (target - previous) * 0.45
        levels.insert(smoothed, at: 0); levels.removeLast()
    }

    private func abandonRecording() {
        guard recording != nil else { return }
        recording = nil
        let rec = recorder
        audioQ.async { _ = rec.stop() }
    }

    private func voiceFailed(_ why: String) {
        recording = nil
        liveTranscript = why
        setPill(.thinking)
        clearPill(after: 1.6)
    }

    private func heard(_ text: String, mode: VoiceMode, modelReady: Bool) {
        guard !text.isEmpty else {
            if modelReady { setPill(.idle) } else { liveTranscript = "Speech model is still loading"; clearPill(after: 1.6) }
            return
        }
        switch mode {
        case .talk:
            liveTranscript = text
            run(text, app: voiceTarget)
        case .dictate:
            liveTranscript = text
            onReleaseKeyboard?()                                  // make sure our bar is not the key window
            let front = NSWorkspace.shared.frontmostApplication
            guard front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { setPill(.idle); return }   // never into Onboard
            Task.detached {
                // Wait for fn and control to be physically released, so the text is not typed as shortcuts.
                for _ in 0..<25 {
                    let f = await MainActor.run { NSEvent.modifierFlags }
                    if !f.contains(.control) && !f.contains(.function) { break }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
                Screen.type(text + " ")
            }
            finishPill()
        }
    }

    private var voiceWired = false
    private func wireVoice(base: URL?) {
        guard !voiceWired else { return }
        voiceWired = true
        voice.ownerName = { [weak self] in self?.owner ?? "Owner" }
        voice.transcriber = { [weak self] in self?.transcriber }
        voice.accurate = { [weak self] in self?.accurate }
        voice.canListen = { [weak self] in
            guard let self else { return false }
            return self.recording == nil && !self.speakingNow && self.pill != .speaking && !self.agent.running
        }
        voice.onCommand = { [weak self] text in
            guard let self else { return }
            self.liveTranscript = text; self.setPill(.thinking)
            self.run(text, app: Screen.targetApp(excluding: Bundle.main.bundleIdentifier))
        }
        voice.onRejected = { [weak self] in self?.notOwner() }
        voice.isWorking = { [weak self] in (self?.agent.running ?? false) || (self?.speakingNow ?? false) }
        voice.onCancel = { [weak self] in
            guard let self else { return }
            self.stop()
            self.onCancelled?()
            self.liveTranscript = "Cancelled"; self.setPill(.thinking); self.clearPill(after: 1.4)
        }
        voice.onArmed = { [weak self] in
            guard let self else { return }
            self.levels = Array(repeating: 0, count: self.levels.count)
            self.liveTranscript = "Yes?"; self.setPill(.listening); self.clearPill(after: 7)
        }
        voice.onLevel = { [weak self] level in self?.pushLevel(level) }
        Task { await voice.load(downloadBase: base) }
    }

    /// Someone other than the owner tried to give an order.
    private func notOwner() {
        liveTranscript = "Voice not recognized"
        setPill(.thinking)
        clearPill(after: 1.6)
    }

    // MARK: pill

    private func setPill(_ s: PillState) { pillToken += 1; pill = s }

    private func finishPill() {
        setPill(.done)
        clearPill(after: 0.9)
    }

    private func clearPill(after secs: Double) {
        let token = pillToken
        Task {
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            if pillToken == token { pill = .idle; liveTranscript = "" }
        }
    }
}
