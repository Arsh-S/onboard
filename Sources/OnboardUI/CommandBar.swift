import AppKit
import SwiftUI
import OnboardCore
import OnboardOverlay

// MARK: plain inputs (so every state can be rendered offscreen)

struct StepData: Identifiable, Equatable {
    var id = UUID()
    var action: String
    var title: String
    var detail = ""
    var result = ""
    var secs = 0.0
    var done = false
    var source: String?

    init(id: UUID = UUID(), action: String, title: String, detail: String = "", result: String = "", secs: Double = 0, done: Bool = false, source: String? = nil) {
        self.id = id; self.action = action; self.title = title; self.detail = detail; self.result = result
        self.secs = secs; self.done = done; self.source = source
    }

    init(_ s: AgentStep) {
        id = s.id; action = s.action; secs = s.secs; done = s.done; source = s.source
        title = s.say.isEmpty ? Self.fallbackTitle(s.action) : s.say
        // "#12 Save" reads better as "Save".
        detail = Self.oneLine(s.detail.replacingOccurrences(of: #"^#\d+\s*"#, with: "", options: .regularExpression))
        result = Self.oneLine(s.result)
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func fallbackTitle(_ action: String) -> String {
        switch action {
        case "point": "Showing you where"
        case "click": "Clicking"
        case "type": "Typing"
        case "menu": "Choosing a menu command"
        case "key": "Pressing a key"
        case "open_app": "Opening an app"
        case "verify": "Checking my work"
        case "search_memory": "Searching your notes"
        case "look": "Looking at the screen"
        case "replace_selection": "Rewriting your selection"
        case "list_files": "Looking through files"
        case "move_files": "Moving files"
        case "add_reminder": "Adding a reminder"
        case "add_event": "Adding to the calendar"
        case "draft_email": "Drafting an email"
        default: "Working"
        }
    }

    var icon: String {
        switch action {
        case "answer": "text.bubble"
        case "point": "hand.point.up.left"
        case "click": "cursorarrow.click"
        case "type": "keyboard"
        case "menu": "filemenu.and.selection"
        case "key": "command"
        case "open_app": "macwindow"
        case "verify": "checkmark.shield"
        case "search_memory": "magnifyingglass"
        case "look": "eye"
        case "replace_selection": "pencil.line"
        case "list_files": "folder"
        case "move_files": "folder.badge.plus"
        case "add_reminder": "checklist"
        case "add_event": "calendar"
        case "draft_email": "envelope"
        default: "sparkle"
        }
    }
}

struct FooterData: Equatable {
    var online = false
    var bonsaiReady = true
    var tokPerSec = 0.0
    var replySecs: Double?
    var cloudBytes = 0
}

struct BarData: Equatable {
    var steps: [StepData] = []
    var answer = ""
    var request = ""
    var running = false
    var compact = false
    var listening = false
    var footer = FooterData()

    var source: String? { steps.last(where: { $0.source != nil })?.source }
    var hasBody: Bool { !steps.isEmpty || !answer.isEmpty }
}

struct BarActions {
    var submit: () -> Void = {}
    var mic: () -> Void = {}
    var close: () -> Void = {}
    var openSource: (String) -> Void = { _ in }
}

// MARK: the bar

struct CommandBarView: View {
    let data: BarData
    @Binding var text: String
    var preview = false
    var focusToken = 0
    var act = BarActions()

    @FocusState private var focused: Bool
    @State private var listHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 680
    static let compactWidth: CGFloat = 400
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 32
    static let maxHeight: CGFloat = 420
    private var maxBody: CGFloat { Self.maxHeight - (data.compact ? 46 : Self.headerHeight) - Self.footerHeight - 2 }
    private var anim: Animation { reduceMotion ? UI.fade : Theme.snappy }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: UI.barRadius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            if data.compact { compactHeader } else { inputHeader }
            if data.hasBody {
                Theme.hairline.frame(height: 1)
                results
            }
            Theme.hairline.frame(height: 1)
            BarFooter(data: data.footer, compact: data.compact, canRun: !text.isEmpty)
        }
        .background(BarSurface(preview: preview))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay(PrismBorder(shape, lineWidth: 1, glow: 4, active: data.listening))
        .background(shape.fill(Color.black.opacity(preview ? 1 : 0.4)).shadow(color: .black.opacity(0.45), radius: 30, y: 12))
        .animation(anim, value: data.steps.count)
        .animation(anim, value: data.answer.isEmpty)
        .onExitCommand(perform: act.close)
    }

    // MARK: headers

    private var inputHeader: some View {
        HStack(spacing: 12) {
            BrandMark(size: 22)
            if preview {
                HStack(spacing: 1) {
                    Text(text.isEmpty ? "Ask Onboard to do something" : text)
                        .font(.system(size: 20))
                        .foregroundStyle(text.isEmpty ? Theme.tertiary : Theme.primary)
                        .lineLimit(1)
                    if !text.isEmpty { Theme.accent.frame(width: 2, height: 24).clipShape(Capsule()) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $text, prompt: Text("Ask Onboard to do something").foregroundStyle(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.primary)
                    .tint(Theme.accent)
                    .focused($focused)
                    .onSubmit(act.submit)
                    .onKeyPress(.escape) { act.close(); return .handled }
                    .onAppear { focused = true }
                    .onChange(of: focusToken) { focused = true }
            }
            Button(action: act.mic) {
                Image(systemName: data.listening ? "waveform" : "mic.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(data.listening ? Theme.accent : Theme.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(data.listening ? Theme.accent.opacity(0.16) : Color.white.opacity(0.07)))
                    .overlay(Circle().strokeBorder(data.listening ? Theme.accent.opacity(0.4) : Theme.hairline, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Talk to Onboard")
        }
        .padding(.leading, 18).padding(.trailing, 13)
        .frame(height: Self.headerHeight)
    }

    private var compactHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            BrandMark(size: 18).padding(.top, 2)
            // The whole request, wrapped, so a dictated command can be read back in full.
            Text(data.request)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(6).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Spacer(minLength: 8)
            if data.running {
                HStack(spacing: 4) {
                    Keycap("⌥"); Keycap("Space")
                    Text("Stop").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(.leading, 2)
                }
                .fixedSize()
            } else {
                Button(action: act.close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 12)
        .frame(minHeight: 46)
    }

    // MARK: results

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(data.steps) { step in
                StepRow(step: step, compact: data.compact, preview: preview)
                    .transition(rowTransition)
            }
            if !data.answer.isEmpty {
                AnswerBlock(text: data.answer, source: data.source, compact: data.compact, open: act.openSource)
                    .padding(.top, data.steps.isEmpty ? 0 : 6)
                    .transition(rowTransition)
            }
        }
        .padding(8)
    }

    @ViewBuilder private var results: some View {
        if preview {
            list
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    list
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                            withAnimation(anim) { listHeight = h }
                        }
                    Color.clear.frame(height: 0).id("end")
                }
                .scrollIndicators(.never)
                .frame(height: min(listHeight, maxBody))
                .onChange(of: data.steps.count) { withAnimation(anim) { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: data.answer) { withAnimation(anim) { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
    }
}

// MARK: rows

struct StepRow: View {
    let step: StepData
    var compact = false
    var preview = false
    @State private var started = Date()

    private var running: Bool { !step.done }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: step.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(running ? Theme.accent : Theme.secondary)
                .frame(width: 18, height: 18)
            if compact { compactText } else { wideText }
            Spacer(minLength: 6)
            if !compact, !step.result.isEmpty {
                Text(step.result)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 210, alignment: .trailing)
            }
            seconds
            ZStack {
                if step.done { CheckDraw(size: 16, animated: !preview).transition(.opacity) }
                else { Spinner(size: 14, animated: !preview).transition(.opacity) }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: compact ? 44 : 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(running ? 0.06 : 0)))
        .animation(.easeOut(duration: 0.15), value: step.done)
    }

    private var wideText: some View {
        HStack(spacing: 8) {
            Text(step.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(running ? Theme.primary : Color.white.opacity(0.85))
                .lineLimit(1)
                .layoutPriority(2)
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    private var compactText: some View {
        let sub = [step.detail, step.result].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        return VStack(alignment: .leading, spacing: 1) {
            Text(step.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(running ? Theme.primary : Color.white.opacity(0.85))
                .lineLimit(1)
            if !sub.isEmpty {
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var seconds: some View {
        Group {
            if step.done || preview {
                Text(Self.format(step.secs))
            } else {
                TimelineView(.periodic(from: started, by: 0.1)) { ctx in
                    Text(Self.format(ctx.date.timeIntervalSince(started)))
                }
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(Theme.tertiary)
        .frame(width: 40, alignment: .trailing)
    }

    static func format(_ s: Double) -> String { String(format: "%.1f s", max(0, s)) }
}

struct AnswerBlock: View {
    let text: String
    var source: String?
    var compact = false
    var open: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: compact ? 14 : 15))
                .foregroundStyle(Theme.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let source {
                Button { open(source) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text").font(.system(size: 10, weight: .medium))
                        Text((source as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("From your notes. Click to open.")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.09))
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.24), lineWidth: 1)
            }
        }
    }
}

struct BarFooter: View {
    let data: FooterData
    var compact = false
    var canRun = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(UI.ok).frame(width: 6, height: 6).shadow(color: UI.ok.opacity(0.7), radius: 3)
                Text("On-device").foregroundStyle(Theme.secondary)
            }
            dot
            HStack(spacing: 4) {
                Image(systemName: data.online ? "wifi" : "wifi.slash").font(.system(size: 10, weight: .medium))
                if !compact { Text(data.online ? "Wi-Fi on" : "Offline") }
            }
            dot
            if !data.bonsaiReady {
                Text(compact ? "No Bonsai" : "Bonsai not reachable").foregroundStyle(Theme.warn)
            } else if data.tokPerSec > 0 {
                Text(String(format: compact ? "%.0f tok/s" : "Bonsai %.0f tok/s", data.tokPerSec))
            } else {
                Text(compact ? "Bonsai" : "Bonsai warming up")
            }
            if let r = data.replySecs {
                dot
                Text(String(format: compact ? "%.1f s" : "Reply %.1f s", r))
            }
            dot
            Text("\(data.cloudBytes) B to cloud")
            Spacer(minLength: 8)
            if !compact {
                HStack(spacing: 5) {
                    Keycap("↵")
                    Text("Run").foregroundStyle(canRun ? Theme.secondary : Theme.tertiary).padding(.trailing, 8)
                    Keycap("esc")
                    Text("Close")
                }
                .fixedSize().layoutPriority(3)
            }
        }
        .font(.system(size: compact ? 11 : 12).monospacedDigit())
        .foregroundStyle(Theme.tertiary)
        .lineLimit(1)
        .padding(.leading, compact ? 14 : 18).padding(.trailing, 12)
        .frame(height: CommandBarView.footerHeight)
    }

    private var dot: some View {
        Circle().fill(Color.white.opacity(0.22)).frame(width: 2.5, height: 2.5).padding(.horizontal, compact ? 7 : 9)
    }
}

// MARK: panel

final class BarPanel: NSPanel {
    var allowKey = true
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Live wrapper: reads the model and reports the card height so the panel can hug it.
struct CommandBarHost: View {
    let model: AppModel
    var onHeight: (CGFloat) -> Void
    var close: () -> Void

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            CommandBarView(data: model.barData, text: $m.query, focusToken: model.focusToken,
                           act: BarActions(submit: { model.submit() }, mic: { model.toggleBarMic() }, close: close,
                                           openSource: { model.openSource($0) }))
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            Spacer(minLength: 0)
        }
        .padding(.top, CommandBarController.inset.top)
        .padding(.horizontal, CommandBarController.inset.left)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

extension AppModel {
    var barData: BarData {
        BarData(steps: showTurn ? agent.steps.map(StepData.init) : [],
                answer: showTurn ? answer : "",
                request: agent.request,
                running: agent.running,
                compact: compact,
                listening: recording == .talk,
                footer: FooterData(online: online, bonsaiReady: bonsaiReachable, tokPerSec: tokPerSec,
                                   replySecs: replySecs, cloudBytes: 0))
    }
}

/// Owns the floating, non-activating panel. Expanded: centered, 22% from the top, takes the keyboard.
/// Compact (while the agent works): top right corner, never key and click-through, so it cannot get in the agent's way.
@MainActor final class CommandBarController {
    static let inset = NSEdgeInsets(top: 28, left: 44, bottom: 72, right: 44)   // room for the shadow
    let model: AppModel
    private let panel: BarPanel
    private var cardHeight: CGFloat = CommandBarView.headerHeight + CommandBarView.footerHeight + 6
    private var shrink: DispatchWorkItem?
    private var closing = false
    private var generation = 0

    init(model: AppModel) {
        self.model = model
        panel = BarPanel(contentRect: NSRect(x: 0, y: 0, width: 768, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CommandBarHost(model: model, onHeight: { [weak self] h in self?.heightChanged(h) },
                                                          close: { [weak self] in self?.close() }))
        host.sizingOptions = []
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.close() }
    }

    var isVisible: Bool { panel.isVisible && !closing }
    var isKey: Bool { panel.isKeyWindow }

    /// Option-Space.
    func toggle() {
        if !isVisible { open() }
        else if model.agent.running { model.stop(); close() }
        else if model.compact { model.clearScreen(); fadeOut { [weak self] in self?.open() } }
        else { model.clearScreen(); close() }
    }

    func open() {
        // Remember the user's app BEFORE anything of ours is on screen.
        model.targetApp = Screen.targetApp(excluding: Bundle.main.bundleIdentifier)
        closing = false
        generation += 1
        model.query = ""
        model.compact = false
        if !model.agent.running { model.showTurn = false }
        model.focusToken += 1
        panel.allowKey = true
        panel.ignoresMouseEvents = false
        place()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        fade(to: 1, 0.08)
    }

    func close() {
        guard panel.isVisible, !closing else { return }
        if model.agent.running { model.stop() }
        fadeOut(nil)
    }

    /// The agent is starting: give the keyboard back to the user's app and move out of the way.
    func showCompact() {
        let apply = { [weak self] in
            guard let self else { return }
            self.closing = false
            self.generation += 1
            self.model.compact = true
            self.panel.allowKey = false
            self.panel.orderOut(nil)                 // the only reliable way to stop being the key window
            self.panel.ignoresMouseEvents = true     // the agent's clicks pass straight through
            self.place()
            self.panel.alphaValue = 0
            self.panel.orderFrontRegardless()
            self.fade(to: 1, 0.08)
        }
        if panel.isVisible, !model.compact { fadeOut(apply) } else { apply() }
    }

    /// The turn is over: the answer's source chip and the close button become clickable.
    func turnEnded() {
        panel.ignoresMouseEvents = false
        // The result does not sit there: it leaves on its own once it has been said, or after a moment to read it.
        let g = generation
        Task { [weak self] in
            var spoke = false
            try? await Task.sleep(nanoseconds: 300_000_000)                       // speech starts just after the turn ends
            while let self, self.model.speakingNow { spoke = true; try? await Task.sleep(nanoseconds: 150_000_000) }
            guard let self else { return }
            let read = spoke ? 1.2 : min(5, max(2.2, Double(self.model.answer.count) / 28))
            try? await Task.sleep(nanoseconds: UInt64(read * 1_000_000_000))
            guard g == self.generation, self.model.compact, self.panel.isVisible, !self.model.agent.running else { return }
            self.model.clearScreen()
            self.fadeOut(nil)
        }
    }

    /// Dictation is about to type: make sure our text field is not what receives the keys.
    func releaseKeyboard() {
        guard panel.isVisible, panel.isKeyWindow else { return }
        panel.orderOut(nil)
    }

    // MARK: layout

    private func heightChanged(_ h: CGFloat) {
        guard abs(h - cardHeight) > 0.5 else { return }
        shrink?.cancel()
        if h > cardHeight {
            cardHeight = h; place()
        } else {
            // Let the content finish animating before the window gets smaller.
            let w = DispatchWorkItem { [weak self] in self?.cardHeight = h; self?.place() }
            shrink = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: w)
        }
    }

    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let i = Self.inset
        let card: NSRect
        if model.compact {
            let v = screen.visibleFrame, w = CommandBarView.compactWidth
            card = NSRect(x: v.maxX - w - 16, y: v.maxY - 12 - cardHeight, width: w, height: cardHeight)
        } else {
            let f = screen.frame, w = CommandBarView.width
            let top = f.maxY - (f.height * 0.22).rounded()
            card = NSRect(x: (f.midX - w / 2).rounded(), y: top - cardHeight, width: w, height: cardHeight)
        }
        let frame = NSRect(x: card.minX - i.left, y: card.minY - i.bottom, width: card.width + i.left + i.right, height: card.height + i.top + i.bottom)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func fade(to alpha: CGFloat, _ secs: Double, then: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = secs
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { then?() } })
    }

    private func fadeOut(_ then: (() -> Void)?) {
        closing = true
        generation += 1
        let g = generation
        fade(to: 0, 0.10) { [weak self] in
            guard let self, g == self.generation else { return }   // reopened meanwhile
            self.panel.orderOut(nil)
            self.closing = false
            then?()
        }
    }
}
