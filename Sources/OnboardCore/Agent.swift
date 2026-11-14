import AppKit
import Foundation
import Observation

/// One step the agent took (shown live, and drawn on screen by the overlay).
public struct AgentStep: Identifiable, Sendable {
    public let id = UUID()
    public var action: String
    public var detail: String
    public var say: String
    public var result: String = ""
    public var secs: Double = 0
    public var done = false
    public var point: CGPoint?
    public var frame: CGRect?
    public var source: String?      // memory: file the answer came from
}

/// What the overlay should draw; the app supplies these so the core stays UI free.
@MainActor public protocol AgentStage: AnyObject {
    func scan(window: CGRect, elements: [UIElement]) async      // shimmer + x-ray pass
    func glide(to: CGPoint, frame: CGRect?, thought: String) async
    func click(at: CGPoint) async
    func thought(_ text: String)
    func speak(_ text: String) async
    func approve(_ question: String, detail: String) async -> Bool
    func rest()
}

/// The agent: each step it re-reads the screen as text, Bonsai picks one action (constrained JSON), Onboard performs it
/// with its own cursor. Fresh grounding every step means the small model never has to remember a long conversation.
@MainActor @Observable
public final class Agent {
    public private(set) var steps: [AgentStep] = []
    public private(set) var answer = ""
    public private(set) var running = false
    public private(set) var request = ""
    public private(set) var lastSnapshot: ScreenSnapshot?
    public private(set) var turnSecs = 0.0
    public var owner = "you"
    public let bonsai: Bonsai
    public let memory: MemoryIndex
    public weak var stage: AgentStage?
    public var ownBundle: String? = Bundle.main.bundleIdentifier
    public var maxSteps = 8
    private var cancelled = false
    private var target: NSRunningApplication?

    public init(bonsai: Bonsai, memory: MemoryIndex) { self.bonsai = bonsai; self.memory = memory }

    public func cancel() { cancelled = true }

    static let actions = ["answer", "point", "click", "type", "menu", "key", "open_app", "search_memory", "add_reminder", "add_event", "draft_email"]

    var system: String {
        """
        You are Onboard, an assistant that lives on \(owner)'s Mac and works with no internet. You see the screen as text and act with your own cursor.
        Now: \(Date().formatted(date: .complete, time: .shortened)).
        Each step choose ONE action. Fields: action, target (an element number from the screen, or 0), text, say.
        - answer: finish. say = your spoken reply to \(owner), one or two short sentences.
        - point: show \(owner) where something is. target = element number. say = what to do there. Use for "how do I" and "where is" questions.
        - click: press an element. target = element number.
        - type: type text into a field. target = field number, text = what to type.
        - menu: choose a menu bar command. text = the command name, for example "New Note" or "Chart".
        - key: press a key. text = one of: return, tab, escape, save, select all, copy, paste, undo, new.
        - open_app: text = app name.
        - search_memory: search \(owner)'s notes, manuals and files on this Mac. text = search words. Use before answering questions about facts, procedures or past notes.
        - add_reminder: text = title | when.   - add_event: text = title | when.
        - draft_email: text = recipient | subject | body. Opens a draft; \(owner) sends it.
        say = a few words narrating this step, in plain speech (for answer and point it is the full reply).
        Rules: only use element numbers that appear on the screen. Never invent facts: search memory or read the screen. Prefer menu over hunting for buttons. When the request is done, answer.
        Examples:
        Request: how do I make this bold? -> if a Bold button is on screen, point at its number; if it is only a menu command: {"action":"answer","target":0,"text":"","say":"Use the Format menu, then Font, then Bold."}
        Request: make a new note that says hello -> {"action":"menu","target":0,"text":"New Note","say":"Starting a new note."} then {"action":"type","target":0,"text":"hello","say":"Typing it in."} then {"action":"answer","target":0,"text":"","say":"Done, your note says hello."}
        Request: what does the manual say about filter changes? -> {"action":"search_memory","target":0,"text":"filter change procedure","say":"Checking the manual."}
        Answer only in JSON.
        """
    }

    func history() -> String {
        steps.isEmpty ? "(none)" : steps.map { "- \($0.action)(\($0.detail.prefix(80))) -> \($0.result.prefix(500))" }.joined(separator: "\n")
    }

