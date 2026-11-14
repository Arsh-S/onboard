import AppKit
import SwiftUI
import OnboardOverlay

/// Local tokens that sit next to the shared `Theme`.
enum UI {
    static let panelSolid = Color(red: 0.078, green: 0.090, blue: 0.086)   // offscreen stand-in for the blur
    static let card = Color.white.opacity(0.04)
    static let ok = Color(red: 0.30, green: 0.86, blue: 0.52)
    static let barRadius: CGFloat = 14
    static let pillSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let fade = Animation.easeOut(duration: 0.15)
}

/// The Onboard mark: an open ring with the agent's cursor in the gap.
struct BrandMark: View {
    var size: CGFloat = 20
    var color: Color = Theme.accent
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.80)
                .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size * 0.115), lineCap: .round))
                .rotationEffect(.degrees(81))
                .padding(size * 0.10)
            ArrowShape().fill(color)
                .frame(width: size * 0.40, height: size * 0.40)
                .offset(x: size * 0.25, y: size * 0.25)
        }
        .frame(width: size, height: size)
    }
}

/// A cursor arrow whose tip is the top-left corner.
struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.40))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.56, y: r.minY + r.height * 0.56))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.40, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

enum StatusIcon {
    /// Template image of the mark for the menu bar.
    /// `tint` nil gives the plain template mark; a colour gives a tinted one (amber loading, green ready, teal working, red problem).
    static func make(tint: NSColor? = nil) -> NSImage {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (tint ?? NSColor.black).set()
            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: s / 2, y: s / 2), radius: 6.2, startAngle: -9, endAngle: 279, clockwise: false)
            ring.lineWidth = 1.8; ring.lineCapStyle = .round; ring.stroke()
            let o = NSPoint(x: 10.6, y: 7.4), k: CGFloat = 6.6   // arrow tip (top-left), y grows upward here
            let a = NSBezierPath()
            a.move(to: o)
            a.line(to: NSPoint(x: o.x + k, y: o.y - k * 0.40))
            a.line(to: NSPoint(x: o.x + k * 0.56, y: o.y - k * 0.56))
            a.line(to: NSPoint(x: o.x + k * 0.40, y: o.y - k))
            a.close(); a.fill()
            return true
        }
        img.isTemplate = tint == nil
        return img
    }
}

/// Small teal arc that spins while a step runs.
struct Spinner: View {
    var size: CGFloat = 14
    var animated = true
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 1.75)
            Circle().trim(from: 0.0, to: 0.62)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : (animated ? 0 : 215)))
                .animation(animated ? .linear(duration: 0.75).repeatForever(autoreverses: false) : nil, value: spin)
        }
        .frame(width: size, height: size)
        .onAppear { if animated { spin = true } }
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.27, y: r.minY + r.height * 0.53))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.69))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.34))
        return p
    }
}

/// A checkmark that draws itself in when it appears.
struct CheckDraw: View {
    var size: CGFloat = 16
    var color: Color = Theme.accent
    var filled = true
    @State private var progress: CGFloat
    init(size: CGFloat = 16, color: Color = Theme.accent, filled: Bool = true, animated: Bool = true) {
        self.size = size; self.color = color; self.filled = filled
        _progress = State(initialValue: animated ? 0 : 1)
    }
    var body: some View {
        ZStack {
            if filled { Circle().fill(color.opacity(0.16)) }
            CheckShape().trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: max(1.6, size * 0.115), lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeOut(duration: 0.28)) { progress = 1 } }
    }
}

struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Pure SwiftUI switch (the system one does not draw offscreen and does not match the look).
struct MiniToggle: View {
    let isOn: Bool
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Capsule().fill(isOn ? Theme.accent : Color.white.opacity(0.14))
                .frame(width: 36, height: 21)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 17, height: 17).padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
                .animation(Theme.snappy, value: isOn)
        }
        .buttonStyle(.plain)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Theme.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prominent ? Theme.accent : Color.white.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(prominent ? Color.clear : Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Behind-window blur that stays active even when the panel is not key.
struct BlurView: NSViewRepresentable {
    var radius: CGFloat
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        v.maskImage = Self.mask(radius)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
    static func mask(_ r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.set(); NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill(); return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

/// Bar surface: blur plus black 0.35 on screen, a solid dark fill offscreen (materials do not render there).
struct BarSurface: View {
    var preview: Bool
    var radius: CGFloat = UI.barRadius
    var body: some View {
        if preview {
            UI.panelSolid
        } else {
            ZStack { BlurView(radius: radius); Color.black.opacity(0.35) }
        }
    }
}

extension View {
    func motion(_ animation: Animation, reduce: Bool) -> Animation { reduce ? UI.fade : animation }
}
