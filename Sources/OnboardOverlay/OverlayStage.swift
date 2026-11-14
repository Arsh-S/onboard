import AppKit
import SwiftUI
import Observation
import OnboardCore

/// The on-screen stage: the agent's own cursor, x-ray scan, ripples, step dots and the approval card.
///
/// Coordinates: the agent passes global screen points with a top-left origin (as the accessibility API reports them).
/// The overlay window covers the whole frame of the primary screen (menu bar included), whose top-left corner is that
/// global origin, and its SwiftUI root fills the window with a top-left origin. So global points are view points, unchanged.
@MainActor public final class OverlayStage: AgentStage {
    public static let shared = OverlayStage()
    /// Called when the agent wants to say something (the UI speaks it and shows it).
    public var onSpeak: ((String) async -> Void)?

    let model = OverlayModel()
    private var panel: NSPanel?
    private var approval: ApprovalPresenter?
    private var steps = 0
    private var resting = true          // true between runs: the next call starts a fresh run
    private var restGen = 0             // invalidates pending fade-outs when a new run starts
    private var screenObserver: NSObjectProtocol?

    public init() {}

    // MARK: AgentStage

    public func scan(window: CGRect, elements: [UIElement]) async {
        guard begin() else { return }
        model.set(.thinking)
        let pass = ScanPass(window: window, frames: elements.map(\.frame), bounds: CGRect(origin: .zero, size: model.screen), start: Date())
        model.scan = pass
        await pause(ScanPass.total)
        if model.scan?.id == pass.id { model.scan = nil }
    }

    public func glide(to: CGPoint, frame: CGRect?, thought: String) async {
        guard begin() else { return }
        // Keep the cursor on this screen even if the element sits on another display.
        let dest = CGPoint(x: Motion.clamp(to.x, 1, model.screen.width - 2), y: Motion.clamp(to.y, 1, model.screen.height - 2))
        setBubble(thought)
        model.set(.acting)
        if var old = model.target, old.end == nil { old.end = Date(); model.target = old }   // read, then write: one access at a time
        let from = model.pose(at: Date()).tip
        func glow() { if let frame { model.target = TargetGlow(rect: frame, start: Date()) } }
        if hypot(dest.x - from.x, dest.y - from.y) < 2 {
            model.flight = nil; model.tip = dest; glow()
            if frame != nil { await pause(0.2) }
        } else if model.reduceMotion {
            // Reduce Motion: fade out, move, fade in.
            withAnimation(.easeOut(duration: 0.15)) { model.cursorVisible = false }
            await pause(0.15)
            model.flight = nil; model.tip = dest; glow()
            withAnimation(.easeOut(duration: 0.15)) { model.cursorVisible = true }
            await pause(0.15)
        } else {
            let f = Flight(from: from, to: dest, start: Date())
            model.tip = from; model.flight = f
            // The target lights up just before the cursor lands.
            let lead = min(0.22, f.duration * 0.6)
            await pause(f.duration - lead); glow()
            await pause(f.start.addingTimeInterval(f.duration).timeIntervalSinceNow)
            if model.flight?.id == f.id { model.tip = dest; model.flight = nil }
        }
    }

    public func click(at: CGPoint) async {
        guard begin() else { return }
        if model.flight == nil, hypot(model.tip.x - at.x, model.tip.y - at.y) > 2 { model.tip = at }
        model.set(.acting)
        let now = Date()
        model.ripples.append(Ripple(at: at, start: now))
        steps += 1
        withAnimation(Theme.pop) { model.steps.append(StepDot(id: steps, at: at, prev: model.steps.last?.at)) }
        withAnimation(.easeOut(duration: 0.08)) { model.dip = true }
        await pause(0.09)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { model.dip = false }
        await pause(0.09)            // about 0.18 s in total, so the real click lands on the ripple
        let gen = restGen
        Task { [weak self] in
            await self?.pause(0.4)
            guard let self else { return }
            self.model.ripples.removeAll { Date().timeIntervalSince($0.start) > Ripple.life }
            if var old = self.model.target, old.end == nil { old.end = Date(); self.model.target = old }
            if gen == self.restGen, self.model.mode == .acting, self.model.flight == nil { self.model.set(.thinking) }
        }
    }

    public func thought(_ text: String) {
        guard begin() else { return }
        setBubble(text)
        if model.flight == nil { model.set(.thinking) }
    }

    public func speak(_ text: String) async { await onSpeak?(text) }

    public func approve(_ question: String, detail: String) async -> Bool {
        // With no screen to ask on, behave like the headless default.
        guard begin(), let screen = NSScreen.screens.first else { return true }
        model.set(.waiting)
        let presenter = ApprovalPresenter(question: question, detail: detail)
        approval?.decide(false)
        approval = presenter
        let origin = model.cardOrigin(presenter.cardSize)
        model.dimCenter = CGPoint(x: origin.x + presenter.cardSize.width / 2, y: origin.y + presenter.cardSize.height / 2)
        model.dim = true
        let ok = await presenter.present(at: origin, on: screen, above: panel?.level ?? .statusBar)
        if approval === presenter { approval = nil; model.dim = false; model.set(ok ? .thinking : .idle) }
        return ok
    }