    public func run(_ text: String, app: NSRunningApplication? = nil) async {
        let req = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty, !running else { return }
        running = true; cancelled = false; request = req; steps = []; answer = ""
        let t0 = now()
        defer { running = false; turnSecs = now() - t0; stage?.rest() }
        target = app ?? Screen.targetApp(excluding: ownBundle)
        var first = true
        for _ in 0..<maxSteps {
            if cancelled { answer = "Stopped."; return }
            // Fresh look at the screen every step.
            var snap: ScreenSnapshot?
            if let t = target { snap = Screen.snapshot(t); lastSnapshot = snap }
            if first, let s = snap { await stage?.scan(window: s.windowFrame, elements: s.elements.filter { $0.role != "text" }); first = false }
            let screen = snap?.text() ?? "(no app window is open)"
            // The model may only name elements that are really on screen.
            let ids = [0] + (snap?.elements.filter { $0.id > 0 }.map(\.id) ?? [])
            let schema: [String: Any] = [
                "type": "object",
                "properties": ["action": ["type": "string", "enum": Self.actions], "target": ["type": "integer", "enum": ids], "text": ["type": "string"], "say": ["type": "string"]],
                "required": ["action", "target", "text", "say"], "additionalProperties": false,
            ]
            let hints = snap.map { Screen.menuHints($0, for: req) } ?? []
            let user = "Screen right now:\n\(screen)\nMenu commands that may help: \(hints.isEmpty ? "(none match)" : hints.joined(separator: "; "))\n\nRequest from \(owner): \(req)\n\nSteps so far:\n\(history())\n\nNext step. JSON: action, target, text, say."
            guard let r = try? await bonsai.json(system: system, user: user, schema: schema, maxTokens: 170) else {
                answer = "I can't reach Bonsai. Is LM Studio running?"; await stage?.speak(answer); return
            }
            let action = r.json["action"] as? String ?? "answer"
            let tid = r.json["target"] as? Int ?? 0
            let txt = (r.json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let say = (r.json["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if action == "answer" {
                answer = say.isEmpty ? (txt.isEmpty ? "Done." : txt) : say
                await stage?.speak(answer); return
            }
            // The same step twice means it is stuck: summarize and stop.
            if let last = steps.last, last.action == action, last.detail == (tid > 0 ? "#\(tid) \(txt)" : txt) { break }
            var step = AgentStep(action: action, detail: tid > 0 ? "#\(tid) \(txt)" : txt, say: say, secs: r.secs)
            if let el = snap?.element(tid) { step.frame = el.frame; step.point = CGPoint(x: el.frame.midX, y: el.frame.midY) }
            steps.append(step)
            let tA = now()
            let (result, finish) = await perform(action, tid, txt, say, snap, &step)
            step.result = result; step.secs += now() - tA; step.done = true
            steps[steps.count - 1] = step
            if finish { return }
        }
        await summarize(req)
    }

    func summarize(_ req: String) async {
        let schema: [String: Any] = ["type": "object", "properties": ["say": ["type": "string"]], "required": ["say"], "additionalProperties": false]
        let r = try? await bonsai.json(system: "You are Onboard, \(owner)'s assistant. Answer only in JSON.",
                                       user: "Request: \(req)\nWhat you did and found (this really happened):\n\(history())\n\nTell \(owner) the result in one or two short spoken sentences, using only what is above. JSON: say.", schema: schema, maxTokens: 100)
        answer = (r?.json["say"] as? String) ?? "Done."
        await stage?.speak(answer)
    }

    static let keys: [String: (CGKeyCode, Bool)] = ["return": (36, false), "enter": (36, false), "tab": (48, false), "escape": (53, false), "save": (1, true),
                                                    "select all": (0, true), "copy": (8, true), "paste": (9, true), "undo": (6, true), "new": (45, true)]

    /// Returns (result text for the model, whether the request is finished).
    func perform(_ action: String, _ tid: Int, _ text: String, _ say: String, _ snap: ScreenSnapshot?, _ step: inout AgentStep) async -> (String, Bool) {
        switch action {
        case "point":
            guard let el = snap?.element(tid) else { return ("There is no element \(tid) on screen", false) }
            await stage?.glide(to: CGPoint(x: el.frame.midX, y: el.frame.midY), frame: el.frame, thought: el.label)
            answer = say.isEmpty ? "It's right here: \(el.label)." : say
            await stage?.speak(answer)
            return ("Pointed at \(el.label)", true)
        case "click":
            guard let snap, let el = snap.element(tid) else { return ("There is no element \(tid) on screen", false) }
            let p = CGPoint(x: el.frame.midX, y: el.frame.midY)
            await stage?.glide(to: p, frame: el.frame, thought: say.isEmpty ? "Clicking \(el.label)" : say)
            await stage?.click(at: p)
            let ok = Screen.press(snap, id: tid)
            try? await Task.sleep(nanoseconds: 450_000_000)
            return (ok ? "Clicked \(el.label)" : "Could not click \(el.label)", false)
        case "type":
            guard let app = target else { return ("No app to type into", false) }
            if let snap, let el = snap.element(tid), el.role == "field" {
                let p = CGPoint(x: el.frame.midX, y: el.frame.midY)
                await stage?.glide(to: p, frame: el.frame, thought: say.isEmpty ? "Typing" : say)
                await stage?.click(at: p)
                _ = Screen.focus(snap, id: tid)
                // Empty one-line fields are set directly; anything with content gets the text added at the end.
                if el.value.isEmpty, Screen.setValue(snap, id: tid, text: text) { return ("Typed \"\(text.prefix(60))\" into \(el.label)", false) }
                if Screen.insertAtEnd(snap, id: tid, text: text) { return ("Added \"\(text.prefix(60))\" at the end of \(el.label)", false) }
            } else {
                stage?.thought(say.isEmpty ? "Typing" : say)
                // No field named: use the focused or main text area, still without stealing focus.
                if let snap, let fid = Screen.defaultField(snap), let el = snap.element(fid) {
                    step.frame = el.frame; step.point = CGPoint(x: el.frame.midX, y: el.frame.midY)
                    await stage?.glide(to: step.point!, frame: el.frame, thought: say.isEmpty ? "Typing" : say)
                    if Screen.insertAtEnd(snap, id: fid, text: text) { return ("Added \"\(text.prefix(60))\" to \(el.label)", false) }
                }
            }
            guard await Screen.bringForward(app) else { return ("Could not bring \(app.localizedName ?? "the app") forward", false) }
            Screen.type(text)
            try? await Task.sleep(nanoseconds: 250_000_000)
            return ("Typed \"\(text.prefix(60))\"", false)
        case "menu":
            guard let snap else { return ("No app is open", false) }
            guard let path = Screen.findMenu(snap, text) else {
                let near = snap.menus.filter { m in text.lowercased().split(separator: " ").contains { m.lowercased().contains($0) } }.prefix(8)
                return ("No menu command named \"\(text)\". Similar: \(near.joined(separator: "; "))", false)
            }
            step.detail = path
            let barPoint = CGPoint(x: snap.windowFrame.minX + 160, y: 12)
            await stage?.glide(to: barPoint, frame: nil, thought: say.isEmpty ? path : say)
            await stage?.click(at: barPoint)
            let ok = Screen.pressMenu(snap, path: path)
            try? await Task.sleep(nanoseconds: 600_000_000)
            return (ok ? "Chose \(path)" : "Could not choose \(path)", false)
        case "key":
            guard let app = target, let k = Self.keys[text.lowercased()] else { return ("Unknown key \(text)", false) }
            stage?.thought(say.isEmpty ? "Pressing \(text)" : say)
            guard await Screen.bringForward(app) else { return ("Could not bring the app forward", false) }
            Screen.key(k.0, command: k.1)
            try? await Task.sleep(nanoseconds: 350_000_000)
            return ("Pressed \(text)", false)
        case "open_app":
            stage?.thought(say.isEmpty ? "Opening \(text)" : say)
            guard let a = await Screen.open(text) else { return ("There is no app named \(text)", false) }
            target = a
            return ("\(a.localizedName ?? text) is open and in front", false)
        case "search_memory":
            stage?.thought(say.isEmpty ? "Searching memory" : say)
            let hits = await memory.search(text, k: 3)
            guard let top = hits.first else { return ("Nothing in memory about that", false) }
            step.source = top.chunk.source
            return (hits.map { "[\($0.chunk.title)] \($0.chunk.text.prefix(380))" }.joined(separator: "\n"), false)
        case "add_reminder":
            let p = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            stage?.thought(say.isEmpty ? "Adding a reminder" : say)
            let r = await Tools.addReminder(p.first ?? text, when: p.count > 1 ? p[1] : "")
            await summarizeAfter(r); return (r, true)
        case "add_event":
            let p = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            stage?.thought(say.isEmpty ? "Adding to the calendar" : say)
            let r = await Tools.addEvent(p.first ?? text, when: p.count > 1 ? p[1] : "")
            await summarizeAfter(r); return (r, true)
        case "draft_email":
            let p = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let ok = await stage?.approve("Open this email draft?", detail: "To: \(p.first ?? "")\n\(p.count > 1 ? p[1] : "")\n\n\(p.count > 2 ? p[2] : "")") ?? true
            guard ok else { answer = "Okay, I left it."; await stage?.speak(answer); return ("Not approved", true) }
            let r = Tools.draftEmail(to: p.first ?? "", subject: p.count > 1 ? p[1] : "", body: p.count > 2 ? p.dropFirst(2).joined(separator: " | ") : "")
            await summarizeAfter(r); return (r, true)
        default:
            return ("Unknown action \(action)", false)
        }
    }

    func summarizeAfter(_ result: String) async {
        steps[steps.count - 1].result = result; steps[steps.count - 1].done = true
        answer = result.hasSuffix(".") ? result : result + "."
        await stage?.speak(answer)
    }
}
