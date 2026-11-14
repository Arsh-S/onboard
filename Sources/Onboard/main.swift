// Onboard: the app by default; `Onboard snap <app>` and `Onboard ask "<request>" [--app Name]` for headless checks.
import AppKit
import Foundation
import OnboardCore
import OnboardOverlay
import OnboardUI

let args = CommandLine.arguments
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let supportDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Onboard")

if args.count > 2, args[1] == "snap" {
    print("accessibility trusted:", Screen.trusted)
    if let a = Screen.runningApp(args[2]), let s = Screen.snapshot(a) {
        print(s.text()); print(String(format: "elements %d, menus %d, %.0f ms", s.elements.count, s.menus.count, s.secs * 1000))
        if let q = opt("--menu") { print("menu match:", Screen.findMenu(s, q) ?? "none") }
    } else { print("no window for \(args[2])") }
    exit(0)
} else if args.count > 2, args[1] == "ask" {
    Task { @MainActor in
        let mem = MemoryIndex(folders: [supportDir.appendingPathComponent("memory")], store: supportDir.appendingPathComponent("memory_index.json"))
        await mem.refresh()
        Screen.allowForeground = args.contains("--foreground")   // headless checks never touch what is on screen
        let agent = Agent(bonsai: Bonsai(), memory: mem)
        agent.owner = "Arsh"
        let app = opt("--app").flatMap { Screen.runningApp($0) }
        let t = CFAbsoluteTimeGetCurrent()
        await agent.run(args[2], app: app)
        for s in agent.steps { print(String(format: "  %@(%@)  %.2fs  say: %@\n     -> %@", s.action, s.detail, s.secs, s.say, String(s.result.prefix(140)).replacingOccurrences(of: "\n", with: " "))) }
        print(String(format: "ANSWER (%.1fs): %@", CFAbsoluteTimeGetCurrent() - t, agent.answer))
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