    public func rest() {
        model.set(.idle)
        resting = true
        restGen += 1
        let gen = restGen
        Task { [weak self] in
            // Dots, bubble and target fade about 2 s after the task ends; the cursor after about 6 s idle.
            await self?.pause(2)
            guard let self, gen == self.restGen else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.model.steps = []; self.model.bubble = nil }
            if var old = self.model.target, old.end == nil { old.end = Date(); self.model.target = old }
            await self.pause(4)
            guard gen == self.restGen else { return }
            withAnimation(.easeOut(duration: 0.5)) { self.model.cursorVisible = false }
            await self.pause(0.6)
            guard gen == self.restGen else { return }
            self.model.target = nil; self.model.ripples = []
            self.panel?.orderOut(nil)
        }
    }

    /// Lets the app show what the agent is doing between stage calls (for example `.thinking` while the model runs).
    public func setState(_ mode: CursorMode) {
        guard panel != nil, model.cursorVisible else { return }
        model.set(mode)
    }

    // MARK: plumbing

    private func pause(_ seconds: Double) async {
        if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    }

    /// Crossfade when the text changes, pop when the bubble appears.
    private func setBubble(_ text: String) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard t != model.bubble ?? "" else { return }
        if t.isEmpty { withAnimation(.easeOut(duration: 0.15)) { model.bubble = nil } }
        else if model.bubble == nil { withAnimation(model.reduceMotion ? .easeOut(duration: 0.15) : Theme.pop) { model.bubble = t } }
        else { withAnimation(.easeInOut(duration: 0.15)) { model.bubble = t } }
    }

    /// Called at the top of every drawing call: starts a fresh run if the last one ended, makes sure the overlay window
    /// is up (never activating the app) and the cursor is visible. False when there is no screen to draw on.
    @discardableResult private func begin() -> Bool {
        guard let screen = NSScreen.screens.first else { return false }
        if resting {
            resting = false; restGen += 1; steps = 0
            model.takeover = Date()          // the grid wave that says "Onboard has the screen"
            if !model.steps.isEmpty { withAnimation(.easeOut(duration: 0.2)) { model.steps = [] } }
        }
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panel = self.panel ?? makePanel(screen)
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: true) }
        model.screen = screen.frame.size
        if !model.placed { model.tip = CGPoint(x: screen.frame.width / 2, y: screen.frame.height * 0.56); model.placed = true }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if !model.cursorVisible { withAnimation(.easeOut(duration: 0.3)) { model.cursorVisible = true } }
        return true
    }

    private func makePanel(_ screen: NSScreen) -> NSPanel {
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true                      // fully click-through
        p.level = .statusBar                             // above app windows and the menu bar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false; p.animationBehavior = .none
        p.isExcludedFromWindowsMenu = true
        let host = NSHostingView(rootView: OverlayRoot(model: model))
        host.sizingOptions = []                          // the window drives the size, not the content
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = NSScreen.screens.first, let panel = self.panel else { return }
                panel.setFrame(s.frame, display: true); self.model.screen = s.frame.size
            }
        }
        return p
    }
}

// MARK: approval panel

/// A borderless panel that can take the keyboard without activating the app.
final class KeyPanel: NSPanel {
    var onDecide: ((Bool) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onDecide?(true)        // Return, Enter
        case 53: onDecide?(false)           // Escape
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { onDecide?(false) }
}

@MainActor @Observable final class ApprovalState { var shown = false }

/// Shows the approval card in its own small key-capable panel (the main overlay stays click-through) and returns the choice.
@MainActor final class ApprovalPresenter {
    static let margin = 56.0            // room around the card for its shadow
    let question: String, detail: String
    let cardSize: CGSize
    private let state = ApprovalState()
    private var panel: KeyPanel?
    private var pending: CheckedContinuation<Bool, Never>?

    init(question: String, detail: String) {
        self.question = question; self.detail = detail
        cardSize = NSHostingView(rootView: ApprovalCard(question: question, detail: detail)).fittingSize
    }

    func present(at origin: CGPoint, on screen: NSScreen, above level: NSWindow.Level) async -> Bool {
        let m = Self.margin, size = CGSize(width: cardSize.width + 2 * m, height: cardSize.height + 2 * m)
        // Overlay points (top-left origin) to AppKit screen coordinates (bottom-left origin).
        let frame = CGRect(x: screen.frame.minX + origin.x - m, y: screen.frame.maxY - (origin.y - m) - size.height, width: size.width, height: size.height)
        let p = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = NSWindow.Level(rawValue: level.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false; p.animationBehavior = .none
        p.isFloatingPanel = true; p.becomesKeyOnlyIfNeeded = false
        p.onDecide = { [weak self] in self?.decide($0) }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingView(rootView: ApprovalHost(state: state, reduce: reduce, card: ApprovalCard(question: question, detail: detail) { [weak self] in self?.decide($0) }))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        p.contentView = host
        panel = p
        p.makeKeyAndOrderFront(nil)         // key without activating: this is a non-activating panel
        return await withCheckedContinuation { c in
            pending = c
            DispatchQueue.main.async { [state] in state.shown = true }
        }
    }

    func decide(_ ok: Bool) {
        guard let c = pending else { return }
        pending = nil
        state.shown = false
        let p = panel; panel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { p?.orderOut(nil) }
        c.resume(returning: ok)
    }
}

struct ApprovalHost: View {
    let state: ApprovalState
    let reduce: Bool
    let card: ApprovalCard
    var body: some View {
        card
            .offset(y: state.shown || reduce ? 0 : 12)
            .opacity(state.shown ? 1 : 0)
            .animation(state.shown ? Theme.spring : .easeOut(duration: 0.12), value: state.shown)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
