import SwiftUI
import AppKit

/// Shared design tokens (see docs/design-spec.md). Add members freely; do not rename existing ones.
public enum Theme {
    public static let accent = Color(red: 0.176, green: 0.831, blue: 0.749)        // teal #2DD4BF
    public static let background = Color(red: 0.043, green: 0.051, blue: 0.047)    // #0B0D0C
    public static let danger = Color(red: 0.94, green: 0.36, blue: 0.33)
    public static let warn = Color(red: 0.96, green: 0.68, blue: 0.26)
    public static let primary = Color.white.opacity(0.95)
    public static let secondary = Color.white.opacity(0.65)
    public static let tertiary = Color.white.opacity(0.40)
    public static let hairline = Color.white.opacity(0.08)
    public static let strongLine = Color.white.opacity(0.14)
    /// Prism spectrum (light split by glass): used for the takeover wave, the edge glow, trails and active borders.
    public static let prism: [Color] = [
        // Deliberately restrained: one cool family (teal to blue to soft indigo), no rainbow.
        Color(red: 0.18, green: 0.83, blue: 0.75), Color(red: 0.24, green: 0.72, blue: 0.90), Color(red: 0.42, green: 0.58, blue: 0.98),
        Color(red: 0.24, green: 0.72, blue: 0.90), Color(red: 0.18, green: 0.83, blue: 0.75),
    ]
    /// A point on the spectrum, 0...1 wrapping.
    public static func prism(_ t: Double) -> Color {
        let x = (t - t.rounded(.down)) * Double(prism.count - 1), i = Int(x), f = x - Double(i)
        let a = NSColor(prism[i]).usingColorSpace(.sRGB)!, b = NSColor(prism[min(i + 1, prism.count - 1)]).usingColorSpace(.sRGB)!
        return Color(red: a.redComponent + (b.redComponent - a.redComponent) * f, green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f)
    }
    public static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    public static let snappy = Animation.spring(response: 0.25, dampingFraction: 1.0)
    public static let pop = Animation.spring(response: 0.4, dampingFraction: 0.6)
}

/// Overlay additions.
public extension Theme {
    static let accentBright = Color(red: 0.369, green: 0.918, blue: 0.831)          // #5EEAD4, top of the cursor gradient
    static let ink = Color(red: 0.016, green: 0.137, blue: 0.118)                   // dark text on teal
    static let surface = Color(red: 0.082, green: 0.094, blue: 0.090)               // card fill (solid, no material)
}


/// A slowly rotating spectrum border with a soft glow. Put it over any shape while Onboard is listening or working.
public struct PrismBorder<S: InsettableShape>: View {
    let shape: S
    var lineWidth: CGFloat
    var glow: CGFloat
    var active: Bool
    public init(_ shape: S, lineWidth: CGFloat = 1.5, glow: CGFloat = 6, active: Bool = true) { self.shape = shape; self.lineWidth = lineWidth; self.glow = glow; self.active = active }
    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { tl in
            let angle = Angle.degrees(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) * 60)
            let g = AngularGradient(colors: Theme.prism, center: .center, angle: angle)
            ZStack {
                shape.strokeBorder(g, lineWidth: lineWidth * 1.5).blur(radius: glow).opacity(0.35)
                shape.strokeBorder(g, lineWidth: lineWidth).opacity(0.75)
            }
        }
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: active)
        .allowsHitTesting(false)
    }
}
