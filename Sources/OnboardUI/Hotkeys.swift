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
        HotkeySpec(action: .talk, keyCode: kVK_Space, modifiers: controlKey | optionKey,
                   keys: ["⌃", "⌥", "Space"], title: "Hold to talk", hint: "Release and Onboard gets to work"),
        HotkeySpec(action: .dictate, keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey,
                   keys: ["⌃", "⌥", "D"], title: "Hold to dictate", hint: "Types what you say into your app"),
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
        for s in Hotkeys.all {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(s.keyCode), UInt32(s.modifiers),
                                             EventHotKeyID(signature: OSType(0x4F4E4244), id: s.action.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { failed.insert(s.action.rawValue) }
            refs.append(ref)
        }
    }

    private func dispatch(_ id: UInt32, pressed: Bool) {
        guard let a = HotkeyAction(rawValue: id) else { return }
        if pressed { onPress?(a) } else { onRelease?(a) }
    }
}
