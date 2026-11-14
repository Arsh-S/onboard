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
    public private(set) var promptTokens = 0
    /// done, partly or not_done from the last check ("" when nothing needed checking).
    public private(set) var lastVerdict = ""
    public var owner = "you"
    public let bonsai: Bonsai
    public let memory: MemoryIndex
    public weak var stage: AgentStage?
    public var ownBundle: String? = Bundle.main.bundleIdentifier
    public var maxSteps = 12
    /// How many times a failure must be answered with a different attempt before Onboard may say it could not do it.
    public var maxRetries = 3
    private var cancelled = false
    private var target: NSRunningApplication?

    public init(bonsai: Bonsai, memory: MemoryIndex) { self.bonsai = bonsai; self.memory = memory }

    public func cancel() { cancelled = true }

    static let actions = ["answer", "point", "click", "type", "menu", "key", "open_app", "search_memory", "add_reminder", "add_event", "draft_email", "list_apps", "show_menu", "scroll"]

    var system: String {
        """
        You are Onboard, an assistant that lives on \(owner)'s Mac and works with no internet. You see the screen as text and act with your own cursor.
        Each step you output ONE JSON object with these fields, in this order:
        - plan: under 10 words, what this single step does (it is shown to \(owner)).
        - action: one of the actions below.
        - target: an element number from the screen, or 0 when the action needs none.
        - text: the literal content for the action (see each action). Never put explanations in text.

        Actions:
        - answer: finish. text = your spoken reply to \(owner), one or two short sentences.
        - point: show where something is. target = element number, text = what to do there in one sentence. For "how do I" and "where is" questions.
        - click: press an element. target = element number, text = "".
        - type: put words into a document or field. target = the field number (or 0 for the main text area), text = EXACTLY the words to insert, nothing else.
        - menu: choose a menu bar command. text = the command name, for example "New Note" or "Bold".
        - key: text = one of: return, tab, escape, save, select all, copy, paste, undo, new.
        - open_app: text = the app name.
        - search_memory: look in \(owner)'s notes, manuals and files on this Mac. text = search words. Do this before answering questions about facts, procedures, people or past notes.
        - add_reminder: text = title | when        - add_event: text = title | when
        - draft_email: text = recipient | subject | body   (opens a draft; \(owner) sends it)
        - list_apps: see which apps are installed. text = a word to filter by, or "" for all.
        - show_menu: see the commands inside one menu of the app in front. text = the menu name (for example File), or "" to list the menus.
        - scroll: move the page to see more. text = down or up.

        How to work:
        - Take ONE small step at a time: one click, or typing into one field. After every step you get a fresh view of the screen. Look at it before deciding the next step.
        - Never assume a step worked. Read the result and the new screen. If the thing you expected is not there, fix that first.
        - To type somewhere, name the field number as target. Typing clicks that field first.
        - When a list of suggestions or search results appears, click the right one before going on.
        - Never send or submit for \(owner): do not press return in a message or email, and do not click Send. Leave the draft ready and say so.

        Rules:
        - Only use element numbers that appear on the screen.
        - Never invent facts. Use search_memory or what the screen says.
        - Each result line under "Steps so far" is the truth about what happened. Results starting with "Verified" worked. Results starting with "FAILED" did not: try another way or tell \(owner) honestly that it did not work.
        - Never say something was done unless a result shows it. A typed terminal command has not run until you press return and read the result.
        - Do not repeat a step that succeeded.
        - When a step FAILED, do not give up and do not repeat it: try a different way. Look around first if needed (list_apps, show_menu, scroll), pick another element, use a menu command, or open the right app. Only after three different attempts fail may you answer that it did not work, and say what you tried.
        - If the request is a question ("what", "how", "why", "what do I do"), never change anything on screen: find the facts, then answer with them.
        - To run a shell command, first use open_app with "Terminal" (never a browser or a menu guess), then type the command, then key return.
        - In a terminal, type the real shell command, never a description of it. If you are not sure of the exact command, search_memory for it first.
        - Only type, click or add things when \(owner) asked for that.
        - As soon as the request is done, use answer and say what you did or found.

        Examples (request -> one step):
        add a line that says Pump A checked -> {"plan":"Type the line into the document","action":"type","target":0,"text":"Pump A checked"}
        (after that succeeded) -> {"plan":"Report back","action":"answer","target":0,"text":"Done. I added the line Pump A checked."}
        how do I make this bold? -> {"plan":"Use the Bold menu command","action":"answer","target":0,"text":"Open the Format menu, choose Font, then Bold."}
        where is the share button? -> {"plan":"Point at Share","action":"point","target":12,"text":"It's right here, the Share button in the toolbar."}
        what does the manual say about filter changes? -> {"plan":"Check the manual","action":"search_memory","target":0,"text":"filter change procedure"}
        (after the search returned the procedure) -> {"plan":"Tell the steps","action":"answer","target":0,"text":"Swap the filter every 30 days: power down the fan, pull the tray, and seat the new one."}
        open a terminal and flush the DNS cache -> {"plan":"Open the Terminal app","action":"open_app","target":0,"text":"Terminal"}
        (after Terminal is open and in front) -> {"plan":"Type the flush command","action":"type","target":0,"text":"sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"}
        (after the command was typed) -> {"plan":"Run it","action":"key","target":0,"text":"return"}
        (after the terminal showed Password:) -> {"plan":"Report back","action":"answer","target":0,"text":"I ran the flush command. The terminal is asking for your password to finish."}
        text Maya that I'm running late (worked out one step at a time, each after seeing the new screen):
          {"plan":"Open Messages","action":"open_app","target":0,"text":"Messages"}
          then, seeing a compose button [7]: {"plan":"Start a new message","action":"click","target":7,"text":""}
          then, seeing the To field [3]: {"plan":"Enter the recipient","action":"type","target":3,"text":"Maya"}
          then, seeing a suggestion row [12] "Maya Chen": {"plan":"Pick Maya from the suggestions","action":"click","target":12,"text":""}
          then, seeing the message field [9]: {"plan":"Write the message","action":"type","target":9,"text":"I'm running late"}
          then: {"plan":"Report back","action":"answer","target":0,"text":"Your message to Maya is drafted and ready. I did not send it."}
        remind me to call Sam tomorrow at 9 -> {"plan":"Add the reminder","action":"add_reminder","target":0,"text":"Call Sam | tomorrow 9am"}
        Answer only with the JSON object.
        """
    }

    func history() -> String {
        steps.isEmpty ? "(none)" : steps.map { "- \($0.action)(\($0.detail.prefix(80))) -> \($0.result.prefix(1300))" }.joined(separator: "\n")
    }

    public func run(_ text: String, app: NSRunningApplication? = nil) async {
        let req = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty, !running else { return }
        running = true; cancelled = false; request = req; steps = []; answer = ""; lastVerdict = ""
        let t0 = now()
        defer { running = false; turnSecs = now() - t0; stage?.rest(); writeRunLog() }
        target = app ?? Screen.targetApp(excluding: ownBundle)
        var first = true
        var retries = 0
        var nudge = ""
        for _ in 0..<maxSteps {
            if cancelled { answer = "Stopped."; return }
            // Fresh look at the screen every step.
            // Follow the user's screen: if a different app came to the front (opened by a step, or by the user), work there.
            if Screen.allowForeground, let f = Screen.targetApp(excluding: ownBundle), f.processIdentifier != target?.processIdentifier, !steps.isEmpty { target = f }
            var snap: ScreenSnapshot?
            if let t = target { snap = Screen.snapshot(t, menusFrom: lastSnapshot); lastSnapshot = snap }
            if first, let s = snap { await stage?.scan(window: s.windowFrame, elements: s.elements.filter { $0.role != "text" }); first = false }
            let screen = snap?.text() ?? "(no app window is open)"
            // The model may only name elements that are really on screen.
            let ids = [0] + (snap?.elements.filter { $0.id > 0 }.map(\.id) ?? [])
            let actionList = Self.actions.map { "\"\($0)\"" }.joined(separator: ",")
            let schema = "{\"type\":\"object\",\"properties\":{\"plan\":{\"type\":\"string\"},\"action\":{\"type\":\"string\",\"enum\":[\(actionList)]},\"target\":{\"type\":\"integer\",\"enum\":[\(ids.map(String.init).joined(separator: ","))]},\"text\":{\"type\":\"string\"}},\"required\":[\"plan\",\"action\",\"target\",\"text\"],\"additionalProperties\":false}"
            let hints = snap.map { Screen.menuHints($0, for: req) } ?? []
            let user = "Screen right now:\n\(screen)\nMenu commands that may help: \(hints.isEmpty ? "(none match)" : hints.joined(separator: "; "))\n\nRequest from \(owner): \(req)\n\nSteps so far:\n\(history())\(nudge)\n\nNow: \(Date().formatted(date: .complete, time: .shortened)). Next step as JSON (plan, action, target, text)."
            guard let r = try? await bonsai.json(system: system, user: user, schemaJSON: schema, maxTokens: 170) else {
                answer = "I can't reach Bonsai. Is LM Studio running?"; await stage?.speak(answer); return
            }
            let action = r.json["action"] as? String ?? "answer"
            var tid = r.json["target"] as? Int ?? 0
            let txt = (r.json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let say = (r.json["plan"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            promptTokens = r.promptTokens

            let lastFailed = steps.last.map { $0.result.hasPrefix("FAILED") || $0.result.contains("nothing visibly changed") } ?? false
            let detail = tid > 0 ? "#\(tid) \(txt)" : txt
            let repeatsFailure = action != "answer" && steps.contains { $0.action == action && $0.detail == detail && ($0.result.hasPrefix("FAILED") || $0.id == steps.last?.id) }
            // Persistence: after a failure, answering or repeating the same step is not accepted until other ways were tried.
            if (action == "answer" && lastFailed || repeatsFailure) && retries < maxRetries {
                retries += 1
                stage?.thought("That did not work, trying another way")
                nudge = "\n\nIMPORTANT: your last attempt did not work and you may not give up yet (attempt \(retries) of \(maxRetries)). Do something DIFFERENT now: another action, another element, a menu command, or look around with list_apps, show_menu or scroll. Do not answer and do not repeat \(steps.last?.action ?? "the last step")(\(steps.last?.detail.prefix(40) ?? ""))."
                continue
            }
            nudge = ""
            if action == "answer" {
                let proposed = txt.isEmpty ? (say.isEmpty ? "Done." : say) : txt
                answer = await verified(req, proposed: proposed)
                await stage?.speak(answer); return
            }
            // Still repeating after all retries: stop and report honestly.
            if let last = steps.last, last.action == action, last.detail == detail { break }
            if tid > 0, let t = target, let old = snap?.element(tid), let fresh = Screen.snapshot(t, menusFrom: snap) {
                if fresh.signature != snap?.signature, let moved = fresh.relocate(old) { tid = moved.id; snap = fresh; lastSnapshot = fresh }
            }
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
        answer = await verified(req, proposed: (r?.json["say"] as? String) ?? "Done.")
        await stage?.speak(answer)
    }

    /// Every run is written to Application Support/Onboard/runs/last.txt (and a dated copy) so mistakes can be diagnosed.
    func writeRunLog() {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Onboard/runs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out = "Request: \(request)\nApp: \(target?.localizedName ?? "none")\nTime: \(Date())  turn \(String(format: "%.1f", turnSecs))s  verdict: \(lastVerdict)\n\n"
        for (i, s) in steps.enumerated() { out += "\(i + 1). \(s.action)(\(s.detail))  [\(String(format: "%.1f", s.secs))s]  plan: \(s.say)\n   -> \(s.result)\n" }
        out += "\nAnswer: \(answer)\n\nLast screen the model saw:\n\(lastSnapshot?.text() ?? "(none)")\n"
        try? out.write(to: dir.appendingPathComponent("last.txt"), atomically: true, encoding: .utf8)
        let f = DateFormatter(); f.dateFormat = "MMdd_HHmmss"
        try? out.write(to: dir.appendingPathComponent(f.string(from: Date()) + ".txt"), atomically: true, encoding: .utf8)
    }

    static let changing: Set<String> = ["type", "click", "menu", "key", "open_app"]

    /// Check the work before reporting: re-read the screen, compare it with the request and the step results, and let a
    /// strict second pass write the reply. The actor's own "done" is never trusted on its own.
    func verified(_ req: String, proposed: String) async -> String {
        let acted = steps.filter { Self.changing.contains($0.action) }
        guard !acted.isEmpty else { return proposed }                      // pure questions have nothing to verify on screen
        var check = AgentStep(action: "verify", detail: "Re-reading the screen", say: "Checking my work")
        steps.append(check)
        stage?.thought("Checking my work")
        let t0 = now()
        var screen = "(no window)"
        if let app = Screen.allowForeground ? (Screen.targetApp(excluding: ownBundle) ?? target) : target, let snap = Screen.snapshot(app, menusFrom: lastSnapshot) {
            await stage?.scan(window: snap.windowFrame, elements: snap.elements.filter { $0.role != "text" })
            let full = Screen.visibleText(app)
            screen = snap.text(maxActions: 25, maxText: 500) + "\nLatest text in the window:\n" + String(full.suffix(700))
        }
        // Hard facts the model cannot talk its way around.
        var facts: [String] = []
        let typedCommand = acted.contains { $0.action == "type" && $0.result.contains("NOT run yet") }
        let ran = acted.contains { $0.result.hasPrefix("Ran it") }
        if typedCommand && !ran { facts.append("A command was typed but never run (return was not pressed).") }
        let failures = acted.filter { $0.result.hasPrefix("FAILED") }
        if !failures.isEmpty { facts.append("\(failures.count) step(s) failed: " + failures.map { $0.result.prefix(110) }.joined(separator: " | ")) }
        if acted.allSatisfy({ $0.result.hasPrefix("FAILED") || $0.result.contains("nothing visibly changed") }) { facts.append("No step had a confirmed effect.") }

        let schema = "{\"type\":\"object\",\"properties\":{\"evidence\":{\"type\":\"string\"},\"verdict\":{\"type\":\"string\",\"enum\":[\"done\",\"partly\",\"not_done\"]},\"reply\":{\"type\":\"string\"}},\"required\":[\"evidence\",\"verdict\",\"reply\"],\"additionalProperties\":false}"
        let sys = """
        You are a strict checker for an assistant that operates a Mac for \(owner). Judge only from the evidence: the step results and what is on screen now.
        - done: the screen or a result proves the request was fully carried out.
        - partly: some of it happened. not_done: it did not happen, or there is no proof.
        A typed command that was never run is not done. Text typed into the wrong place (for example a browser address bar) is not done. If the terminal shows Password: the command is waiting for a password, which is partly.
        evidence: under 20 words, what proves your verdict. reply: one or two short spoken sentences to \(owner) saying honestly what happened and, if not done, what is left. JSON only.
        """
        let user = "Request: \(req)\n\nSteps and results:\n\(history())\n\nKnown facts:\n\(facts.isEmpty ? "(none)" : facts.joined(separator: "\n"))\n\nScreen now:\n\(screen)\n\nThe assistant wants to say: \"\(proposed)\"\n\nJSON: evidence, verdict, reply."
        var verdict = "done", reply = proposed, evidence = ""
        if let r = try? await bonsai.json(system: sys, user: user, schemaJSON: schema, maxTokens: 150) {
            verdict = r.json["verdict"] as? String ?? "done"
            evidence = r.json["evidence"] as? String ?? ""
            if let rp = r.json["reply"] as? String, !rp.isEmpty { reply = rp }
        }
        // The hard facts win over the model.
        if !facts.isEmpty && verdict == "done" {
            verdict = "not_done"
            reply = typedCommand && !ran ? "I typed the command but it has not run yet, so the task is not finished." : "That did not work: " + (failures.first.map { String($0.result.dropFirst(8).prefix(120)) } ?? "I could not confirm any change on screen.")
        }
        check.result = (verdict == "done" ? "Confirmed" : verdict == "partly" ? "Partly done" : "Not done") + (evidence.isEmpty ? "" : ": " + evidence)
        check.secs = now() - t0; check.done = true
        if let i = steps.firstIndex(where: { $0.id == check.id }) { steps[i] = check }
        lastVerdict = verdict
        return reply
    }

    static let terminals: Set<String> = ["Terminal", "iTerm2", "iTerm", "Ghostty", "Warp", "kitty", "Alacritty", "cmux"]
    static let keys: [String: (CGKeyCode, Bool)] = ["return": (36, false), "enter": (36, false), "tab": (48, false), "escape": (53, false), "save": (1, true),
                                                    "select all": (0, true), "copy": (8, true), "paste": (9, true), "undo": (6, true), "new": (45, true)]

    /// Returns (result text for the model, whether the request is finished).
    func perform(_ action: String, _ tid: Int, _ text: String, _ say: String, _ snap: ScreenSnapshot?, _ step: inout AgentStep) async -> (String, Bool) {
        switch action {
        case "point":
            guard let el = snap?.element(tid) else { return ("There is no element \(tid) on screen", false) }
            await stage?.glide(to: CGPoint(x: el.frame.midX, y: el.frame.midY), frame: el.frame, thought: el.label)
            answer = text.isEmpty ? "It's right here: \(el.label)." : text
            await stage?.speak(answer)
            return ("Pointed at \(el.label)", true)
        case "click":
            guard let snap, let el = snap.element(tid) else { return ("There is no element \(tid) on screen", false) }
            let p = CGPoint(x: el.frame.midX, y: el.frame.midY)
            await stage?.glide(to: p, frame: el.frame, thought: say.isEmpty ? "Clicking \(el.label)" : say)
            await stage?.click(at: p)
            let ok = Screen.press(snap, id: tid)
            let changed = await settle(snap)
            return (!ok ? "FAILED: could not click \(el.label). Try a menu command for the same thing, or a different element." : changed ? "Clicked \(el.label); the screen changed" : "Clicked \(el.label), but nothing visibly changed. It may not have worked.", false)
        case "type":
            guard let app = target else { return ("No app to type into", false) }
            let isTerminal = Self.terminals.contains(app.localizedName ?? "")
            let before = Screen.visibleText(app)
            var point: CGPoint?
            if let snap, let fid = (snap.element(tid)?.role == "field" ? tid : Screen.defaultField(snap)), let el = snap.element(fid) {
                point = CGPoint(x: el.frame.midX, y: el.frame.midY)
                step.frame = el.frame; step.point = point
                await stage?.glide(to: point!, frame: el.frame, thought: say.isEmpty ? "Typing" : say)
                await stage?.click(at: point!)
                // In the background (tests) use the quiet accessibility route. On the real screen, click and type like a person:
                // apps only show suggestions and enable buttons for real key presses.
                if !isTerminal && !Screen.allowForeground {
                    _ = Screen.focus(snap, id: fid)
                    if el.value.isEmpty { _ = Screen.setValue(snap, id: fid, text: text) } else { _ = Screen.insertAtEnd(snap, id: fid, text: text) }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Self.appeared(text, before: before, after: Screen.visibleText(app)) { return ("Verified: \"\(text.prefix(60))\" is now in the document. If the request is complete, answer now, in plain words.", false) }
                }
            } else { stage?.thought(say.isEmpty ? "Typing" : say) }
            // Real key presses into the app.
            guard await Screen.bringForward(app) else { return ("FAILED: could not bring \(app.localizedName ?? "the app") to the front, nothing was typed", false) }
            if let point, !isTerminal { Screen.click(at: point) ; try? await Task.sleep(nanoseconds: 220_000_000) }
            // A shell command must go to a terminal prompt, never to an address bar or a search field.
            if isTerminal, ["AXTextField", "AXComboBox", "AXSearchField"].contains(Screen.focusedRole(app)) {
                return ("FAILED: the keyboard focus is in a text box (an address or search bar), not at a terminal prompt. Nothing was typed. Open the Terminal app with open_app instead.", false)
            }
            Screen.type(text)
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Self.appeared(text, before: before, after: Screen.visibleText(app)) else {
                return ("FAILED: the text did not appear in \(app.localizedName ?? "the app"). Do not claim it was typed.", false)
            }
            if isTerminal { return ("Verified: the command is typed at the prompt but NOT run yet. Use key return to run it.", false) }
            _ = await settle(snap)
            return ("Verified: \"\(text.prefix(60))\" was typed. Look at the new screen: pick a suggestion if one appeared, or continue.", false)
        case "menu":
            guard let snap else { return ("No app is open", false) }
            guard let path = Screen.findMenu(snap, text) else {
                let near = snap.menus.filter { m in text.lowercased().split(separator: " ").contains { m.lowercased().contains($0) } }.prefix(8)
                return ("No menu command named \"\(text)\". Similar: \(near.joined(separator: "; "))", false)
            }
            step.detail = path
            // Fly to the real menu title in the menu bar.
            let top = path.components(separatedBy: " > ").first ?? ""
            let tf = snap.menuTitleFrames[top]
            let barPoint = tf.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: snap.windowFrame.minX + 160, y: 12)
            step.frame = tf; step.point = barPoint
            await stage?.glide(to: barPoint, frame: nil, thought: say.isEmpty ? path : say)
            await stage?.click(at: barPoint)
            let ok = Screen.pressMenu(snap, path: path)
            let changed = await settle(snap)
            return (!ok ? "FAILED: could not choose \(path)" : changed ? "Chose \(path); the screen changed" : "Chose \(path), but nothing visibly changed yet", false)
        case "key":
            let name = Self.keys.keys.sorted { $0.count > $1.count }.first { text.lowercased().contains($0) } ?? ""
            guard let app = target, let k = Self.keys[name] else { return ("Unknown key. Use one of: return, tab, escape, save, select all, copy, paste, undo, new", false) }
            stage?.thought(say.isEmpty ? "Pressing \(text)" : say)
            // Running a shell command is the kind of thing Onboard asks about first.
            if name == "return" || name == "enter", Self.terminals.contains(app.localizedName ?? ""),
               let cmd = steps.dropLast().last(where: { $0.action == "type" })?.detail {
                let ok = await stage?.approve("Run this command?", detail: cmd) ?? true
                guard ok else { answer = "Okay, I left the command in the terminal without running it."; await stage?.speak(answer); return ("Not approved", true) }
            }
            if name == "return" || name == "enter", ["Messages", "Mail", "Slack", "Discord", "WhatsApp"].contains(app.localizedName ?? "") {
                let ok = await stage?.approve("Send this?", detail: "Pressing Return in \(app.localizedName ?? "this app") may send the message.") ?? false
                guard ok else { return ("Not approved: \(owner) did not allow sending. Leave the draft as it is and answer.", false) }
            }
            guard await Screen.bringForward(app) else { return ("Could not bring the app forward", false) }
            let beforeText = Screen.visibleText(app)
            Screen.key(k.0, command: k.1)
            _ = await settle(snap)
            if Self.terminals.contains(app.localizedName ?? "") && (name == "return" || name == "enter") {
                // Read what the terminal printed, so the answer reports the real outcome (errors, a password prompt, output).
                try? await Task.sleep(nanoseconds: 700_000_000)
                let after = Screen.visibleText(app)
                let new = after.count > beforeText.count ? String(after.suffix(after.count - beforeText.count + 80)) : String(after.suffix(300))
                let tail = new.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(8).joined(separator: " / ")
                return ("Ran it. The terminal now shows: \(tail.suffix(500)). Report exactly this outcome: if it shows Password:, say it is waiting for \(owner)'s password; if it shows an error, say so.", false)
            }
            return ("Pressed \(name)", false)
        case "open_app":
            stage?.thought(say.isEmpty ? "Opening \(text)" : say)
            // Headless checks never launch anything: they only report what would open.
            if !Screen.allowForeground {
                guard let r = Screen.resolveApp(text) else { return ("FAILED: there is no app named \(text).", false) }
                return ("(dry run) \(r.name) would open", false)
            }
            guard let a = await Screen.open(text) else {
                let near = Screen.similarApps(text)
                return ("FAILED: there is no app named \(text)." + (near.isEmpty ? "" : " Installed apps with similar names: \(near.joined(separator: ", ")).") + " Do not search memory for apps.", false)
            }
            target = a
            return ("\(a.localizedName ?? text) is open and in front", false)
        case "search_memory":
            stage?.thought(say.isEmpty ? "Searching memory" : say)
            let hits = await memory.search(text, k: 3)
            guard let top = hits.first else { return ("Nothing in memory about that", false) }
            step.source = top.chunk.source
            // A question gets a focused answer from the passages alone (small prompt: faster and more faithful than the full loop).
            if Self.isQuestion(request) {
                let passages = hits.map { "[\($0.chunk.title)]\n\($0.chunk.text.prefix(700))" }.joined(separator: "\n\n")
                let schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}"
                if let r = try? await bonsai.json(system: "You are Onboard, \(owner)'s assistant on a Mac with no internet. Answer from the passages only. If they give a procedure, say its steps in order. Two or three short spoken sentences, no lists, no markdown. If the passages do not answer it, say so. JSON only.",
                                                  user: "Passages from \(owner)'s files:\n\(passages)\n\nQuestion: \(request)\n\nJSON: answer.", schemaJSON: schema, maxTokens: 140),
                   let a = r.json["answer"] as? String, !a.isEmpty {
                    steps[steps.count - 1].result = "Found in \(top.chunk.title)"; steps[steps.count - 1].done = true
                    steps[steps.count - 1].source = top.chunk.source
                    answer = a
                    await stage?.speak(a)
                    return ("Found in \(top.chunk.title)", true)
                }
            }
            return ("Found in \(owner)'s files:\n" + hits.map { "[\($0.chunk.title)] \($0.chunk.text.prefix(420))" }.joined(separator: "\n") + "\nUse these facts. If the request was a question, answer it now.", false)
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
        case "list_apps":
            stage?.thought(say.isEmpty ? "Looking at installed apps" : say)
            let all = Screen.installedApps().keys.sorted()
            let f = text.lowercased()
            let hits = f.isEmpty ? all : all.filter { $0.lowercased().contains(f) }
            return (hits.isEmpty ? "No installed app matches \"\(text)\". Some apps: \(all.prefix(40).joined(separator: ", "))" : "Installed: \(hits.prefix(40).joined(separator: ", "))", false)
        case "show_menu":
            guard let snap else { return ("FAILED: no app is open", false) }
            stage?.thought(say.isEmpty ? "Looking through the menus" : say)
            if text.isEmpty { return ("Menus: \(Screen.menuTitles(snap).joined(separator: ", "))", false) }
            let items = Screen.menuItems(snap, top: text)
            if let tf = snap.menuTitleFrames.first(where: { $0.key.lowercased() == text.lowercased() })?.value {
                await stage?.glide(to: CGPoint(x: tf.midX, y: tf.midY), frame: tf, thought: say.isEmpty ? "Looking in \(text)" : say)
            }
            return (items.isEmpty ? "There is no \(text) menu. Menus: \(Screen.menuTitles(snap).joined(separator: ", "))" : "\(text) menu has: \(items.prefix(45).joined(separator: "; "))", false)
        case "scroll":
            guard let app = target else { return ("FAILED: no app is open", false) }
            stage?.thought(say.isEmpty ? "Scrolling" : say)
            let ok = Screen.scroll(app, down: !text.lowercased().contains("up"))
            _ = await settle(snap)
            return (ok ? "Scrolled \(text.lowercased().contains("up") ? "up" : "down"); the screen shows new content" : "FAILED: nothing here can scroll further", false)
        case "draft_message":
            let p = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            var to = p.count > 1 ? p[0] : "", shown = to
            let body = p.count > 1 ? p.dropFirst().joined(separator: " | ") : text
            // A name becomes a real number or address from the Mac's Contacts, so the draft arrives addressed.
            let isHandle = to.contains("@") || to.filter(\.isNumber).count >= 7
            if !to.isEmpty, !isHandle, !Tools.dryRun, let c = await Tools.lookupContact(to) { shown = "\(c.name) (\(c.handle))"; to = c.handle }
            let ok = await stage?.approve("Draft this message?", detail: "To: \(shown.isEmpty ? "(you choose)" : shown)\n\n\(body)") ?? true
            guard ok else { answer = "Okay, I left it."; await stage?.speak(answer); return ("Not approved", true) }
            var r = Tools.draftMessage(to: to, body: body)
            let addressed = to.contains("@") || to.filter(\.isNumber).count >= 7
            if !addressed, !to.isEmpty, !Tools.dryRun, Screen.allowForeground {
                // Not in Contacts (or no access): type the name into the To field and take the first suggestion.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let m = Screen.runningApp("Messages"), await Screen.bringForward(m), let snap = Screen.snapshot(m),
                   let field = snap.elements.first(where: { $0.role == "field" && ($0.label.lowercased().hasPrefix("to") || $0.label.lowercased().contains("recipient")) }) {
                    await stage?.glide(to: CGPoint(x: field.frame.midX, y: field.frame.midY), frame: field.frame, thought: "Adding \(to)")
                    Screen.click(at: CGPoint(x: field.frame.minX + 60, y: field.frame.midY))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    Screen.type(to)
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    Screen.key(36)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    let now = Screen.visibleText(m)
                    r = now.lowercased().contains(to.lowercased()) ? "Verified: a message to \(to) is drafted in Messages, not sent." : "Messages is open with the text drafted, but I could not confirm \(to) was added as the recipient."
                }
            } else if addressed, shown != to { r = "Verified: a message to \(shown) is drafted in Messages, not sent." }
            await summarizeAfter(r.replacingOccurrences(of: "Verified: ", with: "")); return (r, true)
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

    /// Wait until the screen reacts to an action and stops changing (at most about a second), instead of a fixed pause.
    /// Did `text` show up? (New text is longer or contains the typed words; terminals wrap lines, so compare without whitespace.)
    static func appeared(_ text: String, before: String, after: String) -> Bool {
        func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        let needle = squash(String(text.prefix(40)))
        guard !needle.isEmpty else { return true }
        let a = squash(after), b = squash(before)
        return a.components(separatedBy: needle).count > b.components(separatedBy: needle).count
    }

    @discardableResult func settle(_ before: ScreenSnapshot?) async -> Bool {
        guard let t = target, let before else { try? await Task.sleep(nanoseconds: 300_000_000); return true }
        var last = before.signature, changed = false
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 130_000_000)
            // A new app in front counts as a change.
            if Screen.allowForeground, let f = Screen.targetApp(excluding: ownBundle), f.processIdentifier != t.processIdentifier { return true }
            guard let now = Screen.snapshot(t, limit: 1500, menusFrom: before) else { continue }
            if now.signature != last { changed = true; last = now.signature } else if changed { return true }
        }
        return changed
    }

    static func isQuestion(_ r: String) -> Bool {
        let l = r.lowercased().trimmingCharacters(in: .whitespaces)
        // "Can you open...", "Could you draft...", "Please ..." are requests to act, even with a question mark.
        if ["can you", "could you", "would you", "will you", "please", "go ", "open", "draft", "make", "add", "write", "send", "create", "type", "click"].contains(where: { l.hasPrefix($0) }) { return false }
        if l.hasSuffix("?") { return true }
        return ["what", "how", "who", "when", "where", "why", "which", "is ", "are ", "does", "do i", "tell me"].contains { l.hasPrefix($0) }
    }

    func summarizeAfter(_ result: String) async {
        steps[steps.count - 1].result = result; steps[steps.count - 1].done = true
        answer = result.hasSuffix(".") ? result : result + "."
        await stage?.speak(answer)
    }
}
