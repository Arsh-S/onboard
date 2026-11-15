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

    static let actions = ["click", "type", "key", "menu", "scroll", "open_app", "wait", "look", "replace_selection", "list_files", "move_files", "search_memory", "add_reminder", "add_event", "point", "done"]
    static let capped = ["look", "search_memory", "list_files"]
    static let changing: Set<String> = ["type", "click", "menu", "key", "open_app", "scroll", "replace_selection"]

    var system: String {
        """
        You are Onboard. You operate \(owner)'s Mac for them, offline. You see the app in front as a list of elements and act one step at a time.

        Elements: "[12] button "Save"" can be acted on by its number. NEW SINCE LAST STEP lists the elements that appeared after your last step (your action caused them: check whether you need them). Lines starting with - are text on screen: use them to verify outcomes. "[40] seen "Play"" is text read from a picture of the window (the app exposes no controls): click it by number like any other element.

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
        - key: press a key. text = return, tab, escape, save, select all, copy, paste, undo, new or new tab.
        - menu: choose a menu bar command by name. text = for example "New Window".
        - scroll: text = down or up. Reveals more elements.
        - open_app: text = the app name.
        - wait: the screen is still loading.
        - look: look at a picture of the window and answer a question about it. text = the question. For images, charts, error dialogs, colors and layout that the element list does not describe.
        - replace_selection: replace the text \(owner) has selected (shown as SELECTED TEXT) with new text. text = the complete rewritten text, nothing else. For "rewrite this", "make this shorter", "fix the grammar", "translate this".
        - list_files: list files in a folder. text = folder | kind, for example "Downloads | pdf".
        - move_files: move files into a folder (it is created if needed). text = source folder | kind | destination folder, for example "Downloads | pdf | Receipts".
        - search_memory: look in \(owner)'s notes, manuals and files on this Mac. text = search words.
        - add_reminder: text = title | when.    - add_event: text = title | when.
        - point: show \(owner) where element target is. text = one sentence of guidance. Ends the task. For "where is" and "how do I" questions.
        - done: finish. text = what to tell \(owner), one or two short spoken sentences. Set success honestly.

        Rules:
        1. Only use element numbers that are in the list. One action per step.
        2. Never assume an action succeeded just because you issued it. Check CHANGES and the screen first.
        3. If you typed into a field, you may still need to pick a suggestion, press return, or click a button to complete it.
        4. Handle popups, dialogs and suggestion lists before anything else.
        5. If LAST RESULT starts with FAILED or ERROR, your step did not happen: prev_result is failed. Read what it says and do something different. Never repeat a failed action.
        6. Never send, submit, pay or delete for \(owner). Leave drafts ready and say so. A typed terminal command has not run until return is pressed.
        7. Never invent facts: use search_memory or the screen. For a question about facts, search_memory, then done with the answer.
        8. If any part of the request is unmet, uncertain or unverifiable, done must have success false and say what is left. If the request is missing something you need (what to remind about, who to message, what to write), do not fill it in: use done with success false and ask for it.
        9. Use the most direct action. To add text to a document, type into its text area: no clicking, selecting or cursor positioning first. For reminders and calendar events use add_reminder and add_event directly: never open those apps. To list or move files use list_files and move_files directly: never the terminal or Finder. To rewrite SELECTED TEXT use replace_selection.
        11. "Tell", "ask" or "message" this chat, this session, this assistant or this terminal means: type those words into the app in front, then press return. You are passing a message on: type only the message itself, worded as \(owner) would say it to them, without "can you tell this session to". Do not look for settings, search memory, or try to do what the message says yourself.
        10. Only write values you have actually read. When a task needs a number, name or fact from the app in front, find it on screen first and copy it into memory BEFORE you open another app. Never guess a value.

        Examples (one step each):
        TASK: add a line that says Pump A checked. ELEMENTS: [3] field "(unnamed field)" = "Log..."
        {"prev_result":"none","memory":"Need to add one line to the open document.","next_goal":"Type the line into the document text area","action":"type","target":3,"target_label":"(unnamed field)","text":"Pump A checked","success":false}
        Next step, after CHANGES shows the value now ends with Pump A checked:
        {"prev_result":"success","memory":"The line Pump A checked is in the document.","next_goal":"Report that it is done","action":"done","target":0,"target_label":"","text":"I added the line Pump A checked to your document.","success":true}
        TASK: remind me to call Sam tomorrow at 9.
        {"prev_result":"none","memory":"A reminder is needed.","next_goal":"Add the reminder","action":"add_reminder","target":0,"target_label":"","text":"Call Sam | tomorrow 9am","success":false}
        TASK: add lunch with Maya to my calendar on Friday at noon. (never open a calendar app: add_event does it)
        {"prev_result":"none","memory":"A calendar event is needed.","next_goal":"Add the event","action":"add_event","target":0,"target_label":"","text":"Lunch with Maya | Friday 12pm","success":false}
        TASK: can you tell this session to also make the font bigger? ELEMENTS: [2] field "Terminal content area" (pass the message on: type it, do not do it)
        {"prev_result":"none","memory":"Pass the message to the session in front.","next_goal":"Type the message into the session's text area","action":"type","target":2,"target_label":"Terminal content area","text":"Also make the font bigger","success":false}
        TASK: what does the manual say about filter changes?
        {"prev_result":"none","memory":"Need the filter procedure from the notes.","next_goal":"Search the notes","action":"search_memory","target":0,"target_label":"","text":"filter change procedure","success":false}
        TASK: what does this document say? (the answer is already on screen)
        {"prev_result":"none","memory":"The document text is visible.","next_goal":"Answer from the screen","action":"done","target":0,"target_label":"","text":"It says the pump was checked on Sol 211 and pressure is nominal.","success":true}
        TASK: how do I make this bold? (a question about how: explain or point, do not do it)
        {"prev_result":"none","memory":"The user wants to know how, not for me to do it.","next_goal":"Explain where Bold is","action":"done","target":0,"target_label":"","text":"Select the text, then open the Format menu, choose Font, and pick Bold.","success":true}
        TASK: text Maya that I'm late. After typing Maya in the To field: NEW SINCE LAST STEP: [12] row "Maya Chen"
        {"prev_result":"success","memory":"Messages is open, new message started, typed Maya; a suggestion appeared.","next_goal":"Pick Maya Chen from the suggestions","action":"click","target":12,"target_label":"Maya Chen","text":"","success":false}
        TASK: make this sound more professional. SELECTED TEXT: "hey can u send me the numbers asap"
        {"prev_result":"none","memory":"Rewrite the selected text in place.","next_goal":"Replace the selection with a professional version","action":"replace_selection","target":0,"target_label":"","text":"Hello, could you please send me the numbers as soon as possible?","success":false}
        TASK: what is wrong in this chart? (the element list does not describe the chart)
        {"prev_result":"none","memory":"Need to see the chart itself.","next_goal":"Look at the window","action":"look","target":0,"target_label":"","text":"What does the chart show and what looks wrong in it?","success":false}
        TASK: put the screenshots on my desktop into a folder called Shots.
        {"prev_result":"none","memory":"Move screenshots from Desktop into Shots.","next_goal":"Move the files","action":"move_files","target":0,"target_label":"","text":"Desktop | screenshot | Shots","success":false}
        JSON only.
        """
    }

    private var selected = ""
    private var startSelection = ""
    /// Everything the model has been shown in this run (screens, results, the request). Values it writes must come from here.
    private var shown = ""
    private var challenged: Set<String> = []
    /// What the model has read so far (from looks, memory and file listings), kept by the harness so it survives app switches.
    private var findings: [String] = []

    /// Numbers in text the model wants to write that it was never shown: the mark of an invented value.
    func ungrounded(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\d+(?:[.,:]\d+)*"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }.filter { $0.count > 1 && !shown.contains($0) }
    }
    private var selectionHolder: AXUIElement?

    /// Does the request itself name a time? If not, a due time from the model ("tomorrow 9am") is a guess and is dropped.
    var requestNamesATime: Bool {
        let l = request.lowercased()
        if l.contains(where: \.isNumber) { return true }
        let words = Set(l.split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["today", "tonight", "tomorrow", "morning", "afternoon", "evening", "night", "noon", "midnight", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                                        "week", "weekend", "month", "next", "later", "hour", "hours", "minute", "minutes", "am", "pm", "oclock", "soon", "now"])
    }

    /// Words of a reminder or event that appear nowhere in the request, on a screen, or in a result: the small model
    /// fills a request that names nothing ("remind me") with the example from its instructions.
    func inventedWords(_ text: String) -> (unknown: [String], total: Int) {
        let filler: Set<String> = ["remind", "reminder", "the", "and", "for", "with", "about", "that", "this", "event", "add", "set", "new"]
        // Only the request and the selected text count here, not the screen: with a document or a chat in front,
        // almost any words are "on screen" (a script that mentions a dentist turned "remind me" into a dentist reminder).
        let seen = (request + " " + startSelection).lowercased()
        let words = text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 && !filler.contains($0) }
        return (words.filter { !seen.contains($0) }, words.count)
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
        trail.isEmpty ? "(none)" : trail.enumerated().map { "\($0.offset + 1). \($0.element.goal) -> \($0.element.action) -> \($0.element.result.prefix(110))" }.joined(separator: "\n")
    }

    /// Screenshots as a backup sense: text read from a picture when an app exposes almost nothing, and a picture for the final check.
    public var useEyes = true

    /// The screen as the model gets it: the accessibility tree, plus text read from a picture of the window when the tree is nearly empty.
    func look(_ app: NSRunningApplication?, menusFrom old: ScreenSnapshot? = nil) async -> ScreenSnapshot? {
        guard let app, let snap = Screen.snapshot(app, menusFrom: old) else { return nil }
        // Nearly empty, or controls with nothing to read (a spreadsheet grid, a canvas): read the words from a picture.
        let readable = snap.elements.reduce(0) { $0 + ($1.role == "text" ? $1.label.count : $1.value.count) }
        guard useEyes, snap.elements.count < 10 || readable < 80, let img = await Eyes.capture(pid: snap.pid, windowFrame: snap.windowFrame) else { return snap }
        return snap.adding(seen: Eyes.readText(img, windowFrame: snap.windowFrame))
    }

    /// Elements as the model sees them, with * on the ones that were not there at the last step.
    func render(_ snap: ScreenSnapshot, previous: Set<String>) -> String {
        var out = ""
        let named = snap.elements.filter { $0.id > 0 && $0.role != "seen" }.prefix(snap.seen ? 40 : 70)
        for e in named + snap.elements.filter({ $0.role == "seen" }).prefix(60) {
            let isNew = !previous.isEmpty && !previous.contains(e.role + "|" + e.label)
            out += "\(isNew ? "*" : "")[\(e.id)] \(e.role) \"\(e.label.prefix(60))\"" + (e.value.isEmpty ? "" : " = \"\(e.value.count > 150 ? e.value.prefix(50) + " … " + e.value.suffix(90) : e.value)\"") + "\n"      // the end of a field is where typing lands
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

    /// "Can you ask this Claude Code session what else I can demo?" -> "What else can I demo?": the words to pass on
    /// when the request is to tell, ask or message the chat, session or assistant in front. nil for anything else.
    nonisolated public static func relayMessage(_ request: String) -> String? {
        let pattern = #"^\W*(?:(?:hey|ok|okay|so)\W+)?(?:on[\s-]?board\W+)?(?:(?:can|could|would|will) you (?:please |just |also )?|please )?(?:ask|tell|message|say to|type (?:in|into|to)|send) (?:this|the|my|that|our) (?:[\w-]+ ){0,3}?(?:session|chat|assistant|terminal|window|agent|bot|conversation|claude code|claude|codex|cursor|chatgpt|copilot)(?: session| chat| window)?\b[\s,:]*"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)), let r = Range(m.range, in: request) else { return nil }
        var msg = request[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["to ", "that ", "if it can ", "whether it can "] where msg.lowercased().hasPrefix(lead) { msg = String(msg.dropFirst(lead.count)); break }
        // "what else I can ask" -> "what else can I ask"
        if let q = try? NSRegularExpression(pattern: #"^((?:what|which|how|where|when|why|who)(?: else| many| much| kind of \w+| \w+)??) (I|we|you|it|they) (can|could|should|would|will|do|did|does|is|are|was|were|have|has)\b"#, options: [.caseInsensitive]) {
            msg = q.stringByReplacingMatches(in: msg, range: NSRange(msg.startIndex..., in: msg), withTemplate: "$1 $3 $2")
        }
        // "where the logs are" -> "where are the logs"
        if let q = try? NSRegularExpression(pattern: #"^(where|what|who|how|when|why) (?!is |are |was |were |can |could |should |do |does |did |will |would )(.+?) (is|are|was|were)[.?!]*$"#, options: [.caseInsensitive]) {
            msg = q.stringByReplacingMatches(in: msg, range: NSRange(msg.startIndex..., in: msg), withTemplate: "$1 $3 $2")
        }
        guard msg.split(separator: " ").count >= 2 else { return nil }
        msg = msg.prefix(1).uppercased() + msg.dropFirst()
        // The mark belongs to the message, not to "can you ask...?".
        while let last = msg.last, ".?!".contains(last) { msg.removeLast() }
        let first = msg.split(separator: " ").first.map { $0.lowercased() } ?? ""
        msg += ["what", "which", "how", "where", "when", "why", "who", "can", "could", "is", "are", "do", "does", "will", "would", "should"].contains(first) ? "?" : "."
        return msg
    }

    /// A plainly worded reminder or calendar request, taken apart without the model: (is it an event, title, time phrase).
    /// "Add lunch with Jared to my calendar Friday at noon" -> (true, "Lunch with Jared", "Friday at noon").
    /// An empty title means the request named nothing to remember. nil means it is not one of these.
    nonisolated public static func quickEntry(_ request: String) -> (event: Bool, title: String, when: String)? {
        let lead = #"^\W*(?:(?:hey|ok|okay|so)\W+)?(?:on[\s-]?board\W+)?(?:(?:can|could|would|will) you (?:please )?|please )?"#
        func groups(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: lead + pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: request).map { String(request[$0]) } ?? "" }
        }
        var event = false, body = ""
        if let g = groups(#"(?:add|put|schedule|create|book|set up)\s+(?:an?\s+)?(?:event\s+|meeting\s+)?(?:for\s+|called\s+)?(.+?)\s+(?:to|on|in|into)\s+(?:my\s+|the\s+)?calendar\b(.*)$"#) { event = true; body = g[0] + " " + g[1] }
        else if let g = groups(#"(?:remind me|set (?:me )?a reminder|add a reminder|make a reminder)\b(?:\s+(?:to|about|that|for))?\s*(.*)$"#) { body = g[0] }
        else { return nil }
        let when = Tools.timePhrase(in: body) ?? ""
        // A time the detector could not read ("at 5"): leave the request to the model rather than drop the time.
        if when.isEmpty, body.range(of: #"\b(?:at|by|around)\s+\d"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        var title = when.isEmpty ? body : body.replacingOccurrences(of: when, with: " ")
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " .,?!"))
        for _ in 0..<3 { for tail in [" at", " on", " by", " for", " in", " this", " next", " to"] where title.lowercased().hasSuffix(tail) { title = String(title.dropLast(tail.count)) } }
        for head in ["to ", "about ", "that "] where title.lowercased().hasPrefix(head) { title = String(title.dropFirst(head.count)) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .,?!"))
        return (event, title.prefix(1).uppercased() + title.dropFirst(), when)
    }

    /// "Text Jared hi", "message Maya saying I'm running late", "send a text to Sam that dinner is at 7":
    /// (who, what). nil when it is not a request to text a person.
    nonisolated public static func textRequest(_ request: String) -> (to: String, body: String)? {
        let pattern = #"^\W*(?:(?:hey|ok|okay|so)\W+)?(?:on[\s-]?board\W+)?(?:(?:can|could|would|will) you (?:please )?|please )?(?:(?:send|write|draft|shoot) (?:an? )?(?:text|message|imessage)(?: message)? to|text|message|imessage)\s+(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)), let r = Range(m.range(at: 1), in: request) else { return nil }
        let rest = String(request[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        // "this chat", "the assistant": that is passing a message to an app, handled elsewhere.
        if rest.range(of: #"^(this|the|that|my|our|it|them|him|her)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        var to = "", body = ""
        if let sep = rest.range(of: #"\s*(?:,|:|\bsaying\b|\bthat says\b|\band say\b|\band tell (?:him|her|them)\b|\bto say\b|\bthat\b)\s*"#, options: [.regularExpression, .caseInsensitive]) {
            to = String(rest[..<sep.lowerBound]); body = String(rest[sep.upperBound...])
        } else {
            // No joining word: the first word is the name, unless the second is also capitalized ("Jared Smith hi").
            let words = rest.split(separator: " ").map(String.init)
            guard words.count >= 2 else { return nil }
            let two = words.count >= 3 && words[1].first?.isUppercase == true && words[1].count > 2 && !["Hi", "Hey", "Hello", "Yo", "Sup", "Can", "Are", "The", "That", "What", "Where", "When", "How"].contains(words[1])
            to = words.prefix(two ? 2 : 1).joined(separator: " "); body = words.dropFirst(two ? 2 : 1).joined(separator: " ")
        }
        to = to.trimmingCharacters(in: CharacterSet(charactersIn: " .,")); body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, to.split(separator: " ").count <= 3, !body.isEmpty else { return nil }
        // "..., but don't send it" is an instruction to Onboard, not part of the message (it never sends anyway).
        body = body.replacingOccurrences(of: #"[,.]?\s*(?:but |and )?(?:do not|don't|dont) (?:send|text)(?: it| that| yet)?[.!]?\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        if body.count >= 2, body.last == ".", body.split(separator: " ").count <= 3 { body.removeLast() }      // "Hi." -> "Hi"
        guard !body.isEmpty else { return nil }
        return (to, body.prefix(1).uppercased() + body.dropFirst())
    }

    /// "Turn the WiFi off", "switch wifi on", "disable Wi-Fi": true for on, false for off, nil for anything else.
    nonisolated public static func wifiRequest(_ request: String) -> Bool? {
        let l = request.lowercased()
        guard l.range(of: #"\bwi[\s-]?fi\b"#, options: .regularExpression) != nil, l.split(separator: " ").count <= 9 else { return nil }
        if l.range(of: #"\b(turn|switch|shut|put)\b.*\boff\b|\b(disable|kill|disconnect)\b"#, options: .regularExpression) != nil { return false }
        if l.range(of: #"\b(turn|switch|put)\b.*\bon\b|\b(enable|reconnect)\b|\bback on\b"#, options: .regularExpression) != nil { return true }
        return nil
    }

    /// Texting a person, done on screen the way a person would do it: open Messages, start a new message, type the
    /// name, pick the contact, type the text. Return is never pressed, so nothing is ever sent.
    func textVisibly(to: String, body: String) async {
        func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func begin(_ action: String, _ detail: String, _ say: String) -> (Int, Double) {
            steps.append(AgentStep(action: action, detail: detail, say: say)); stage?.thought(say); return (steps.count - 1, now())
        }
        func end(_ h: (Int, Double), _ result: String) { steps[h.0].result = result; steps[h.0].secs = now() - h.1; steps[h.0].done = true }
        func stop(_ why: String) async { lastVerdict = "not_done"; answer = cancelled ? "Stopped." : why; if !cancelled { await stage?.speak(answer) } }
        let textRoles = ["AXTextField", "AXComboBox", "AXSearchField", "AXTextArea"]

        // 1. Open Messages.
        var h = begin("open_app", "Messages", "Opening Messages")
        guard let app = await Screen.open("Messages"), await Screen.bringForward(app) else { end(h, "FAILED: Messages did not open"); await stop("I couldn't open Messages."); return }
        target = app
        await pause(0.6)
        end(h, "Messages is open and in front")
        guard !cancelled, var snap = Screen.snapshot(app) else { await stop("I couldn't read the Messages window."); return }
        lastSnapshot = snap
        await stage?.scan(window: snap.windowFrame, elements: snap.elements.filter { $0.role != "text" })

        // 2. Start a new message from the menu bar.
        h = begin("menu", "New Message", "Starting a new message")
        if let path = Screen.findMenu(snap, "New Message") {
            let top = path.components(separatedBy: " > ").first ?? ""
            let tf = snap.menuTitleFrames[top]
            let bar = tf.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: snap.windowFrame.minX + 160, y: 12)
            steps[h.0].detail = path; steps[h.0].frame = tf; steps[h.0].point = bar
            await stage?.glide(to: bar, frame: nil, thought: "Starting a new message")
            await stage?.click(at: bar)
            _ = Screen.pressMenu(snap, path: path)
        } else { Screen.key(45, command: true) }                      // Command-N does the same
        await pause(0.9)
        end(h, "A new message is started")
        guard !cancelled else { await stop(""); return }

        // 3. Type the name into the To field.
        h = begin("type", "To: · \(to)", "Typing \(to) in the To field")
        snap = Screen.snapshot(app, menusFrom: snap) ?? snap
        func isTo(_ e: UIElement) -> Bool { let l = e.label.lowercased(); return e.role == "field" && (l.hasPrefix("to") || l.contains("recipient")) }
        guard let field = snap.elements.first(where: isTo) else { end(h, "FAILED: there is no To field"); await stop("Messages is open, but I couldn't find the To field."); return }
        let fp = CGPoint(x: field.frame.minX + min(90, field.frame.width / 2), y: field.frame.midY)
        steps[h.0].frame = field.frame; steps[h.0].point = fp
        await stage?.glide(to: fp, frame: field.frame, thought: "Typing \(to)")
        await stage?.click(at: fp)
        Screen.click(at: fp)
        await pause(0.35)
        guard textRoles.contains(Screen.focusedRole(app)) else { end(h, "FAILED: the To field did not take the keyboard"); await stop("I opened a new message but couldn't get into the To field."); return }
        Screen.type(to)
        await pause(1.4)
        end(h, "Typed \(to)")
        guard !cancelled else { await stop(""); return }

        // 4. Pick the contact from the suggestions that appeared.
        h = begin("click", to, "Choosing \(to) from the suggestions")
        let known = Self.keys(of: snap)
        let suggest = Screen.snapshot(app, menusFrom: snap) ?? snap
        let first = to.lowercased().split(separator: " ").first.map(String.init) ?? to.lowercased()
        var chosen = to
        if let row = suggest.elements.first(where: { $0.id > 0 && $0.role != "field" && $0.label.lowercased().contains(first) && !known.contains($0.role + "|" + $0.label) && $0.frame.width > 20 }) {
            let rp = CGPoint(x: row.frame.midX, y: row.frame.midY)
            steps[h.0].detail = String(row.label.prefix(50)); steps[h.0].frame = row.frame; steps[h.0].point = rp
            await stage?.glide(to: rp, frame: row.frame, thought: "Choosing \(row.label.prefix(30))")
            await stage?.click(at: rp)
            Screen.click(at: rp)
            await pause(0.7)
            chosen = String(row.label.prefix(40))
            end(h, "Chose \(chosen)")
        } else { end(h, "No suggestion appeared, so \(to) stays as typed") }
        guard !cancelled else { await stop(""); return }

        // 5. Type the message. It stays in the box: return is never pressed.
        h = begin("type", String(body.prefix(60)), "Typing the message")
        let compose = Screen.snapshot(app, menusFrom: snap) ?? suggest
        let box = compose.elements.filter { $0.role == "field" && !isTo($0) && !$0.label.lowercased().contains("search") }.max { $0.frame.midY < $1.frame.midY }      // the lowest text box
        guard let box else { end(h, "FAILED: there is no message box"); await stop("I addressed the message to \(chosen) but couldn't find where to type it."); return }
        let bp = CGPoint(x: box.frame.minX + min(90, box.frame.width / 2), y: box.frame.midY)
        steps[h.0].frame = box.frame; steps[h.0].point = bp
        await stage?.glide(to: bp, frame: box.frame, thought: "Typing the message")
        await stage?.click(at: bp)
        Screen.click(at: bp)
        await pause(0.35)
        guard textRoles.contains(Screen.focusedRole(app)) else { end(h, "FAILED: the message box did not take the keyboard"); await stop("I addressed the message to \(chosen) but couldn't type into the message box."); return }
        let before = Screen.visibleText(app)
        Screen.type(body)
        await pause(0.5)
        let there = Self.appeared(body, before: before, after: Screen.visibleText(app))
        end(h, there ? "Verified: \"\(body.prefix(60))\" is in the message box, not sent" : "Typed the message (it could not be read back)")
        lastSnapshot = Screen.snapshot(app, menusFrom: snap) ?? compose
        lastVerdict = "done"
        answer = "I wrote \"\(body)\" to \(chosen) in Messages. It's ready, not sent."
        await stage?.speak(answer)
    }

    /// Passing a message on needs no thinking: type it into the app in front and press return.
    func relay(_ message: String, snap: ScreenSnapshot?) async {
        var step = AgentStep(action: "type", detail: String(message.prefix(80)), say: "Typing your message")
        steps.append(step)
        let t0 = now()
        let (typed, _) = await perform("type", 0, message, "Typing your message", snap, &step)
        step.result = String(typed.prefix(300)); step.secs = now() - t0; step.done = true; steps[steps.count - 1] = step
        guard !typed.hasPrefix("FAILED"), !typed.hasPrefix("ERROR"), !cancelled else {
            answer = cancelled ? "Stopped." : "I couldn't type that into \(target?.localizedName ?? "the app")."; lastVerdict = "not_done"
            if !cancelled { await stage?.speak(answer) }
            return
        }
        var send = AgentStep(action: "key", detail: "return", say: "Sending it")
        steps.append(send)
        let t1 = now()
        let (sent, _) = await perform("key", 0, "return", "Sending it", lastSnapshot ?? snap, &send)
        send.result = String(sent.prefix(300)); send.secs = now() - t1; send.done = true; steps[steps.count - 1] = send
        let ok = !sent.hasPrefix("FAILED") && !sent.hasPrefix("Not approved")
        lastVerdict = ok ? "done" : "not_done"
        answer = ok ? "Sent." : "I typed it but left it unsent."
        await stage?.speak(answer)
    }

    public func run(_ text: String, app: NSRunningApplication? = nil) async {
        let req = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty, !running else { return }
        running = true; cancelled = false; request = req; steps = []; answer = ""; lastVerdict = ""
        trail = []; memoryNote = ""; lastResult = "(nothing yet)"; consecutiveFailures = 0; blocked = []; judgeRejections = 0
        let t0 = now()
        defer { running = false; turnSecs = now() - t0; stage?.rest(); writeRunLog() }
        target = app ?? Screen.targetApp(excluding: ownBundle)
        let sel = target.flatMap { Screen.selection($0) }
        selected = sel?.text ?? ""; selectionHolder = sel?.holder; startSelection = selected
        shown = req + "\n" + selected; challenged = []; findings = []

        var snap: ScreenSnapshot? = await look(target)
        lastSnapshot = snap
        if let s = snap { await stage?.scan(window: s.windowFrame, elements: s.elements.filter { $0.role != "text" }) }
        firstScreen = snap.map { render($0, previous: []) } ?? "(no window)"
        if let message = Self.relayMessage(req), target != nil { await relay(message, snap: snap); return }
        if let q = Self.quickEntry(req), !(q.event && q.when.isEmpty && !q.title.isEmpty) {
            // Said plainly enough to do directly: no screen reading, no guessing which app to open.
            let what = q.event ? "event" : "reminder"
            if q.title.isEmpty { answer = "What should the \(what) say, and when?"; await stage?.speak(answer); return }
            let step = AgentStep(action: q.event ? "add_event" : "add_reminder", detail: q.title + (q.when.isEmpty ? "" : " · " + q.when), say: q.event ? "Adding to the calendar" : "Adding a reminder")
            steps.append(step); stage?.thought(step.say)
            let r = q.event ? await Tools.addEvent(q.title, when: q.when) : await Tools.addReminder(q.title, when: q.when)
            lastVerdict = "done"
            await summarizeAfter(r); return
        }
        if let t = Self.textRequest(req), Screen.allowForeground { await textVisibly(to: t.to, body: t.body); return }
        if let t = Self.textRequest(req) {
            // Headless checks cannot drive the real Messages window: there the draft is opened directly.
            var step = AgentStep(action: "draft_message", detail: "\(t.to) · \(t.body.prefix(60))", say: "Drafting a message to \(t.to)")
            steps.append(step); stage?.thought(step.say)
            let t0 = now()
            let (r, _) = await perform("draft_message", 0, "\(t.to) | \(t.body)", step.say, snap, &step)
            steps[steps.count - 1].secs = now() - t0; steps[steps.count - 1].done = true
            lastVerdict = r.hasPrefix("Not approved") ? "" : "done"
            return
        }
        if let on = Self.wifiRequest(req) {
            var step = AgentStep(action: "wifi", detail: on ? "on" : "off", say: "Turning WiFi \(on ? "on" : "off")")
            steps.append(step); stage?.thought(step.say)
            let t0 = now()
            let r = Tools.setWifi(on)
            step.result = r; step.secs = now() - t0; step.done = true; steps[steps.count - 1] = step
            lastVerdict = r.hasPrefix("FAILED") ? "not_done" : "done"
            answer = r.hasPrefix("FAILED") ? "I couldn't change the WiFi setting." : r
            await stage?.speak(answer); return
        }
        await makePlan(req, screen: snap.map { "\($0.app), window \"\($0.window)\"" } ?? "nothing")
        var previousKeys: Set<String> = []
        var stale = 0

        for stepNo in 1...maxSteps {
            if cancelled { answer = "Stopped."; return }
            // Follow the screen: a different app in front (opened by a step, or by the user) becomes the one we work in.
            if Screen.allowForeground, let f = Screen.targetApp(excluding: ownBundle), f.processIdentifier != target?.processIdentifier, stepNo > 1 { target = f }
            let before = snap
            snap = await look(target, menusFrom: lastSnapshot)
            lastSnapshot = snap
            let diff = stepNo == 1 ? "CHANGES: (first step)" : Self.changes(before, snap)
            stale = diff == "CHANGES: none" ? stale + 1 : 0

            let ids = [0] + (snap?.elements.filter { $0.id > 0 }.map(\.id) ?? [])
            let lastStep = stepNo == maxSteps || consecutiveFailures >= 5
            // Looking and searching are capped: a small model that is unsure keeps doing them instead of acting.
            let spent = Self.capped.filter { a in steps.filter { $0.action == a }.count >= 2 }
            let allowed = lastStep ? ["done"] : Self.actions.filter { ($0 != "replace_selection" || !selected.isEmpty) && !spent.contains($0) }
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
            if !spent.isEmpty { notes.append("\(spent.joined(separator: " and ")) cannot be used again in this task: you have what they can give. Act on the app in front, or use done and say what you could not find.") }
            if lastStep { notes.append("This is the last step. Use done and report honestly what was and was not achieved.") }
            let hints = snap.map { Screen.menuHints($0, for: req) } ?? []
            let fresh = previousKeys.isEmpty ? [] : (snap?.elements ?? []).filter { $0.id > 0 && !previousKeys.contains($0.role + "|" + $0.label) }
            // Order matters for speed: the model server only skips re-reading a prompt up to the point where it differs
            // from the last one. So everything that stays the same while the screen does (task, selection, findings,
            // the element list) comes first, and what changes every step (memory, last result, changes) comes last.
            let user = """
            TASK: \(req)\(plan.isEmpty ? "" : "\nPLAN:\n" + planText())\(selected.isEmpty ? "" : "\nSELECTED TEXT: \"" + selected.prefix(900) + "\"")\(findings.isEmpty ? "" : "\nFOUND SO FAR (real values you have read, use these):\n" + findings.map { "- " + $0 }.joined(separator: "\n"))
            APP: \(snap?.app ?? "none"). WINDOW: "\(snap?.window ?? "")"
            ELEMENTS:
            \(snap.map { render($0, previous: []) } ?? "(no window is open)")
            Menu commands that may help: \(hints.isEmpty ? "(none)" : hints.prefix(10).joined(separator: "; "))

            TASK (again): \(req.prefix(300))
            MEMORY: \(memoryNote.isEmpty ? "(empty)" : memoryNote)
            LAST STEPS:
            \(history())
            LAST RESULT: \(lastResult)
            \(diff)\(fresh.isEmpty ? "" : "\nNEW SINCE LAST STEP: " + fresh.prefix(8).map { "[\($0.id)] \($0.role) \"\($0.label.prefix(40))\"" }.joined(separator: "; "))
            \(notes.joined(separator: "\n"))
            Time: \(Date().formatted(date: .abbreviated, time: .shortened)). Step \(stepNo) of \(maxSteps).
            """
            previousKeys = Self.keys(of: snap)
            // What counts as "seen": the screen and the clock. Not the step history, which repeats the model's own words
            // (an invented value quoted back in an error would otherwise pass as seen on the next try).
            shown += "\n" + (snap.map { "\($0.app) \($0.window)\n" + render($0, previous: []) } ?? "") + "\n" + Date().formatted(date: .complete, time: .shortened)

            guard let r = try? await bonsai.json(system: system, user: user, schemaJSON: schema, maxTokens: 260) else {
                answer = "I can't reach Bonsai. Is LM Studio running?"; await stage?.speak(answer); return
            }
            promptTokens = r.promptTokens
            if cancelled { answer = "Stopped."; return }      // stopped while the model was thinking: do not act on its reply
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
                lastResult = "ERROR: \(signature) is blocked: it already failed or did nothing. Nothing was done. Choose a different action or element."
                trail.append(Trail(goal: goal, action: signature, result: lastResult)); if trail.count > 3 { trail.removeFirst() }
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
            let after = await look(Screen.allowForeground ? (Screen.targetApp(excluding: ownBundle) ?? target) : target, menusFrom: snap)
            let effect = Self.changes(snap, after)
            let failed = result.hasPrefix("FAILED") || result.hasPrefix("ERROR")
            if Self.capped.contains(action) { blocked.insert(signature) }      // asking the same thing again gives the same answer
            if failed {
                // A failed step is not tried again as is: at once for actions that fail the same way every time (a menu
                // command or app that does not exist), on the second identical failure for the rest.
                if ["menu", "open_app", "key", "click", "scroll"].contains(action) || trail.last?.action == signature { blocked.insert(signature) }
            }
            if Self.changing.contains(action) {
                if failed { consecutiveFailures += 1 }
                else if effect == "CHANGES: none" && !result.hasPrefix("Verified") {
                    consecutiveFailures += 1
                    result += " But nothing changed on screen."
                    if trail.last?.action == signature { blocked.insert(signature) }
                } else { consecutiveFailures = 0 }
            } else if failed { consecutiveFailures += 1 } else { consecutiveFailures = 0 }
            lastResult = (failed ? "" : "OK ") + result.prefix(700)
            if !failed, ["look", "search_memory", "list_files", "key", "list_apps", "show_menu"].contains(action) { shown += "\n" + result }   // real output: file names, notes, what a terminal printed
            if !failed, ["look", "search_memory", "list_files"].contains(action) { findings.append("\(action) \"\(txt.prefix(50))\": \(result.prefix(260))"); if findings.count > 4 { findings.removeFirst() } }
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
        var picture: Data?
        if let app = Screen.allowForeground ? (Screen.targetApp(excluding: ownBundle) ?? target) : target, let snap = await look(app, menusFrom: lastSnapshot) {
            // A picture is the check for steps nothing else confirmed. Steps the harness already verified by reading the text back need no second look.
            let unproven = acted.contains { !$0.result.hasPrefix("Verified") }
            if useEyes, unproven, let img = await Eyes.capture(pid: snap.pid, windowFrame: snap.windowFrame) { picture = Eyes.jpeg(img) }
            await stage?.scan(window: snap.windowFrame, elements: snap.elements.filter { $0.role != "text" })
            screen = "App: \(snap.app). Window: \"\(snap.window)\"\n" + String(render(snap, previous: []).prefix(1500)) + "\nLatest text in the window:\n" + String(Screen.visibleText(app).suffix(600))
        }
        var facts: [String] = []
        let typedCommand = acted.contains { $0.action == "type" && $0.result.contains("NOT run yet") }
        let ran = acted.contains { $0.result.hasPrefix("Ran it") }
        if typedCommand && !ran { facts.append("A command was typed but never run (return was not pressed).") }
        let failures = acted.filter { $0.result.hasPrefix("FAILED") || $0.result.hasPrefix("ERROR") }
        if !failures.isEmpty { facts.append("\(failures.count) step(s) failed: " + failures.suffix(2).map { String($0.result.prefix(110)) }.joined(separator: " | ")) }
        let proven = acted.filter { $0.result.hasPrefix("Verified") }.map { "Confirmed by reading the app's text back: " + String($0.result.dropFirst(10).prefix(150)) }
        if !startSelection.isEmpty { facts.append("The text selected at the start was: \"\(startSelection.prefix(300))\"") }
        let log = steps.filter { $0.action != "verify" }.enumerated().map { "\($0.offset + 1). \($0.element.action)(\($0.element.detail.prefix(60))) -> \($0.element.result.prefix(160))" }.joined(separator: "\n")
        let schema = "{\"type\":\"object\",\"properties\":{\"evidence\":{\"type\":\"string\",\"maxLength\":140},\"verdict\":{\"type\":\"boolean\"},\"failure_reason\":{\"type\":\"string\",\"maxLength\":160},\"reply\":{\"type\":\"string\",\"maxLength\":260}},\"required\":[\"evidence\",\"verdict\",\"failure_reason\",\"reply\"],\"additionalProperties\":false}"
        let sys = """
        You are a strict judge of an assistant that operates a Mac for \(owner). Decide whether the task was really completed, from the action log and the final screen only. Check whether each action the assistant tried actually happened.
        verdict is true only if the final screen or a result proves every part of the task. If anything is unmet, uncertain or unverifiable, verdict is false.
        If the task was to tell, ask or message the chat, session or assistant in front, the task is only to pass the message on: once the message is typed there, it is done. The assistant does not have to do what the message says.
        A typed command that was never run is not done. Text in the wrong place is not done. A draft that is ready but not sent counts as done when the task was to draft.
        \(picture == nil ? "" : "A picture of the window as it looks right now is attached. Look at it: what is visible in the picture outweighs what the log claims.\n        ")evidence: what on the final screen proves your verdict. failure_reason: what is missing ("" if done). reply: one or two short spoken sentences telling \(owner) honestly what happened and what is left. JSON only.
        """
        let user = "TASK: \(req)\n\nACTION LOG:\n\(log)\n\nKNOWN FACTS (these are true):\n\((facts + proven).isEmpty ? "(none)" : (facts + proven).joined(separator: "\n"))\n\nSCREEN AT THE START:\n\(firstScreen.prefix(700))\n\nSCREEN NOW:\n\(screen)\n\nThe assistant says (claims \(claimed ? "success" : "failure")): \"\(proposed)\"\n\nJSON: evidence, verdict, failure_reason, reply."
        var ok = claimed, reply = proposed, reason = "", evidence = ""
        check.detail = picture == nil ? "Re-reading the screen" : "Looking at the screen"
        if let r = try? await bonsai.json(system: sys, user: user, schemaJSON: schema, maxTokens: 200, image: picture) {
            ok = (r.json["verdict"] as? Bool ?? false) && claimed
            evidence = r.json["evidence"] as? String ?? ""
            reason = r.json["failure_reason"] as? String ?? ""
            if let rp = r.json["reply"] as? String, !rp.isEmpty { reply = rp }
        }
        let hard = facts.filter { !$0.hasPrefix("The text selected") }
        if !hard.isEmpty && ok { ok = false; reason = hard.joined(separator: " ") }
        if !ok && reason.isEmpty { reason = "There is no proof on screen that it is finished." }
        // A "not done" verdict never goes out with a reply that sounds like success.
        if !ok, !["not", "n't", "couldn", "unable", "fail", "but ", "however", "still", "left", "instead"].contains(where: { reply.lowercased().contains($0) }) {
            reply = "I couldn't finish that. \(reason)"
        }
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

    static let browsers: Set<String> = ["company.thebrowser.Browser", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox", "com.openai.atlas", "ai.perplexity.comet"]
    static let terminals: Set<String> = ["Terminal", "iTerm2", "iTerm", "Ghostty", "Warp", "kitty", "Alacritty", "cmux"]
    static let keys: [String: (CGKeyCode, Bool)] = ["return": (36, false), "enter": (36, false), "tab": (48, false), "escape": (53, false), "save": (1, true),
                                                    "select all": (0, true), "copy": (8, true), "paste": (9, true), "undo": (6, true), "new": (45, true), "new tab": (17, true)]

    /// Returns (result text for the model, whether the request is finished).
    func perform(_ action: String, _ tid: Int, _ text: String, _ say: String, _ snap: ScreenSnapshot?, _ step: inout AgentStep) async -> (String, Bool) {
        if action == "click", tid == 0 { return ("ERROR: click needs an element number as target. Nothing was clicked.", false) }
        // Grounding: a value that appears nowhere in what the model was shown is challenged once before it is written.
        if action == "type" || action == "replace_selection" {
            let unknown = ungrounded(text)
            if !unknown.isEmpty, !challenged.contains(text) {
                challenged.insert(text)
                return ("ERROR: nothing was written. \(unknown.joined(separator: ", ")) is not in the task, on any screen you have seen, or in a memory result, so it looks invented. Use a value from FOUND SO FAR if it is there. Otherwise go and read the real value first (open the app that has it, or use look). Only if you calculated it yourself from values you read, repeat the same action.", false)
            }
        }
        if action == "add_reminder" || action == "add_event" {
            let what = action == "add_reminder" ? "reminder" : "event"
            // Judged on the title alone: the time may be worked out ("noon" becomes 12pm), the subject may not.
            let (unknown, total) = inventedWords(text.components(separatedBy: "|").first ?? text)
            if total == 0 || unknown.count == total {
                // Nothing in it came from the request: ask instead of guessing.
                answer = "What should the \(what) say, and when?"
                await stage?.speak(answer)
                return ("Asked \(owner) what the \(what) should say", true)
            }
            if unknown.count * 2 > total {
                return ("ERROR: no \(what) was added. \(owner) did not say \(unknown.isEmpty ? "what it is about" : "\"" + unknown.prefix(4).joined(separator: " ") + "\"")\(total == 0 ? "" : ": that was made up"). Use only \(owner)'s own words from the TASK. If the TASK does not say what the \(what) is about or when, do not add anything: use done with success false and ask \(owner) what the \(what) should say.", false)
            }
        }
        switch action {
        case "wait":
            stage?.thought(say.isEmpty ? "Waiting for the screen" : say)
            try? await Task.sleep(nanoseconds: 900_000_000)
            return ("Waited", false)
        case "point":
            guard let el = snap?.element(tid) else { return ("FAILED: there is no element \(tid) on screen.", false) }
            await stage?.glide(to: CGPoint(x: el.frame.midX, y: el.frame.midY), frame: el.frame, thought: el.label)
            answer = text.isEmpty ? "It's right here: \(el.label)." : text
            await stage?.speak(answer)
            return ("Pointed at \(el.label)", true)
        case "click":
            guard let snap, let el = snap.element(tid) else { return ("FAILED: there is no element \(tid) on screen. Nothing was clicked.", false) }
            let p = CGPoint(x: el.frame.midX, y: el.frame.midY)
            await stage?.glide(to: p, frame: el.frame, thought: say.isEmpty ? "Clicking \(el.label)" : say)
            await stage?.click(at: p)
            // Web pages often accept an accessibility press and then do nothing with it. In a browser, click for real.
            var ok = false
            if Screen.allowForeground, let app = target, Self.browsers.contains(app.bundleIdentifier ?? ""), el.frame.width > 2, await Screen.bringForward(app) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                Screen.click(at: p); ok = true
            } else { ok = Screen.press(snap, id: tid) }
            if snap.seen, ok { try? await Task.sleep(nanoseconds: 700_000_000); return ("Clicked \(el.label)", false) }
            var changed = await settle(snap)
            // A link that jumps within the page changes no controls, only where they are.
            if ok, !changed, let t = target {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let now = Screen.snapshot(t, limit: 1500, menusFrom: snap) {
                    let same = now.elements.first { $0.role == el.role && $0.label == el.label }
                    if same == nil || abs(same!.frame.minY - el.frame.minY) > 20 { return ("Verified: clicked \(el.label) and the page moved to that part. If that was the whole request, answer now.", false) }
                    changed = now.signature != snap.signature
                }
            }
            return (!ok ? "FAILED: could not click \(el.label). Try a menu command for the same thing, or a different element." : changed ? "Clicked \(el.label); the screen changed" : "Clicked \(el.label), but nothing visibly changed. It may not have worked.", false)
        case "type":
            guard let app = target else { return ("FAILED: there is no app to type into.", false) }
            let isTerminal = Self.terminals.contains(app.localizedName ?? "")
            let before = Screen.visibleText(app)
            var point: CGPoint?
            var fieldLabel: String?
            if let snap, let fid = (snap.element(tid)?.role == "field" ? tid : Screen.defaultField(snap)), let el = snap.element(fid) {
                fieldLabel = el.label
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
            let afterText = Screen.visibleText(app)
            if !Self.appeared(text, before: before, after: afterText) {
                // The app may simply not expose its text (a GPU-drawn terminal): then read it from a picture instead.
                guard afterText == before, let lines = await pictureText(snap) else {
                    return ("FAILED: the text did not appear in \(app.localizedName ?? "the app"). Do not claim it was typed.", false)
                }
                guard Self.mostlySeen(text, in: lines) else {
                    return ("FAILED: the text is not visible in \(app.localizedName ?? "the app") after typing. Do not claim it was typed, and do not type it again: check where the keyboard focus is.", false)
                }
            }
            if isTerminal { return ("Verified: the command is typed at the prompt but NOT run yet. Use key return to run it.", false) }
            _ = await settle(snap)
            // Say what the field holds now, not just what was typed: text that was already there is easy to miss.
            if let fieldLabel, let now = Screen.snapshot(app, limit: 1500, menusFrom: snap), let f = now.elements.first(where: { $0.role == "field" && $0.label == fieldLabel }),
               !f.value.isEmpty, f.value.count <= 80, f.value != text, f.value.contains(text) {
                return ("Verified: \"\(text.prefix(60))\" was typed, but the field \"\(fieldLabel.prefix(30))\" now reads \"\(f.value)\": it already had other text. If that is not what is wanted, use key select all and type again to replace it.", false)
            }
            return ("Verified: \"\(text.prefix(60))\" was typed. Look at the new screen: pick a suggestion if one appeared, or continue.", false)
        case "menu":
            guard let snap else { return ("FAILED: no app is open.", false) }
            guard let path = Screen.findMenu(snap, text) else {
                let near = Screen.similarMenus(snap, text)
                return ("FAILED: there is no menu command named \"\(text)\". Nothing was chosen. " + (near.isEmpty ? "This app has no menu command like it: use a different action." : "Menu commands that do exist: \(near.joined(separator: "; ")). Use one of these exactly, or a different action."), false)
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
            guard let app = target, let k = Self.keys[name] else { return ("FAILED: unknown key, nothing was pressed. Use one of: return, tab, escape, save, select all, copy, paste, undo, new, new tab", false) }
            stage?.thought(say.isEmpty ? "Pressing \(text)" : say)
            if name == "return" || name == "enter", ["Messages", "Mail", "Slack", "Discord", "WhatsApp"].contains(app.localizedName ?? "") {
                let ok = await stage?.approve("Send this?", detail: "Pressing Return in \(app.localizedName ?? "this app") may send the message.") ?? false
                guard ok else { return ("Not approved: \(owner) did not allow sending. Leave the draft as it is and answer.", false) }
            }
            guard await Screen.bringForward(app) else { return ("FAILED: could not bring the app forward, nothing was pressed.", false) }
            try? await Task.sleep(nanoseconds: 250_000_000)      // being in front is not yet having the keyboard
            let beforeText = Screen.visibleText(app)
            Screen.key(k.0, command: k.1)
            _ = await settle(snap)
            if Self.terminals.contains(app.localizedName ?? "") && (name == "return" || name == "enter") {
                // Read what the terminal printed, so the answer reports the real outcome (errors, a password prompt, output).
                try? await Task.sleep(nanoseconds: 700_000_000)
                var after = Screen.visibleText(app)
                if after.count < 40, let lines = await pictureText(snap) { after = lines.suffix(10).joined(separator: "\n") }      // nothing readable: use the picture
                let new = after.count > beforeText.count ? String(after.suffix(after.count - beforeText.count + 80)) : String(after.suffix(300))
                let tail = new.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(8).joined(separator: " / ")
                return ("Ran it. The terminal now shows: \(tail.suffix(500)). Report exactly this outcome: if it shows Password:, say it is waiting for \(owner)'s password; if it shows an error, say so.", false)
            }
            return ("Pressed \(name)", false)
        case "open_app":
            stage?.thought(say.isEmpty ? "Opening \(text)" : say)
            // Headless checks never show anything: the app starts hidden and becomes the one we work in.
            if !Screen.allowForeground {
                guard let a = await Screen.openHidden(text) else { return ("FAILED: there is no app named \(text).", false) }
                target = a
                return ("\(a.localizedName ?? text) is open and in front", false)
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
        case "look":
            stage?.thought(say.isEmpty ? "Looking at the screen" : say)
            guard let snap, let img = await Eyes.capture(pid: snap.pid, windowFrame: snap.windowFrame), let pic = Eyes.jpeg(img) else {
                return ("FAILED: I cannot take a picture of the window (Screen Recording permission is off). Answer from the element list only.", false)
            }
            await stage?.scan(window: snap.windowFrame, elements: [])
            let schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}"
            let q = text.isEmpty ? request : text
            guard let r = try? await bonsai.json(system: "You are Onboard, looking at a picture of the \(snap.app) window on \(owner)'s Mac. Answer from what is visible in the picture only. Be specific: quote numbers, labels and messages you can read. If asked what is wrong, name the value or message that stands out and say what it means. Two or three short spoken sentences, no lists. JSON only.",
                                                 user: "\(owner) asked: \(request)\nQuestion about the picture: \(q)\n\nJSON: answer.", schemaJSON: schema, maxTokens: 170, image: pic),
                  let a = r.json["answer"] as? String, !a.isEmpty else { return ("FAILED: Bonsai could not read the picture.", false) }
            if Self.isQuestion(request) { answer = a; await stage?.speak(a); return ("Saw: \(a)", true) }
            return ("The picture shows: \(a)", false)
        case "replace_selection":
            guard !selected.isEmpty, let holder = selectionHolder else { return ("FAILED: no text is selected. Ask \(owner) to select the text first, or type into a field instead.", false) }
            guard !text.isEmpty else { return ("ERROR: replace_selection needs the new text.", false) }
            stage?.thought(say.isEmpty ? "Rewriting the selection" : say)
            if Screen.replaceSelection(holder, with: text) { selected = ""; return ("Verified: the selected text now reads \"\(text.prefix(80))\". The rewrite is done.", false) }
            // Apps that refuse a direct edit still take real typing over the selection.
            if Screen.allowForeground, let app = target, await Screen.bringForward(app) {
                let before = Screen.visibleText(app)
                Screen.type(text); try? await Task.sleep(nanoseconds: 350_000_000)
                if Self.appeared(text, before: before, after: Screen.visibleText(app)) { selected = ""; return ("Verified: the selected text now reads \"\(text.prefix(80))\". The rewrite is done.", false) }
            }
            return ("FAILED: this app did not accept the new text.", false)
        case "list_files":
            let p = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let dir = Files.folder(p.first ?? "")
            stage?.thought(say.isEmpty ? "Looking in \(dir.lastPathComponent)" : say)
            let found = Files.list(dir, filter: p.count > 1 ? p[1] : "")
            guard FileManager.default.fileExists(atPath: dir.path) else { return ("FAILED: there is no folder \(Files.short(dir)).", false) }
            return ("\(found.count) file(s) in \(Files.short(dir)): " + found.prefix(25).map(\.lastPathComponent).joined(separator: ", ") + (found.count > 25 ? " and more" : ""), false)
        case "move_files":
            let p = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard p.count >= 3 else { return ("ERROR: move_files needs text = source folder | kind | destination folder.", false) }
            let src = Files.folder(p[0]), dest = Files.folder(p[2], inside: src)
            let found = Files.list(src, filter: p[1])
            guard !found.isEmpty else { return ("FAILED: no \(p[1]) files in \(Files.short(src)). Nothing was moved.", false) }
            stage?.thought(say.isEmpty ? "Moving \(found.count) files" : say)
            let names = found.prefix(6).map(\.lastPathComponent).joined(separator: "\n") + (found.count > 6 ? "\nand \(found.count - 6) more" : "")
            if Tools.dryRun { return ("(dry run) \(found.count) file(s) would move from \(Files.short(src)) to \(Files.short(dest)): \(found.prefix(8).map(\.lastPathComponent).joined(separator: ", "))", false) }
            guard await stage?.approve("Move \(found.count) file\(found.count == 1 ? "" : "s") to \(Files.short(dest))?", detail: names) ?? true else { return ("\(owner) said no. Nothing was moved.", false) }
            let (moved, skipped) = Files.move(found, to: dest)
            let there = Files.list(dest, filter: "").count
            if Screen.allowForeground { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
            return ("Verified: moved \(moved) file(s) to \(Files.short(dest)), which now holds \(there)." + (skipped.isEmpty ? "" : " Left in place (name already taken): \(skipped.prefix(4).joined(separator: ", ")).") + " The file work is done.", false)
        case "add_reminder":
            let p = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            stage?.thought(say.isEmpty ? "Adding a reminder" : say)
            let r = await Tools.addReminder(p.first ?? text, when: p.count > 1 && requestNamesATime ? p[1] : "")     // no due time unless one was asked for
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

    /// Words read from a picture of the window, top to bottom. For apps that draw their own text (GPU terminals such as
    /// cmux and Ghostty), where accessibility returns nothing to check typing against.
    func pictureText(_ snap: ScreenSnapshot?) async -> [String]? {
        guard useEyes, let snap, let img = await Eyes.capture(pid: snap.pid, windowFrame: snap.windowFrame) else { return nil }
        return Eyes.readText(img, windowFrame: snap.windowFrame, max: 400).map(\.text)
    }

    /// Is most of `text` readable in what the picture shows? Letters a picture reader confuses (l, 1, I and o, 0) count as the same.
    static func mostlySeen(_ text: String, in lines: [String]) -> Bool {
        func norm(_ s: String) -> String { String(s.lowercased().map { "1i|".contains($0) ? "l" : $0 == "0" ? "o" : $0 }.filter { $0.isLetter || $0.isNumber }) }
        let hay = norm(lines.joined())
        let words = text.split { !$0.isLetter && !$0.isNumber }.map { norm(String($0)) }.filter { $0.count > 2 }
        guard !words.isEmpty else { return true }
        return Double(words.filter { hay.contains($0) }.count) / Double(words.count) >= 0.6
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
