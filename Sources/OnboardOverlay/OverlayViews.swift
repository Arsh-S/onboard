import SwiftUI

/// The single view hosted by the click-through overlay window. It fills the screen with a top-left origin, so model
/// points map straight to view points. `fixedNow` freezes the clock (used for offscreen previews).
struct OverlayRoot: View {
    let model: OverlayModel
    var fixedNow: Date?

    var body: some View {
        Group {
            if let fixedNow { layers(fixedNow) } else {
                // Display-rate clock during a flight, 60 fps otherwise, stopped when nothing is visible.
                TimelineView(.animation(minimumInterval: model.flight == nil ? 1.0 / 60 : nil, paused: !model.animating)) { layers($0.date) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    func layers(_ now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            DimLayer(model: model)
            EffectsLayer(model: model, now: now)
            StepsLayer(model: model)
            CursorLayer(model: model, now: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: spotlight dim

struct DimLayer: View {
    let model: OverlayModel
    var body: some View {
        let c = UnitPoint(x: model.dimCenter.x / max(model.screen.width, 1), y: model.dimCenter.y / max(model.screen.height, 1))
        // Black 0.35 on average, a touch lighter around the card so it reads as a spotlight.
        RadialGradient(colors: [.black.opacity(0.26), .black.opacity(0.38)], center: c, startRadius: 140, endRadius: 640)
            .opacity(model.dim ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: model.dim)
    }
}

// MARK: scan, target glow, ripples (one canvas, pure functions of time)

struct EffectsLayer: View {
    let model: OverlayModel
    let now: Date
    var body: some View {
        let scan = model.scan, target = model.target, ripples = model.ripples, reduce = model.reduceMotion, now = now
        Canvas { ctx, _ in
            if let scan { FX.scan(scan, now, reduce, &ctx) }
            if let target { FX.target(target, now, reduce, &ctx) }
            for r in ripples { FX.ripple(r, now, reduce, &ctx) }
        }
    }
}

enum FX {
    static func scan(_ s: ScanPass, _ now: Date, _ reduce: Bool, _ ctx: inout GraphicsContext) {
        let t = now.timeIntervalSince(s.start)
        guard t >= 0, t < ScanPass.total else { return }
        let fade = 1 - Motion.clamp((t - ScanPass.fadeAt) / ScanPass.fade, 0, 1)
        let w = s.window
        if !reduce, t < ScanPass.sweep {
            // 120pt band of white 0.12, tilted, crossing the window once.
            var c = ctx
            c.clip(to: Path(roundedRect: w, cornerRadius: 10, style: .continuous))
            let x = w.minX - 140 + (w.width + 280) * (t / ScanPass.sweep)
            c.translateBy(x: x, y: w.midY); c.rotate(by: .degrees(14))
            let band = Gradient(stops: [.init(color: .white.opacity(0), location: 0), .init(color: .white.opacity(0.12), location: 0.5), .init(color: .white.opacity(0), location: 1)])
            c.fill(Path(CGRect(x: -60, y: -w.height, width: 120, height: w.height * 2)), with: .linearGradient(band, startPoint: CGPoint(x: -60, y: 0), endPoint: CGPoint(x: 60, y: 0)))
        }
        // The window itself gets a hairline so the pass reads as "this window".
        let edge = min(1, t / 0.12) * fade
        ctx.stroke(Path(roundedRect: w.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10, style: .continuous), with: .color(Theme.accent.opacity(0.22 * edge)), lineWidth: 1)
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: Theme.accent.opacity(0.4), radius: 6))
            for (i, r) in s.rects.enumerated() {
                let local = t - (reduce ? 0 : s.delays[i])
                guard local > 0 else { continue }
                let a = min(1, local / (reduce ? 0.15 : 0.09)) * fade
                // In from scale 1.04 on the spec spring.
                let k = reduce ? 1 : Motion.spring(local, response: 0.3, damping: 0.85)
                let grow = 0.04 * (1 - k)
                let p = Path(roundedRect: r.insetBy(dx: -r.width * grow / 2, dy: -r.height * grow / 2), cornerRadius: min(4, r.height / 2), style: .continuous)
                l.fill(p, with: .color(Theme.accent.opacity(0.08 * a)))
                l.stroke(p, with: .color(Theme.accent.opacity(a)), lineWidth: 1.5)
            }
        }
    }

    static func target(_ g: TargetGlow, _ now: Date, _ reduce: Bool, _ ctx: inout GraphicsContext) {
        let age = now.timeIntervalSince(g.start)
        guard age >= 0 else { return }
        var a = min(1, age / 0.1)
        if let end = g.end { a *= 1 - Motion.clamp(now.timeIntervalSince(end) / 0.25, 0, 1) }
        guard a > 0 else { return }
        // One 0.25 s pulse: the ring swells and the glow flares, then settles.
        let bump = reduce ? 0 : sin(Double.pi * Motion.clamp(age / 0.25, 0, 1))
        let r = g.rect.insetBy(dx: -3 - 3 * bump, dy: -3 - 3 * bump)
        let p = Path(roundedRect: r, cornerRadius: min(7, r.height / 2), style: .continuous)
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: Theme.accent.opacity((0.45 + 0.35 * bump) * a), radius: 7 + 9 * bump))
            l.fill(p, with: .color(Theme.accent.opacity((0.14 + 0.08 * bump) * a)))
            l.stroke(p, with: .color(Theme.accent.opacity(a)), lineWidth: 2)
        }
    }

    static func ripple(_ r: Ripple, _ now: Date, _ reduce: Bool, _ ctx: inout GraphicsContext) {
        let raw = now.timeIntervalSince(r.start) / Ripple.life
        guard raw >= 0, raw < 1 else { return }
        let p = Motion.easeOut(raw)
        func circle(_ d: Double) -> Path { Path(ellipseIn: CGRect(x: r.at.x - d / 2, y: r.at.y - d / 2, width: d, height: d)) }
        // Ring 8 to 36pt, opacity 0.6 to 0, with a brief soft flash inside.
        ctx.fill(circle(reduce ? 22 : 8 + 16 * p), with: .color(Theme.accent.opacity(0.22 * (1 - p))))
        ctx.stroke(circle(reduce ? 28 : 8 + 28 * p), with: .color(Theme.accent.opacity(0.6 * (1 - p))), lineWidth: 2 - p)
    }
}

// MARK: step dots

struct StepsLayer: View {
    let model: OverlayModel
    /// The badge sits just up and left of the click point, so it never hides the control or sits under the arrow.
    static func center(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - 13, y: p.y - 13) }
    var body: some View {
        let last = model.steps.last?.id
        ZStack(alignment: .topLeading) {
            ForEach(model.steps) { s in
                if let prev = s.prev, hypot(prev.x - s.at.x, prev.y - s.at.y) > 26 {
                    Connector(from: Self.center(prev), to: Self.center(s.at)).transition(.opacity)
                }
            }
            ForEach(model.steps) { s in
                let c = Self.center(s.at)
                StepBadge(n: s.id)
                    .opacity(s.id == last ? 1 : 0.78)
                    .offset(x: c.x - 10, y: c.y - 10)
                    // Anchor the pop on the dot's own center (the offset does not move the layout frame).
                    .transition(model.reduceMotion ? .opacity : .scale(scale: 0.6, anchor: UnitPoint(x: c.x / 20, y: c.y / 20)).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct StepBadge: View {
    let n: Int
    var body: some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Theme.ink)
            .frame(width: 20, height: 20)
            .background(Circle().fill(LinearGradient(colors: [Theme.accentBright, Theme.accent], startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

/// 1pt white 0.15 line between consecutive dots, stopping short of both circles; a faint dark underlay keeps it visible on light apps.
struct Connector: View {
    let from: CGPoint, to: CGPoint
    var body: some View {
        let d = max(hypot(to.x - from.x, to.y - from.y), 1), ux = (to.x - from.x) / d, uy = (to.y - from.y) / d
        let line = Path { p in
            p.move(to: CGPoint(x: from.x + ux * 13, y: from.y + uy * 13))
            p.addLine(to: CGPoint(x: to.x - ux * 13, y: to.y - uy * 13))
        }
        ZStack {
            line.stroke(Color.black.opacity(0.10), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            line.stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }
}

// MARK: cursor, halo, trail, thought bubble

/// The arrow: a rounded kite with its tip at the frame's top-left corner.
struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 18
        let pts = [(0.6, 0.6), (17.3, 7.0), (10.1, 10.1), (7.0, 17.3)].map { CGPoint(x: rect.minX + $0.0 * k, y: rect.minY + $0.1 * k) }
        let radii = [0.9, 1.9, 1.4, 1.9].map { $0 * k }
        var p = Path()
        p.move(to: CGPoint(x: (pts[3].x + pts[0].x) / 2, y: (pts[3].y + pts[0].y) / 2))
        for i in 0..<4 { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 4], radius: radii[i]) }
        p.closeSubpath()
        return p
    }
}

struct CursorArrow: View {
    var glow = 0.6
    var size = 18.0
    var body: some View {
        ArrowShape()
            .fill(LinearGradient(colors: [Theme.accentBright, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(ArrowShape().stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: size / 18, lineJoin: .round)))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            .shadow(color: Theme.accent.opacity(glow), radius: 8)
    }
}

struct CursorLayer: View {
    let model: OverlayModel
    let now: Date

    var body: some View {
        let pose = model.pose(at: now)
        let t = now.timeIntervalSinceReferenceDate
        let still = model.reduceMotion
        let ramp = Motion.clamp(now.timeIntervalSince(model.modeSince) / 0.35, 0, 1)      // eases a new mode in
        let resting = model.mode == .idle && model.flight == nil && !still
        let bob = resting ? sin(t * 2 * .pi / 2.4) * ramp : 0                              // 2pt peak to peak, 2.4 s
        let glow: Double = switch model.mode {
            case .idle, .waiting: 0.6
            case .thinking: 0.6 + (still ? 0 : 0.25 * sin(t * 2 * .pi / 1.4) * ramp)
            case .acting: 0.6 + 0.25 * ramp
        }
        ZStack(alignment: .topLeading) {
            if let f = pose.flight, pose.progress < 1 { trail(f, pose.progress) }
            halo(t, ramp, still)
                .frame(width: 48, height: 48)
                .offset(x: pose.tip.x - 15.0, y: pose.tip.y - 15.0 + bob)   // centered on the arrow body, 9pt in from the tip
            CursorArrow(glow: glow)
                .scaleEffect(model.dip ? 0.92 : 1, anchor: .topLeading)
                .scaleEffect(pose.scale, anchor: .topLeading)
                .rotationEffect(.degrees(pose.lean), anchor: .topLeading)
                .offset(x: pose.tip.x, y: pose.tip.y + bob)
            bubble(bob)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(model.cursorVisible ? 1 : 0)
    }

    /// Comet tail: longest mid flight (when the cursor is fastest), gone at both ends.
    func trail(_ f: Flight, _ e: Double) -> some View {
        let tail = max(0, e - 0.3 * sin(Double.pi * e))
        let a = f.point(tail), b = f.point(e), w = max(model.screen.width, 1), h = max(model.screen.height, 1)
        return f.path.trimmedPath(from: tail, to: e)
            .stroke(LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.55)], startPoint: UnitPoint(x: a.x / w, y: a.y / h), endPoint: UnitPoint(x: b.x / w, y: b.y / h)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .blur(radius: 0.6)
    }

    @ViewBuilder func halo(_ t: Double, _ ramp: Double, _ still: Bool) -> some View {
        switch model.mode {
        case .thinking:
            // Two rings expanding out of the arrow, half a cycle apart.
            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    let p = still ? 0.45 : (t / 1.4 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(Theme.accent, lineWidth: 1.5)
                        .frame(width: 14 + 26 * p, height: 14 + 26 * p)
                        .opacity((still ? 0.5 : 0.6 * (1 - p)) * ramp * (still && i == 1 ? 0 : 1))
                }
            }
        case .waiting:
            // Breathing ring while the approval card is up.
            let b = still ? 0.5 : 0.5 + 0.5 * sin(t * 2 * .pi / 1.8)
            Circle().fill(Theme.accent.opacity(0.10))
                .overlay(Circle().strokeBorder(Theme.accent.opacity(0.45 + 0.45 * b), lineWidth: 1.5))
                .frame(width: 36, height: 36)
                .scaleEffect(1 + 0.10 * b)
                .shadow(color: Theme.accent.opacity(0.35 * b), radius: 6)
                .opacity(ramp)
        default: EmptyView()
        }
    }

    /// Thought bubble at (14, 18) from the tip, trailing the cursor by a few frames; flips to stay on screen.
    func bubble(_ bob: Double) -> some View {
        let boxW = 260.0, boxH = 46.0
        let dest = model.flight?.to ?? model.tip
        let flipX = dest.x + 14 + boxW > model.screen.width - 8, flipY = dest.y + 18 + boxH > model.screen.height - 8
        let lag = model.pose(at: now.addingTimeInterval(-0.014)).tip
        let corner = Alignment(horizontal: flipX ? .trailing : .leading, vertical: flipY ? .bottom : .top)
        let anchor = UnitPoint(x: flipX ? 1 : 0, y: flipY ? 1 : 0)
        return ZStack(alignment: corner) {
            if let text = model.bubble {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.95)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
                    .transition(model.reduceMotion ? .opacity : .scale(scale: 0.5, anchor: anchor).combined(with: .opacity))
            }
        }
        .frame(width: boxW, height: boxH, alignment: corner)
        .offset(x: flipX ? lag.x - 14 - boxW : lag.x + 14, y: (flipY ? lag.y - 10 - boxH : lag.y + 18) + bob)
    }
}

// MARK: approval card

struct ApprovalCard: View {
    let question: String
    let detail: String
    var onDecide: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                CursorArrow(glow: 0.45, size: 11)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent.opacity(0.14)))
                Text(question).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if !detail.isEmpty {
                Text(detail).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7))
                    .lineSpacing(2).lineLimit(8).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { onDecide(false) } label: { CardButtonLabel(title: "Not now", key: "esc") }.buttonStyle(CardButtonStyle(primary: false))
                Button { onDecide(true) } label: { CardButtonLabel(title: "Allow", key: "\u{21A9}") }.buttonStyle(CardButtonStyle(primary: true))
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
    }
}

struct CardButtonLabel: View {
    let title: String, key: String
    var body: some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(key).font(.system(size: 11, weight: .medium)).opacity(0.55)
        }
    }
}

struct CardButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? Theme.ink : Theme.primary)
            .padding(.horizontal, 12).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(primary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.08))))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(primary ? 0.25 : 0.08), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
