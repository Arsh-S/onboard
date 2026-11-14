import AppKit
import ApplicationServices

/// One thing on screen the agent can name, point at, or press.
public struct UIElement: Sendable {
    public let id: Int
    public let role: String        // button, field, checkbox, menu, link, text, tab, cell
    public let label: String
    public let value: String
    public let frame: CGRect       // global screen points, origin top-left
}

/// The screen as text: a snapshot of an app's front window read through the accessibility tree.
/// A text-only model can drive a Mac from this, with exact element frames and no screenshots.
public final class ScreenSnapshot: @unchecked Sendable {
    public let app: String
    public let pid: pid_t
    public let window: String
    public let windowFrame: CGRect
    public let elements: [UIElement]
    public let menus: [String]                 // "Insert > Chart > 2D Column"
    public var menuTitleFrames: [String: CGRect] = [:]   // top-level menu titles in the menu bar
    let refs: [Int: AXUIElement]
    let menuRefs: [String: AXUIElement]
    public let secs: Double

    init(app: String, pid: pid_t, window: String, windowFrame: CGRect, elements: [UIElement], menus: [String], refs: [Int: AXUIElement], menuRefs: [String: AXUIElement], secs: Double) {
        self.app = app; self.pid = pid; self.window = window; self.windowFrame = windowFrame; self.elements = elements; self.menus = menus; self.refs = refs; self.menuRefs = menuRefs; self.secs = secs
    }

    /// Compact text for the model: actionable elements with ids, then readable text.
    public func text(maxActions: Int = 70, maxText: Int = 1400) -> String {
        var out = "App: \(app). Window: \"\(window)\".\nThings you can act on:\n"
        let actions = elements.filter { $0.role != "text" }.prefix(maxActions)
        for e in actions {
            out += "[\(e.id)] \(e.role) \"\(e.label.prefix(60))\"" + (e.value.isEmpty ? "" : " = \"\(e.value.prefix(80))\"") + "\n"
        }
        let texts = elements.filter { $0.role == "text" }.map(\.label)
        var t = ""
        for s in texts where t.count < maxText { t += s + "\n" }
        if !t.isEmpty { out += "Text on screen:\n" + t }
        return out
    }

    public func element(_ id: Int) -> UIElement? { elements.first { $0.id == id } }

    /// Changes whenever the window's content changes (used to wait for the screen to settle after an action).
    public var signature: Int {
        var h = Hasher()
        h.combine(window); h.combine(elements.count)
        for e in elements { h.combine(e.role); h.combine(e.label); h.combine(e.value); h.combine(Int(e.frame.minX)); h.combine(Int(e.frame.minY)) }
        return h.finalize()
    }

    /// The same control in a newer snapshot: same role and label, nearest to where it was.
    public func relocate(_ old: UIElement) -> UIElement? {
        let c = elements.filter { $0.id > 0 && $0.role == old.role && $0.label == old.label }
        return c.min { hypot($0.frame.midX - old.frame.midX, $0.frame.midY - old.frame.midY) < hypot($1.frame.midX - old.frame.midX, $1.frame.midY - old.frame.midY) }
    }
}

public enum Screen {
    static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
    static func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    public static var trusted: Bool { AXIsProcessTrusted() }

    public static func runningApp(_ name: String) -> NSRunningApplication? {
        let n = name.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { ($0.localizedName ?? "").lowercased() == n } ?? apps.first { ($0.localizedName ?? "").lowercased().contains(n) }
    }

