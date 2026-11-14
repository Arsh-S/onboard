import AppKit
import SwiftUI
import OnboardOverlay

/// Offscreen PNGs of every UI state, built from fake data. Nothing is shown on screen.
public enum UIPreview {
    @MainActor public static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let footer = FooterData(online: false, bonsaiReady: true, tokPerSec: 47, replySecs: nil, cloudBytes: 0)
        let done = FooterData(online: false, bonsaiReady: true, tokPerSec: 52, replySecs: 3.4, cloudBytes: 0)

        save(bar(BarData(footer: footer), text: ""), "ui_bar_empty", dir)
        save(bar(BarData(footer: footer), text: "Make a chart of the sales by month"), "ui_bar_typing", dir)

        let working = [
            StepData(action: "open_app", title: "Opening Numbers", detail: "Numbers", result: "Opened Numbers", secs: 0.8, done: true),
            StepData(action: "menu", title: "Adding a column chart", detail: "Insert > Chart > 2D Column", result: "Chose 2D Column", secs: 1.4, done: true),
            StepData(action: "type", title: "Naming the chart", detail: "Sales by month", secs: 0.6, done: false),
        ]
        save(bar(BarData(steps: working, request: "Make a chart of the sales by month", running: true, footer: footer), text: ""), "ui_bar_working", dir)
        save(bar(BarData(steps: working, request: "Make a chart of the sales by month", running: true, compact: true, footer: footer), text: ""), "ui_bar_working_compact", dir)

        let finished = [
            StepData(action: "search_memory", title: "Checking your notes", detail: "espresso machine descale", result: "Found in espresso-manual.md", secs: 0.4, done: true,
                     source: "/Users/demo/Library/Application Support/Onboard/memory/espresso-manual.md"),
            StepData(action: "add_reminder", title: "Setting a reminder", detail: "Descale the espresso machine | Saturday 10 am", result: "Reminder added", secs: 0.9, done: true),
        ]
        let reply = "Your manual says to descale every two months with a one to one mix of water and white vinegar. I set a reminder for Saturday at 10."
        save(bar(BarData(steps: finished, answer: reply, request: "How do I descale the espresso machine? Remind me Saturday", footer: done), text: ""), "ui_bar_answer", dir)
        save(bar(BarData(steps: finished, answer: reply, request: "How do I descale the espresso machine? Remind me Saturday", compact: true, footer: done), text: ""), "ui_bar_answer_compact", dir)

        let pills: [(String, PillData)] = [
            ("idle", PillData(state: .idle)),
            ("listening", PillData(state: .listening, levels: [0.22, 0.30, 0.12, 0.26, 0.08])),
            ("thinking", PillData(state: .thinking)),
            ("thinking_text", PillData(state: .thinking, transcript: "Make a chart of the sales by month")),
            ("speaking", PillData(state: .speaking)),
            ("done", PillData(state: .done)),
        ]
        for (name, data) in pills {
            save(VoicePillView(data: data, preview: true).padding(.horizontal, 60).padding(.vertical, 28).frame(width: 440, height: 96).background(backdrop),
                 "ui_pill_\(name)", dir)
        }

        let icon = NSImage(contentsOfFile: FileManager.default.currentDirectoryPath + "/assets/logo/icon_256.png")
        let s = SettingsData(hearing: .ready, thinking: .ready, speaking: .loading, tokPerSec: 47, notes: 12, indexing: false,
                             axTrusted: true, micGranted: false, memoryPath: "~/Library/Application Support/Onboard/memory",
                             speakAnswers: true)
        save(SettingsView(data: s, owner: .constant("Arsh"), icon: icon, preview: true), "ui_settings", dir)
    }

    @MainActor private static var backdrop: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.24), Color(red: 0.09, green: 0.10, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @MainActor private static func bar(_ data: BarData, text: String) -> some View {
        CommandBarView(data: data, text: .constant(text), preview: true)
            .frame(width: data.compact ? CommandBarView.compactWidth : CommandBarView.width)
            .padding(.horizontal, 60).padding(.top, 44).padding(.bottom, 76)
            .background(backdrop)
    }

    @MainActor private static func save<V: View>(_ view: V, _ name: String, _ dir: URL) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        r.scale = 2
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("could not render \(name)"); return
        }
        let url = dir.appendingPathComponent("\(name).png")
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
}
