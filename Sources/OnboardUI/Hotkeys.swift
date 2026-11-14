import AppKit
import Carbon.HIToolbox

enum HotkeyAction: UInt32, CaseIterable { case toggleBar = 1, talk = 2, dictate = 3 }

struct HotkeySpec {
    let action: HotkeyAction
    let keyCode: Int
    let modifiers: Int
    let keys: [String]      // how the combo is shown
    let title: String
    let hint: String
}

/// THE place to change key codes.
enum Hotkeys {
    static let all: [HotkeySpec] = [
        HotkeySpec(action: .toggleBar, keyCode: kVK_Space, modifiers: optionKey,
                   keys: ["⌥", "Space"], title: "Open the command bar", hint: "Type what you want done"),
        // keyCode -1: not a Carbon hotkey. These two are driven by the fn (globe) key, see FnKeyMonitor.
        HotkeySpec(action: .talk, keyCode: -1, modifiers: 0,
                   keys: ["fn"], title: "Hold to talk", hint: "Release and Onboard gets to work"),
        HotkeySpec(action: .dictate, keyCode: -1, modifiers: 0,
                   keys: ["fn", "⌃"], title: "Hold to dictate", hint: "Types what you say into your app"),
    ]
}

/// Global hotkeys through Carbon, with both press and release (needed for push to talk).
@MainActor final class HotkeyCenter {
    static let shared = HotkeyCenter()
    var onPress: ((HotkeyAction) -> Void)?
    var onRelease: ((HotkeyAction) -> Void)?
    private(set) var failed: Set<UInt32> = []
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hk.id
            // Carbon delivers hotkeys on the main thread.
            MainActor.assumeIsolated { HotkeyCenter.shared.dispatch(id, pressed: pressed) }
            return noErr
        }, 2, &specs, nil, nil)
        FnKeyMonitor.shared.start()
        for s in Hotkeys.all where s.keyCode >= 0 {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(s.keyCode), UInt32(s.modifiers),
                                             EventHotKeyID(signature: OSType(0x4F4E4244), id: s.action.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { failed.insert(s.action.rawValue) }
            refs.append(ref)
        }
    }

    fileprivate func fire(_ a: HotkeyAction, pressed: Bool) { if pressed { onPress?(a) } else { onRelease?(a) } }

    private func dispatch(_ id: UInt32, pressed: Bool) {
        guard let a = HotkeyAction(rawValue: id) else { return }
        if pressed { onPress?(a) } else { onRelease?(a) }
    }
}


/// Hold fn to talk to Onboard, hold fn + control to dictate. The fn key is a modifier, so it is
/// watched through flagsChanged events (needs the Accessibility permission the app already has).
/// A short grace period lets control join before dictation starts; any other key press cancels (fn + arrows and so on).
@MainActor final class FnKeyMonitor {
    static let shared = FnKeyMonitor()
    private var active: HotkeyAction?
    private var pending: DispatchWorkItem?
    private var monitors: [Any] = []
    static let grace = 0.14

    func start() {
        guard monitors.isEmpty else { return }
        let flags: (NSEvent) -> Void = { e in MainActor.assumeIsolated { FnKeyMonitor.shared.flagsChanged(e.modifierFlags) } }
        let keys: (NSEvent) -> Void = { _ in MainActor.assumeIsolated { FnKeyMonitor.shared.cancelPending() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in flags(e); return e }) { monitors.append(m) }
    }

    private func cancelPending() { pending?.cancel(); pending = nil }

    private func flagsChanged(_ f: NSEvent.ModifierFlags) {
        let fn = f.contains(.function), ctrl = f.contains(.control)
        let other = f.contains(.command) || f.contains(.option) || f.contains(.shift)
        if let a = active {
            // Either key lifting ends the hold.
            if !fn || (a == .dictate && !ctrl) { active = nil; HotkeyCenter.shared.fire(a, pressed: false) }
            return
        }
        cancelPending()
        guard fn, !other else { return }
        if ctrl { active = .dictate; HotkeyCenter.shared.fire(.dictate, pressed: true); return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active == nil else { return }
                let now = NSEvent.modifierFlags
                guard now.contains(.function) else { return }
                let a: HotkeyAction = now.contains(.control) ? .dictate : .talk
                self.active = a; HotkeyCenter.shared.fire(a, pressed: true)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
    }
}