    /// The app the user was working in (frontmost, ignoring Onboard itself).
    public static func targetApp(excluding bundle: String?) -> NSRunningApplication? {
        if let f = NSWorkspace.shared.frontmostApplication, f.bundleIdentifier != bundle { return f }
        return NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular && $0.bundleIdentifier != bundle && !$0.isHidden }
    }

    static let roleNames: [String: String] = [
        "AXButton": "button", "AXTextField": "field", "AXTextArea": "field", "AXSearchField": "field", "AXComboBox": "field",
        "AXCheckBox": "checkbox", "AXRadioButton": "tab", "AXPopUpButton": "menu", "AXMenuButton": "menu", "AXLink": "link",
        "AXCell": "cell", "AXRow": "row", "AXSlider": "slider", "AXDisclosureTriangle": "button", "AXTab": "tab", "AXStaticText": "text", "AXHeading": "text",
    ]

    /// `menusFrom`: reuse the menu bar from an earlier snapshot of the same app (walking the menus is the slow part).
    public static func snapshot(_ app: NSRunningApplication, limit: Int = 5000, menusFrom old: ScreenSnapshot? = nil) -> ScreenSnapshot? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)
        if app.bundleIdentifier == "com.google.Chrome" { AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        let win: AXUIElement? = (attr(root, kAXFocusedWindowAttribute) as! AXUIElement?) ?? (attr(root, kAXMainWindowAttribute) as! AXUIElement?) ?? (attr(root, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let win else { return nil }
        let wf = frame(win)
        var els: [UIElement] = []; var refs: [Int: AXUIElement] = [:]
        var seenText = Set<String>()
        var queue: [AXUIElement] = [win]; var n = 0, id = 1
        while !queue.isEmpty && n < limit && els.count < 260 {
            let e = queue.removeFirst(); n += 1
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if let kind = roleNames[role] {
                let f = frame(e)
                let title = str(e, kAXTitleAttribute), desc = str(e, kAXDescriptionAttribute), help = str(e, kAXHelpAttribute)
                let rawValue = attr(e, kAXValueAttribute)
                let value = (rawValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (rawValue as? NSNumber).map { "\($0)" } ?? ""
                if kind == "text" {
                    let t = !value.isEmpty ? value : title
                    if t.count > 1, t.count < 500, !seenText.contains(t) { seenText.insert(t); els.append(UIElement(id: 0, role: "text", label: t, value: "", frame: f)) }
                } else if f.width > 3, f.height > 3, wf.insetBy(dx: -40, dy: -40).intersects(f) {
                    var label = !title.isEmpty ? title : !desc.isEmpty ? desc : help
                    if label.isEmpty, kind == "field" { label = str(e, kAXPlaceholderValueAttribute) }
                    if label.isEmpty, kind == "cell" || kind == "row" { label = value }
                    if !(label.isEmpty && value.isEmpty) && !(kind == "row") {
                        els.append(UIElement(id: id, role: kind, label: label.isEmpty ? "(unnamed \(kind))" : label, value: kind == "field" || kind == "checkbox" || kind == "menu" || kind == "slider" ? String(value.prefix(120)) : "", frame: f))
                        refs[id] = e; id += 1
                    }
                }
            }
            queue += (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        // Menu bar: every enabled item as a path. Menus are the most reliable way to drive a Mac app.
        var menus: [String] = []; var menuRefs: [String: AXUIElement] = [:]; var titleFrames: [String: CGRect] = [:]
        if let old, old.pid == app.processIdentifier, !old.menus.isEmpty {
            menus = old.menus; menuRefs = old.menuRefs; titleFrames = old.menuTitleFrames
        } else if let bar = attr(root, kAXMenuBarAttribute) {
            func walk(_ e: AXUIElement, _ path: [String], _ depth: Int) {
                guard depth < 5, menus.count < 700 else { return }
                for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    let role = attr(c, kAXRoleAttribute) as? String ?? ""
                    let title = str(c, kAXTitleAttribute)
                    if role == "AXMenu" { walk(c, path, depth); continue }
                    guard !title.isEmpty, title != "Apple" else { continue }
                    let p = path + [title]
                    if depth == 0 { titleFrames[title] = frame(c) }
                    let kids = (attr(c, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                    if kids.isEmpty {
                        if (attr(c, kAXEnabledAttribute) as? Bool) != false, p.count > 1 { let key = p.joined(separator: " > "); menus.append(key); menuRefs[key] = c }
                    } else { walk(c, p, depth + 1) }
                }
            }
            walk(bar as! AXUIElement, [], 0)
        }
        let snap = ScreenSnapshot(app: app.localizedName ?? "", pid: app.processIdentifier, window: str(win, kAXTitleAttribute), windowFrame: wf,
                                  elements: els, menus: menus, refs: refs, menuRefs: menuRefs, secs: CFAbsoluteTimeGetCurrent() - t0)
        snap.menuTitleFrames = titleFrames
        return snap
    }

    // MARK: actions

    @discardableResult public static func press(_ snap: ScreenSnapshot, id: Int) -> Bool {
        guard let e = snap.refs[id] else { return false }
        if AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return true }
        // Some controls only respond to a real click.
        if let el = snap.element(id) { click(at: CGPoint(x: el.frame.midX, y: el.frame.midY)); return true }
        return false
    }

    public static func focus(_ snap: ScreenSnapshot, id: Int) -> Bool {
        guard let e = snap.refs[id] else { return false }
        return AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Set a field's text directly (falls back to focusing so typing can follow).
    public static func setValue(_ snap: ScreenSnapshot, id: Int, text: String) -> Bool {
        guard let e = snap.refs[id] else { return false }
        return AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, text as CFString) == .success
    }

    /// Insert text at the end of a text field or document without stealing focus (false if the control does not support it).
    public static func insertAtEnd(_ snap: ScreenSnapshot, id: Int, text: String) -> Bool {
        guard let e = snap.refs[id] else { return false }
        let current = (attr(e, kAXValueAttribute) as? String) ?? ""
        var range = CFRange(location: (current as NSString).length, length: 0)
        guard let rv = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, rv) == .success else { return false }
        let lead = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        return AXUIElementSetAttributeValue(e, kAXSelectedTextAttribute as CFString, (lead + text) as CFString) == .success
    }

    /// Menu commands whose path shares a word with the request (shown to the model as hints).
    public static func menuHints(_ snap: ScreenSnapshot, for request: String, max: Int = 14) -> [String] {
        let stop: Set<String> = ["the", "and", "how", "make", "this", "that", "with", "for", "can", "you", "text", "please", "into", "from", "what", "where"]
        let words = Set(request.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 && !stop.contains($0) })
        guard !words.isEmpty else { return [] }
        let scored = snap.menus.compactMap { m -> (String, Int)? in
            let l = m.lowercased(); let n = words.filter { w in l.contains(w) || l.contains(String(w.prefix(Swift.max(4, w.count - 2)))) }.count
            return n > 0 ? (m, n) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(max).map(\.0)
    }

    /// Everything readable in the app's front window right now (full text of fields and documents, not the trimmed
    /// version the model sees). Used to check that an action really had its effect.
    public static func visibleText(_ app: NSRunningApplication, limit: Int = 3000) -> String {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = (attr(root, kAXFocusedWindowAttribute) as! AXUIElement?) ?? (attr(root, kAXWindowsAttribute) as? [AXUIElement])?.first else { return "" }
        var out = ""; var queue = [win]; var n = 0
        while !queue.isEmpty && n < limit {
            let e = queue.removeFirst(); n += 1
            if let v = attr(e, kAXValueAttribute) as? String, !v.isEmpty { out += v + "\n" }
            queue += (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return out
    }

    /// Best menu item for a phrase: exact leaf match, then all-words match on the path.
    public static func findMenu(_ snap: ScreenSnapshot, _ phrase: String) -> String? {
        let p = phrase.lowercased().replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
        func leaf(_ m: String) -> String { (m.components(separatedBy: " > ").last ?? m).lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "") }
        if let m = snap.menus.first(where: { $0.lowercased() == p }) { return m }
        if let m = snap.menus.first(where: { leaf($0) == p }) { return m }
        // A loose match must be on the command's own name and nearly the same length: "Terminal" must never pick
        // "Make this the Default Terminal". Otherwise return nothing and let the model see the real choices.
        let words = p.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        guard words.count >= 2 else { return nil }
        let scored = snap.menus.compactMap { m -> (String, Int)? in
            let l = leaf(m); let lw = l.split { !$0.isLetter && !$0.isNumber }.count
            return words.allSatisfy { l.contains($0) } && lw <= words.count + 1 ? (m, l.count) : nil
        }
        return scored.min { $0.1 < $1.1 }?.0
    }

    /// Role of the control that currently has keyboard focus in an app ("AXTextField", "AXTextArea", ...).
    public static func focusedRole(_ app: NSRunningApplication) -> String {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let f = attr(root, kAXFocusedUIElementAttribute) else { return "" }
        return attr(f as! AXUIElement, kAXRoleAttribute) as? String ?? ""
    }

    @discardableResult public static func pressMenu(_ snap: ScreenSnapshot, path: String) -> Bool {
        guard let e = snap.menuRefs[path] else { return false }
        return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }

    public static func click(at p: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        let saved = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        // Give the user's pointer back where it was: the agent has its own cursor.
        if let s = saved { usleep(30_000); CGWarpMouseCursorPosition(s) }
    }

    /// Type text into the frontmost app with synthetic key events (only call when the target app is in front).
    public static func type(_ s: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in s.utf16 {
            var c = ch
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true), u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); u?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            d?.flags = []; u?.flags = []      // never inherit held modifiers (fn or control still down would turn text into shortcuts)
            d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
            usleep(9_000)
        }
    }

    public static func key(_ code: CGKeyCode, command: Bool = false, shift: Bool = false) {
        let src = CGEventSource(stateID: .hidSystemState)
        let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true), u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        var f: CGEventFlags = []; if command { f.insert(.maskCommand) }; if shift { f.insert(.maskShift) }
        d?.flags = f; u?.flags = f
        d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
    }

    /// When false, nothing is ever brought to the front (headless tests, and the "work in the background" mode).
    nonisolated(unsafe) public static var allowForeground = true

    /// The text control to type into when the model named none: the app's focused element, else its largest field.
    public static func defaultField(_ snap: ScreenSnapshot) -> Int? {
        let app = AXUIElementCreateApplication(snap.pid)
        if let f = attr(app, kAXFocusedUIElementAttribute) {
            let fe = f as! AXUIElement
            if let hit = snap.refs.first(where: { CFEqual($0.value, fe) }), snap.element(hit.key)?.role == "field" { return hit.key }
        }
        return snap.elements.filter { $0.role == "field" }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.id
    }

    public static func bringForward(_ app: NSRunningApplication) async -> Bool {
        guard allowForeground else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        for i in 0..<25 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            // The accessibility route works even when the caller is not the active app.
            if i % 2 == 0 { AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue) } else { app.activate() }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    static let appAliases: [String: String] = [
        "imessage": "Messages", "imessages": "Messages", "message": "Messages", "texts": "Messages", "text messages": "Messages",
        "chrome": "Google Chrome", "google": "Google Chrome", "vscode": "Visual Studio Code", "vs code": "Visual Studio Code", "code": "Visual Studio Code",
        "settings": "System Settings", "system preferences": "System Settings", "preferences": "System Settings",
        "email": "Mail", "mail app": "Mail", "browser": "Safari", "files": "Finder", "file manager": "Finder",
        "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint", "spreadsheet": "Numbers", "text editor": "TextEdit",
        "app store": "App Store", "facetime": "FaceTime", "music app": "Music", "photos app": "Photos", "terminal app": "Terminal",
    ]
    static let appDirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    /// Installed app names (without .app).
    public static func installedApps() -> [String: String] {
        var out: [String: String] = [:]
        for d in appDirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".app") {
                out[String(f.dropLast(4))] = d + "/" + f
            }
        }
        return out
    }

    /// Find the app someone means: nicknames ("iMessage", "Chrome"), then exact, then closest installed name.
    public static func resolveApp(_ raw: String) -> (name: String, path: String)? {
        var q = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" app", " application", ".app"] where q.hasSuffix(suffix) { q = String(q.dropLast(suffix.count)) }
        if q.hasPrefix("the ") { q = String(q.dropFirst(4)) }
        let apps = installedApps()
        let wanted = (appAliases[q] ?? q).lowercased()
        if let hit = apps.first(where: { $0.key.lowercased() == wanted }) { return (hit.key, hit.value) }
        let near = apps.filter { $0.key.lowercased().hasPrefix(wanted) || $0.key.lowercased().contains(wanted) || wanted.contains($0.key.lowercased()) }
        return near.min { abs($0.key.count - wanted.count) < abs($1.key.count - wanted.count) }.map { ($0.key, $0.value) }
    }

    public static func similarApps(_ raw: String) -> [String] {
        let q = raw.lowercased().prefix(3)
        return installedApps().keys.filter { $0.lowercased().contains(q) }.sorted().prefix(6).map { $0 }
    }

    @discardableResult public static func open(_ name: String) async -> NSRunningApplication? {
        guard let app = resolveApp(name) else { return nil }
        if let a = runningApp(app.name) { _ = await bringForward(a); return a }
        _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
        for _ in 0..<30 { if let a = runningApp(app.name), Screen.snapshot(a) != nil { return a }; try? await Task.sleep(nanoseconds: 150_000_000) }
        return runningApp(app.name)
    }
}
