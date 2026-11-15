// Onboard: the app by default; `Onboard snap <app>` and `Onboard ask "<request>" [--app Name]` for headless checks.
import AppKit
import Foundation
import OnboardCore
import OnboardOverlay
import OnboardUI

let args = CommandLine.arguments
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
_ = NSApplication.shared   // window server connection (needed for pictures of windows)
let supportDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Onboard")

if args.count > 2, args[1] == "snap" {
    print("accessibility trusted:", Screen.trusted)
    if let a = Screen.runningApp(args[2]), let s = Screen.snapshot(a) {
        print(s.text()); print(String(format: "elements %d, menus %d, %.0f ms", s.elements.count, s.menus.count, s.secs * 1000))
        if let q = opt("--menu") { print("menu match:", Screen.findMenu(s, q) ?? "none") }
    } else { print("no window for \(args[2])") }
    exit(0)
} else if args.count > 2, args[1] == "see" {
    // What the eyes get from an app's window: recognized text, and Bonsai's answer to a question about the picture.
    Task { @MainActor in
        guard let a = Screen.runningApp(args[2]), let s = Screen.snapshot(a) else { print("no window for \(args[2])"); exit(1) }
        print("screen recording permitted:", Eyes.permitted)
        var t = CFAbsoluteTimeGetCurrent()
        guard let img = await Eyes.capture(pid: s.pid, windowFrame: s.windowFrame) else { print("no picture"); exit(1) }
        print(String(format: "picture %dx%d, %.0f ms", img.width, img.height, (CFAbsoluteTimeGetCurrent() - t) * 1000)); t = CFAbsoluteTimeGetCurrent()
        let lines = Eyes.readText(img, windowFrame: s.windowFrame)
        print(String(format: "text: %d lines, %.0f ms", lines.count, (CFAbsoluteTimeGetCurrent() - t) * 1000))
        t = CFAbsoluteTimeGetCurrent(); _ = Eyes.readText(img, windowFrame: s.windowFrame)
        print(String(format: "text again (warm): %.0f ms", (CFAbsoluteTimeGetCurrent() - t) * 1000))
        for l in lines.prefix(25) { print(String(format: "  (%.0f,%.0f) %@", l.frame.midX, l.frame.midY, l.text)) }
        if let out = opt("--save"), let d = Eyes.jpeg(img) { try? d.write(to: URL(fileURLWithPath: out)) }
        if let q = opt("--ask"), let d = Eyes.jpeg(img) {
            let r = try? await Bonsai().json(system: "You look at a picture of a Mac window and answer briefly. JSON only.", user: q, schemaJSON: "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}", maxTokens: 120, image: d)
            print(String(format: "bonsai (%.1fs, %d prompt tok): %@", r?.secs ?? 0, r?.promptTokens ?? 0, (r?.json["answer"] as? String) ?? "(no answer)"))
        }
        exit(0)
    }
    dispatchMain()
} else if args.count > 2, args[1] == "voicetest" {
    // Replays a wav through the voice-training path (speech detection, noise check, add sample) with timings.
    Task {
        do {
            let base = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Tableside/huggingface")
            let audio = try loadAudio16k(URL(fileURLWithPath: args[2]))
            var t0 = Date()
            let tr = try await Transcriber(downloadBase: base); print(String(format: "whisper loaded %.1fs", Date().timeIntervalSince(t0))); t0 = Date()
            let sk = try await SpeakerKitLoader.load(downloadBase: base); print(String(format: "speakerkit loaded %.1fs", Date().timeIntervalSince(t0)))
            let spk = SpeakerIdentifier(sk: sk, storeURL: URL(fileURLWithPath: NSTemporaryDirectory() + "voicetest_\(getpid()).json"))
            let vad = EnergyVAD(threshold: Float(opt("--threshold") ?? "") ?? 0.006); vad.minUtterance = 0.3
            var clips: [EnergyVAD.Utterance] = []
            var i = 0
            while i < audio.count { clips += vad.feed(Array(audio[i..<min(i + 8000, audio.count)])); i += 8000 }
            clips += vad.feed([Float](repeating: 0, count: 16000))
            print(String(format: "%.1fs of audio, %d clips detected", Double(audio.count) / 16000, clips.count))
            if let first = clips.first, let n = Int(opt("--short") ?? "") {     // also try the first n tenths of a second on its own (a single word)
                var short = first; short.audio = Array(first.audio.prefix(n * 1600)); short.start = 0; short.end = Double(n) / 10
                clips.insert(short, at: 0)
            }
            for u in clips {
                t0 = Date()
                let text = (try? await tr.transcribe(u.audio)) ?? "<transcribe failed>"
                let t1 = Date().timeIntervalSince(t0); t0 = Date()
                do { try await spk.addSample(name: "Test", audio: u.audio); print(String(format: "clip %.1fs: transcribe %.1fs, add sample %.1fs, text: %@", u.duration, t1, Date().timeIntervalSince(t0), text)) }
                catch { print(String(format: "clip %.1fs: transcribe %.1fs, add sample FAILED after %.1fs (%@), text: %@", u.duration, t1, Date().timeIntervalSince(t0), "\(error)", text)) }
            }
        } catch { print("voicetest failed: \(error)") }
        exit(0)
    }
    dispatchMain()
} else if args.count > 2, args[1] == "mem" {
    Task { @MainActor in
        let mem = MemoryIndex(folders: [supportDir.appendingPathComponent("memory")], store: supportDir.appendingPathComponent("memory_index.json"))
        await mem.refresh()
        print("chunks \(mem.count) files \(mem.fileCount)")
        for h in await mem.search(args[2], k: 5) { print(String(format: "%.3f [%@] %@", h.score, h.chunk.title, String(h.chunk.text.prefix(150)).replacingOccurrences(of: "\n", with: " "))) }
        exit(0)
    }
    dispatchMain()
} else if args.count > 2, args[1] == "ask" {
    Task { @MainActor in
        let mem = MemoryIndex(folders: [supportDir.appendingPathComponent("memory")], store: supportDir.appendingPathComponent("memory_index.json"))
        await mem.refresh()
        Screen.allowForeground = args.contains("--foreground")
        Tools.dryRun = !args.contains("--live")   // headless checks never touch what is on screen
        let agent = Agent(bonsai: Bonsai(), memory: mem)
        agent.owner = "Arsh"
        let app = opt("--app").flatMap { Screen.runningApp($0) }
        if let a = app, let phrase = opt("--select") { print("selected:", Screen.select(a, phrase: phrase)) }
        let t = CFAbsoluteTimeGetCurrent()
        await agent.run(args[2], app: app)
        for s in agent.steps { print(String(format: "  %@(%@)  %.2fs  say: %@\n     -> %@", s.action, s.detail, s.secs, s.say, String(s.result.prefix(140)).replacingOccurrences(of: "\n", with: " "))) }
        print(String(format: "ANSWER (%.1fs, prompt %d tok): %@", CFAbsoluteTimeGetCurrent() - t, agent.promptTokens, agent.answer))
        exit(0)
    }
    dispatchMain()
} else if args.count > 2, args[1] == "render" {
    // Offscreen PNGs of every UI state (no window is shown).
    Task { @MainActor in
        let dir = URL(fileURLWithPath: args[2]); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OverlayPreview.render(to: dir); UIPreview.render(to: dir); exit(0)
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated { OnboardApp.run() }
}
