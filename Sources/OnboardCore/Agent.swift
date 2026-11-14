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
    public var maxSteps = 14
    /// How many times a failure must be answered with a different attempt before Onboard may say it could not do it.
    public var maxRetries = 3
    private var cancelled = false
    private var target: NSRunningApplication?

    public init(bonsai: Bonsai, memory: MemoryIndex) { self.bonsai = bonsai; self.memory = memory }

    public func cancel() { cancelled = true }

    // MARK: the harness
    // The loop follows the design shared by browser-use, macOS-use and Agent S: every step the model first judges its
    // previous step against the fresh screen, keeps a short memory, states one goal, then picks one generic action.
    // The harness (not the model) computes what changed on screen, counts failures, blocks repeats, and has a separate
    // judge confirm the result before anything is reported as done.

    static let actions = ["click", "type", "key", "menu", "scroll", "open_app", "wait", "search_memory", "add_reminder", "add_event", "point", "done"]
    static let changing: Set<String> = ["type", "click", "menu", "key", "open_app", "scroll"]

    var system: String {
        """
        You are Onboard. You operate \(owner)'s Mac for them, offline. You see the app in front as a list of elements and act one step at a time.

        Elements: "[12] button "Save"" can be acted on by its number. A leading * means it appeared since your last step (your action caused it: check whether you need it). Lines starting with - are text on screen: use them to verify outcomes.

        Each step, answer with ONE JSON object, fields in this order:
        - prev_result: success, failed or unknown. Did your previous step do what you intended? Judge from CHANGES and the screen, not from hope. Use none on the first step.
        - memory: one short sentence of facts worth keeping: what is done, what is left, names and values found.
        - next_goal: one sentence saying what this step will do and to which element.
        - action: one of the actions below.
        - target: the element number, or 0.
        - target_label: the label of that element copied exactly, or "".
        - text: the literal content for the action, or "".
        - success: only matters for done. true only if the whole task is finished and you can point to proof.

        Actions:
        - click: press element target.
        - type: type text into field target (0 = the focused text area). Only the exact words, nothing else.
        - key: press a key. text = return, tab, escape, save, select all, copy, paste, undo or new.
        - menu: choose a menu bar command by name. text = for example "New Window".
        - scroll: text = down or up. Reveals more elements.
        - open_app: text = the app name.
        - wait: the screen is still loading.
        - search_memory: look in \(owner)'s notes, manuals and files on this Mac. text = search words.
        - add_reminder: text = title | when.    - add_event: text = title | when.
        - point: show \(owner) where element target is. text = one sentence of guidance. Ends the task. For "where is" and "how do I" questions.
        - done: finish. text = what to tell \(owner), one or two short spoken sentences. Set success honestly.

        Rules:
        1. Only use element numbers that are in the list. One action per step.
        2. Never assume an action succeeded just because you issued it. Check CHANGES and the screen first.
        3. If you typed into a field, you may still need to pick a suggestion, press return, or click a button to complete it.
        4. Handle popups, dialogs and suggestion lists before anything else.
        5. If the same action failed or changed nothing, do something different. Never repeat it.
        6. Never send, submit, pay or delete for \(owner). Leave drafts ready and say so. A typed terminal command has not run until return is pressed.
        7. Never invent facts: use search_memory or the screen. For a question about facts, search_memory, then done with the answer.
        8. If any part of the request is unmet, uncertain or unverifiable, done must have success false and say what is left.
        9. Use the most direct action. To add text to a document, type into its text area: no clicking, selecting or cursor positioning first. For reminders and calendar events use add_reminder and add_event directly: never open those apps.

        Examples (one step each):
        TASK: add a line that says Pump A checked. ELEMENTS: [3] field "(unnamed field)" = "Log..."
        {"prev_result":"none","memory":"Need to add one line to the open document.","next_goal":"Type the line into the document text area","action":"type","target":3,"target_label":"(unnamed field)","text":"Pump A checked","success":false}
        Next step, after CHANGES shows the value now ends with Pump A checked:
        {"prev_result":"success","memory":"The line Pump A checked is in the document.","next_goal":"Report that it is done","action":"done","target":0,"target_label":"","text":"I added the line Pump A checked to your document.","success":true}
        TASK: remind me to call Sam tomorrow at 9.
        {"prev_result":"none","memory":"A reminder is needed.","next_goal":"Add the reminder","action":"add_reminder","target":0,"target_label":"","text":"Call Sam | tomorrow 9am","success":false}
        TASK: what does the manual say about filter changes?
        {"prev_result":"none","memory":"Need the filter procedure from the notes.","next_goal":"Search the notes","action":"search_memory","target":0,"target_label":"","text":"filter change procedure","success":false}
        TASK: what does this document say? (the answer is already on screen)
        {"prev_result":"none","memory":"The document text is visible.","next_goal":"Answer from the screen","action":"done","target":0,"target_label":"","text":"It says the pump was checked on Sol 211 and pressure is nominal.","success":true}
        TASK: how do I make this bold? (a question about how: explain or point, do not do it)
        {"prev_result":"none","memory":"The user wants to know how, not for me to do it.","next_goal":"Explain where Bold is","action":"done","target":0,"target_label":"","text":"Select the text, then open the Format menu, choose Font, and pick Bold.","success":true}
        TASK: text Maya that I'm late. ELEMENTS after typing Maya in the To field: *[12] row "Maya Chen" ...
        {"prev_result":"success","memory":"Messages is open, new message started, typed Maya; a suggestion appeared.","next_goal":"Pick Maya Chen from the suggestions","action":"click","target":12,"target_label":"Maya Chen","text":"","success":false}
        JSON only.
        """
    }

    struct Trail { var goal: String; var action: String; var result: String }
    public var usePlan = false
    private var plan: [String] = []
    private var planDone = 0
    private var memoryNote = ""
    private var trail: [Trail] = []
    private var lastResult = ""
    private var consecutiveFailures = 0
    private var blocked: Set<String> = []
    private var judgeRejections = 0
    private var firstScreen = ""

    func history() -> String {
        trail.isEmpty ? "(none)" : trail.enumerated().map { "\($0.offset + 1). \($0.element.goal) -> \($0.element.action) -> \($0.element.result.prefix(200))" }.joined(separator: "\n")
    }

    /// Elements as the model sees them, with * on the ones that were not there at the last step.
    func render(_ snap: ScreenSnapshot, previous: Set<String>) -> String {
        var out = ""
        for e in snap.elements.filter({ $0.id > 0 }).prefix(70) {
            let isNew = !previous.isEmpty && !previous.contains(e.role + "|" + e.label)
            out += "\(isNew ? "*" : "")[\(e.id)] \(e.role) \"\(e.label.prefix(60))\"" + (e.value.isEmpty ? "" : " = \"\(e.value.prefix(70))\"") + "\n"
        }
        var chars = 0
        for t in snap.elements.filter({ $0.id == 0 }) where chars < 900 { out += "- \"\(t.label.prefix(160))\"\n"; chars += min(t.label.count, 160) }
        return out
    }

    static func keys(of snap: ScreenSnapshot?) -> Set<String> { Set((snap?.elements ?? []).filter { $0.id > 0 }.map { $0.role + "|" + $0.label }) }

    /// What changed on screen between two looks, computed by the harness so the model cannot fool itself.
    static func changes(_ a: ScreenSnapshot?, _ b: ScreenSnapshot?) -> String {
        guard let a, let b else { return "CHANGES: unknown" }
        if a.app != b.app { return "CHANGES: now in \(b.app), window \"\(b.window)\"" }
        let ka = keys(of: a), kb = keys(of: b)
        let added = kb.subtracting(ka), removed = ka.subtracting(kb)
        var parts: [String] = []
        if a.window != b.window { parts.append("window is now \"\(b.window)\"") }
        if !added.isEmpty { parts.append("+\(added.count) new (" + added.prefix(4).map { $0.split(separator: "|").last.map(String.init) ?? "" }.joined(separator: ", ") + ")") }
        if !removed.isEmpty { parts.append("-\(removed.count) removed") }
        for e in b.elements where e.id > 0 && e.role == "field" {
            if let old = a.elements.first(where: { $0.role == "field" && $0.label == e.label }), old.value != e.value { parts.append("value of \"\(e.label.prefix(30))\" is now \"\(e.value.prefix(50))\"") }
        }
        let ta = Set(a.elements.filter { $0.id == 0 }.map(\.label)), tb = Set(b.elements.filter { $0.id == 0 }.map(\.label))
        let newText = tb.subtracting(ta)
        if !newText.isEmpty { parts.append("new text: " + newText.prefix(2).map { "\"\($0.prefix(60))\"" }.joined(separator: ", ")) }
        return parts.isEmpty ? "CHANGES: none" : "CHANGES: " + parts.joined(separator: "; ")
    }

    /// A short list of subgoals for tasks that take several steps (skipped for questions and one-liners).
    func makePlan(_ req: String, screen: String) async {
        plan = []; planDone = 0
        // Off by default: for a small model an upfront plan invents needless steps ("position the cursor", "open Reminders")
        // and then follows them. The per-step memory and goal carry progress instead.
        guard usePlan, !Self.isQuestion(req), req.split(separator: " ").count > 3 else { return }
        let schema = "{\"type\":\"object\",\"properties\":{\"subgoals\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"maxLength\":70},\"minItems\":1,\"maxItems\":6}},\"required\":[\"subgoals\"],\"additionalProperties\":false}"
        let sys = "You plan tasks for an assistant that operates a Mac by clicking, typing and choosing menu commands. Break the request into 1 to 6 short subgoals in order. Each is one visible outcome (for example: Messages is open; a new message is started; the recipient is chosen; the text is written). Use as few as possible: adding text to the open document, setting a reminder, or answering from notes is ONE subgoal. Never add subgoals for positioning the cursor, selecting, or opening an app that is already in front. Do not include verification steps. Do not include sending or submitting unless asked. JSON only."
        if let r = try? await bonsai.json(system: sys, user: "Request: \(req)\nApp in front: \(screen.prefix(200))\nJSON: subgoals.", schemaJSON: schema, maxTokens: 150),
           let g = r.json["subgoals"] as? [String] { plan = g.filter { !$0.isEmpty } }
    }

    func planText() -> String {
        plan.isEmpty ? "(single step)" : plan.enumerated().map { ($0.offset < planDone ? "[x] " : $0.offset == planDone ? "[>] " : "[ ] ") + $0.element }.joined(separator: "\n")
    }

    public func run(_ text: String, app: NSRunningApplication? = nil) async {
        let req = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty, !running else { return }
        running = true; cancelled = false; request = req; steps = []; answer = ""; lastVerdict = ""
        trail = []; memoryNote = ""; lastResult = "(nothing yet)"; consecutiveFailures = 0; blocked = []; judgeRejections = 0
        let t0 = now()
        defer { running = false; turnSecs = now() - t0; stage?.rest(); writeRunLog() }
        target = app ?? Screen.targetApp(excluding: ownBundle)

        var snap: ScreenSnapshot? = target.flatMap { Screen.snapshot($0) }
        lastSnapshot = snap
        if let s = snap { await stage?.scan(window: s.windowFrame, elements: s.elements.filter { $0.role != "text" }) }
        firstScreen = snap.map { render($0, previous: []) } ?? "(no window)"
        await makePlan(req, screen: snap.map { "\($0.app), window \"\($0.window)\"" } ?? "nothing")
        var previousKeys: Set<String> = []
        var stale = 0

        for stepNo in 1...maxSteps {
            if cancelled { answer = "Stopped."; return }
            // Follow the screen: a different app in front (opened by a step, or by the user) becomes the one we work in.
            if Screen.allowForeground, let f = Screen.targetApp(excluding: ownBundle), f.processIdentifier != target?.processIdentifier, stepNo > 1 { target = f }
            let before = snap
            snap = target.flatMap { Screen.snapshot($0, menusFrom: lastSnapshot) }
            lastSnapshot = snap
            let diff = stepNo == 1 ? "CHANGES: (first step)" : Self.changes(before, snap)
            stale = diff == "CHANGES: none" ? stale + 1 : 0

            let ids = [0] + (snap?.elements.filter { $0.id > 0 }.map(\.id) ?? [])
            let lastStep = stepNo == maxSteps || consecutiveFailures >= 5
            let allowed = lastStep ? ["done"] : Self.actions
            let schema = "{\"type\":\"object\",\"properties\":{"
                + "\"prev_result\":{\"type\":\"string\",\"enum\":[\"none\",\"success\",\"failed\",\"unknown\"]},"
                + "\"memory\":{\"type\":\"string\",\"maxLength\":170},\"next_goal\":{\"type\":\"string\",\"maxLength\":110},"
                + "\"action\":{\"type\":\"string\",\"enum\":[\(allowed.map { "\"\($0)\"" }.joined(separator: ","))]},"
                + "\"target\":{\"type\":\"integer\",\"enum\":[\(ids.map(String.init).joined(separator: ","))]},"
                + "\"target_label\":{\"type\":\"string\",\"maxLength\":70},\"text\":{\"type\":\"string\",\"maxLength\":500},\"success\":{\"type\":\"boolean\"}},"
                + "\"required\":[\"prev_result\",\"memory\",\"next_goal\",\"action\",\"target\",\"target_label\",\"text\",\"success\"],\"additionalProperties\":false}"

            var notes: [String] = []
            if consecutiveFailures >= 3 { notes.append("REPLAN SUGGESTED: your approach is not working. Choose a different way to reach the goal.") }
            if stale >= 3 { notes.append("Your actions might not be having the intended effect: the screen has not changed for \(stale) steps.") }
            if !blocked.isEmpty { notes.append("BLOCKED (they did nothing, do not use them): " + blocked.sorted().joined(separator: "; ")) }
            if stepNo >= maxSteps * 3 / 4 && !lastStep { notes.append("You are running out of steps. Finish what matters and use done.") }
            if lastStep { notes.append("This is the last step. Use done and report honestly what was and was not achieved.") }
            let hints = snap.map { Screen.menuHints($0, for: req) } ?? []
            let user = """
            TASK: \(req)\(plan.isEmpty ? "" : "\nPLAN:\n" + planText())
            MEMORY: \(memoryNote.isEmpty ? "(empty)" : memoryNote)
            LAST STEPS:
            \(history())
            LAST RESULT: \(lastResult)
            \(diff)
            \(notes.joined(separator: "\n"))
            APP: \(snap?.app ?? "none"). WINDOW: "\(snap?.window ?? "")"
            ELEMENTS:
            \(snap.map { render($0, previous: previousKeys) } ?? "(no window is open)")
            Menu commands that may help: \(hints.isEmpty ? "(none)" : hints.prefix(10).joined(separator: "; "))
            Time: \(Date().formatted(date: .abbreviated, time: .shortened)). Step \(stepNo) of \(maxSteps).
            """
            previousKeys = Self.keys(of: snap)

            guard let r = try? await bonsai.json(system: system, user: user, schemaJSON: schema, maxTokens: 260) else {
                answer = "I can't reach Bonsai. Is LM Studio running?"; await stage?.speak(answer); return
            }
            promptTokens = r.promptTokens
            let action = r.json["action"] as? String ?? "done"
            var tid = r.json["target"] as? Int ?? 0
            let label = (r.json["target_label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let txt = (r.json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = (r.json["next_goal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let prev = r.json["prev_result"] as? String ?? "unknown"
            if let m = r.json["memory"] as? String, !m.isEmpty { memoryNote = m }
            // The model's verdict on its previous step moves the plan forward.
            if prev == "success", stepNo > 1, planDone < plan.count, diff != "CHANGES: none" { planDone += 1 }

            if action == "done" {
                let claimed = r.json["success"] as? Bool ?? false
                let (ok, reply, reason) = await judge(req, proposed: txt.isEmpty ? goal : txt, claimed: claimed, final: snap)
                if !ok && claimed && judgeRejections < 1 && !lastStep {
                    // Claimed done but the judge disagrees: tell it why, once, and let it finish the job.
                    judgeRejections += 1
                    lastResult = "CHECK FAILED: the task is not done yet. \(reason)"
                    trail.append(Trail(goal: "report done", action: "done", result: lastResult)); if trail.count > 3 { trail.removeFirst() }
                    continue
                }
                lastVerdict = ok ? "done" : "not_done"
                answer = reply
                await stage?.speak(answer); return
            }

            // Wrong-element guard: the label the model meant must match the number it gave. If another element has that
            // exact label, use that one; otherwise reject the step.
            if tid > 0, !label.isEmpty, let el = snap?.element(tid) {
                let a = el.label.lowercased(), b = label.lowercased()
                if !(a.contains(b) || b.contains(a)) {
                    if let right = snap?.elements.first(where: { $0.id > 0 && $0.label.lowercased() == b }) { tid = right.id }
                    else {
                        consecutiveFailures += 1
                        lastResult = "ERROR: element [\(tid)] is \"\(el.label.prefix(50))\", not \"\(label.prefix(50))\". Nothing was done. Pick the number of the element you mean."
                        trail.append(Trail(goal: goal, action: "\(action) [\(tid)]", result: lastResult)); if trail.count > 3 { trail.removeFirst() }
                        continue
                    }
                }
            }
            let signature = "\(action) " + (tid > 0 ? "[\(tid)] \"\(snap?.element(tid)?.label.prefix(40) ?? "")\"" : "\"\(txt.prefix(40))\"")
            if blocked.contains(signature) {
                consecutiveFailures += 1
                lastResult = "ERROR: \(signature) is blocked because it did nothing before. Choose a different action or element."
                continue
            }
            // The screen may have moved while the model was thinking: find the same control again.
            if tid > 0, let t = target, let old = snap?.element(tid), let fresh = Screen.snapshot(t, menusFrom: snap),
               fresh.signature != snap?.signature, let moved = fresh.relocate(old) { tid = moved.id; snap = fresh; lastSnapshot = fresh }

            var step = AgentStep(action: action, detail: tid > 0 ? "\(snap?.element(tid)?.label.prefix(50) ?? "#\(tid)")" + (txt.isEmpty ? "" : " · \(txt.prefix(60))") : txt, say: goal)
            if let el = snap?.element(tid) { step.frame = el.frame; step.point = CGPoint(x: el.frame.midX, y: el.frame.midY) }
            step.secs = r.secs
            steps.append(step)
            let tA = now()
            var (result, finish) = await perform(action, tid, txt, goal, snap, &step)
            if finish { step.result = result; step.secs += now() - tA; step.done = true; steps[steps.count - 1] = step; return }

            // What actually happened, as seen on screen.
            let after = (Screen.allowForeground ? (Screen.targetApp(excluding: ownBundle) ?? target) : target).flatMap { Screen.snapshot($0, menusFrom: snap) }
            let effect = Self.changes(snap, after)
            let failed = result.hasPrefix("FAILED") || result.hasPrefix("ERROR")
            if Self.changing.contains(action) {
                if failed { consecutiveFailures += 1 }
                else if effect == "CHANGES: none" && !result.hasPrefix("Verified") {
                    consecutiveFailures += 1
                    result += " But nothing changed on screen."
                    if trail.last?.action == signature { blocked.insert(signature) }
                } else { consecutiveFailures = 0 }
            } else if failed { consecutiveFailures += 1 } else { consecutiveFailures = 0 }
            lastResult = (failed ? "" : "OK ") + result.prefix(700)
            step.result = String(result.prefix(300)); step.secs += now() - tA; step.done = true
            steps[steps.count - 1] = step
            trail.append(Trail(goal: goal, action: signature, result: String(result.prefix(200)))); if trail.count > 3 { trail.removeFirst() }
        }
        // Out of steps without a done.
        let (_, reply, _) = await judge(req, proposed: "I ran out of steps.", claimed: false, final: lastSnapshot)
        lastVerdict = "not_done"; answer = reply
        await stage?.speak(answer)
    }

    /// A separate strict pass decides whether the task is really done, from the request, the action log, and the
    /// first and final screens. Returns (done, what to tell the owner, why not).
    func judge(_ req: String, proposed: String, claimed: Bool, final: ScreenSnapshot?) async -> (Bool, String, String) {
        let acted = steps.filter { Self.changing.contains($0.action) }
        guard !acted.isEmpty else { return (claimed, proposed, "") }             // nothing was changed on screen: nothing to verify there
        var check = AgentStep(action: "verify", detail: "Re-reading the screen", say: "Checking my work")
        steps.append(check)
        stage?.thought("Checking my work")
        let t0 = now()
        var screen = "(no window)"
        if let app = Screen.allowForeground ? (Screen.targetApp(excluding: ownBundle) ?? target) : target, let snap = Screen.snapshot(app, menusFrom: lastSnapshot) {
            await stage?.scan(window: snap.windowFrame, elements: snap.elements.filter { $0.role != "text" })
            screen = "App: \(snap.app). Window: \"\(snap.window)\"\n" + String(render(snap, previous: []).prefix(1500)) + "\nLatest text in the window:\n" + String(Screen.visibleText(app).suffix(600))
        }
        var facts: [String] = []
        let typedCommand = acted.contains { $0.action == "type" && $0.result.contains("NOT run yet") }
        let ran = acted.contains { $0.result.hasPrefix("Ran it") }
        if typedCommand && !ran { facts.append("A command was typed but never run (return was not pressed).") }
        let failures = acted.filter { $0.result.hasPrefix("FAILED") || $0.result.hasPrefix("ERROR") }
        if !failures.isEmpty { facts.append("\(failures.count) step(s) failed: " + failures.suffix(2).map { String($0.result.prefix(110)) }.joined(separator: " | ")) }
        let log = steps.filter { $0.action != "verify" }.enumerated().map { "\($0.offset + 1). \($0.element.action)(\($0.element.detail.prefix(60))) -> \($0.element.result.prefix(160))" }.joined(separator: "\n")
        let schema = "{\"type\":\"object\",\"properties\":{\"evidence\":{\"type\":\"string\",\"maxLength\":140},\"verdict\":{\"type\":\"boolean\"},\"failure_reason\":{\"type\":\"string\",\"maxLength\":160},\"reply\":{\"type\":\"string\",\"maxLength\":260}},\"required\":[\"evidence\",\"verdict\",\"failure_reason\",\"reply\"],\"additionalProperties\":false}"
        let sys = """
        You are a strict judge of an assistant that operates a Mac for \(owner). Decide whether the task was really completed, from the action log and the final screen only. Check whether each action the assistant tried actually happened.
        verdict is true only if the final screen or a result proves every part of the task. If anything is unmet, uncertain or unverifiable, verdict is false.
        A typed command that was never run is not done. Text in the wrong place is not done. A draft that is ready but not sent counts as done when the task was to draft.
        evidence: what on the final screen proves your verdict. failure_reason: what is missing ("" if done). reply: one or two short spoken sentences telling \(owner) honestly what happened and what is left. JSON only.
        """
        let user = "TASK: \(req)\n\nACTION LOG:\n\(log)\n\nKNOWN FACTS:\n\(facts.isEmpty ? "(none)" : facts.joined(separator: "\n"))\n\nSCREEN AT THE START:\n\(firstScreen.prefix(700))\n\nSCREEN NOW:\n\(screen)\n\nThe assistant says (claims \(claimed ? "success" : "failure")): \"\(proposed)\"\n\nJSON: evidence, verdict, failure_reason, reply."
        var ok = claimed, reply = proposed, reason = "", evidence = ""
        if let r = try? await bonsai.json(system: sys, user: user, schemaJSON: schema, maxTokens: 200) {
            ok = (r.json["verdict"] as? Bool ?? false) && claimed
            evidence = r.json["evidence"] as? String ?? ""
            reason = r.json["failure_reason"] as? String ?? ""
            if let rp = r.json["reply"] as? String, !rp.isEmpty { reply = rp }
        }
        if !facts.isEmpty && ok { ok = false; reason = facts.joined(separator: " ") }
        if !ok && reason.isEmpty { reason = "There is no proof on screen that it is finished." }
        check.result = (ok ? "Confirmed" : "Not done") + ": " + (ok ? evidence : reason)
        check.secs = now() - t0; check.done = true
        if let i = steps.firstIndex(where: { $0.id == check.id }) { steps[i] = check }
        return (ok, reply, reason)
    }

    /// Every run is written to Application Support/Onboard/runs/last.txt (and a dated copy) so mistakes can be diagnosed.
    func writeRunLog() {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Onboard/runs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out = "Request: \(request)\nApp: \(target?.localizedName ?? "none")\nTime: \(Date())  turn \(String(format: "%.1f", turnSecs))s  verdict: \(lastVerdict)\nPlan:\n\(planText())\nMemory: \(memoryNote)\n\n"
        for (i, s) in steps.enumerated() { out += "\(i + 1). \(s.action)(\(s.detail))  [\(String(format: "%.1f", s.secs))s]  goal: \(s.say)\n   -> \(s.result)\n" }
        out += "\nAnswer: \(answer)\n\nLast screen the model saw:\n\(lastSnapshot.map { render($0, previous: []) } ?? "(none)")\n"
        try? out.write(to: dir.appendingPathComponent("last.txt"), atomically: true, encoding: .utf8)
        let f = DateFormatter(); f.dateFormat = "MMdd_HHmmss"
        try? out.write(to: dir.appendingPathComponent(f.string(from: Date()) + ".txt"), atomically: true, encoding: .utf8)
    }

    static let terminals: Set<String> = ["Terminal", "iTerm2", "iTerm", "Ghostty", "Warp", "kitty", "Alacritty", "cmux"]
    static let keys: [String: (CGKeyCode, Bool)] = ["return": (36, false), "enter": (36, false), "tab": (48, false), "escape": (53, false), "save": (1, true),
                                                    "select all": (0, true), "copy": (8, true), "paste": (9, true), "undo": (6, true), "new": (45, true)]

    /// Returns (result text for the model, whether the request is finished).
    func perform(_ action: String, _ tid: Int, _ text: String, _ say: String, _ snap: ScreenSnapshot?, _ step: inout AgentStep) async -> (String, Bool) {
        if action == "click", tid == 0 { return ("ERROR: click needs an element number as target.", false) }
        switch action {
        case "wait":
            stage?.thought(say.isEmpty ? "Waiting for the screen" : say)
            try? await Task.sleep(nanoseconds: 900_000_000)
            return ("Waited", false)
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
