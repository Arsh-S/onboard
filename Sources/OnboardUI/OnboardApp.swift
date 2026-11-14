import AppKit
import SwiftUI
import OnboardCore
import OnboardOverlay

public enum OnboardApp {
    @MainActor private static var delegate: AppDelegate?

    /// Starts the menu bar app. Never returns.
    @MainActor public static func run() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.regular)       // Dock icon and menu bar item both
        app.run()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var bar: CommandBarController!
    private var pill: VoicePillController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var speakItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        bar = CommandBarController(model: model)
        pill = VoicePillController(model: model)
        settings = SettingsWindowController(model: model)
        buildStatusItem()

        model.onShowCompact = { [weak self] in self?.bar.showCompact() }
        model.onTurnEnded = { [weak self] in self?.bar.turnEnded() }
        model.onReleaseKeyboard = { [weak self] in self?.bar.releaseKeyboard() }
        model.onNeedSettings = { [weak self] in self?.settings.show() }

        let keys = HotkeyCenter.shared
        keys.onPress = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleBar: self.bar.toggle()
            case .talk: self.model.beginVoice(.talk, target: self.bar.isKey ? self.model.targetApp : nil)
            case .dictate: self.model.beginVoice(.dictate)
            }
        }
        keys.onRelease = { [weak self] action in
            switch action {
            case .toggleBar: break
            case .talk: self?.model.endVoice(.talk)
            case .dictate: self?.model.endVoice(.dictate)
            }
        }
        keys.install()
        model.hotkeyFailures = keys.failed

        model.start()
        pill.show()
        if model.firstLaunch { settings.show() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon opens the Onboard window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show(); return true
    }

    // MARK: menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.toolTip = "Onboard"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Open Onboard", #selector(openBar)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        speakItem = item("Speak Answers", #selector(toggleSpeak))
        menu.addItem(speakItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Onboard", #selector(quit)))
        statusItem.menu = menu
        // The icon shows state at a glance: amber while models load, green when ready, pulsing teal while working, red if Bonsai is unreachable.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusIcon() }
        }
    }

    private var statusTimer: Timer?
    private var lastStatus = ""
    private var pulse = false

    private func refreshStatusIcon() {
        let busy = model.agent.running || model.pill == .listening || model.pill == .thinking || model.pill == .speaking
        let loaded = model.hearing == .ready && model.speaking == .ready
        let state = busy ? "working" : (model.thinking != .ready && loaded) ? "problem" : loaded ? "ready" : "loading"
        pulse.toggle()
        let key = state + (state == "working" ? (pulse ? "1" : "0") : "")
        guard key != lastStatus else { return }
        lastStatus = key
        let color: NSColor = switch state {
            case "working": NSColor(red: 0.18, green: 0.83, blue: 0.75, alpha: pulse ? 1 : 0.45)
            case "ready": NSColor(red: 0.30, green: 0.85, blue: 0.50, alpha: 1)
            case "problem": NSColor(red: 0.94, green: 0.36, blue: 0.33, alpha: 1)
            default: NSColor(red: 0.96, green: 0.68, blue: 0.26, alpha: 1)
        }
        statusItem.button?.image = StatusIcon.make(tint: color)
        statusItem.button?.toolTip = ["working": "Onboard is working", "ready": "Onboard is ready", "problem": "Onboard cannot reach Bonsai (LM Studio)", "loading": "Onboard is loading models"][state]
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) { speakItem.state = model.speakAnswers ? .on : .off }

    @objc private func openBar() { bar.open() }
    @objc private func openSettings() { settings.show() }
    @objc private func toggleSpeak() { model.speakAnswers.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// An accessory app shows no menu bar, but text fields still need these for copy, paste and undo.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Onboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        return main
    }
}
