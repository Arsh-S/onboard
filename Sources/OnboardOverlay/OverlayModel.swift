import SwiftUI
import Observation

/// What the agent cursor is doing (drives its halo and glow).
public enum CursorMode: Sendable { case idle, thinking, acting, waiting }

/// Pure timing helpers, so transient effects are functions of time (smooth at any frame rate, and renderable at a fixed instant).
enum Motion {
    static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
    static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - clamp(t, 0, 1), 3) }
    /// Closed form of an underdamped spring going 0 to 1 (same parameters as SwiftUI's `.spring`).
    static func spring(_ t: Double, response: Double, damping z: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi / response, wd = w * sqrt(1 - z * z)
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }
}

/// One flight of the cursor along a quadratic bezier (spec: duration clamp(d/1200, 0.28, 0.75), arc min(0.2 d, 80)).
struct Flight: Sendable {
    let id = UUID()
    let from: CGPoint, control: CGPoint, to: CGPoint
    let start: Date
    let duration: Double

    init(from: CGPoint, to: CGPoint, start: Date) {
        let dx = to.x - from.x, dy = to.y - from.y, d = max(hypot(dx, dy), 0.001)
        let h = min(0.2 * d, 80)
        // Unit normal, chosen to arc upward on screen unless that would leave the top edge.
        var nx = -dy / d, ny = dx / d
        if ny > 0 || (ny == 0 && nx > 0) { nx = -nx; ny = -ny }
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        if mid.y + ny * h < 6 { nx = -nx; ny = -ny }
        self.from = from; self.to = to; self.start = start
        // A quadratic bezier peaks at half its control offset, hence 2h.
        control = CGPoint(x: mid.x + nx * 2 * h, y: mid.y + ny * 2 * h)
        duration = Motion.clamp(d / 1200, 0.28, 0.75)
    }

    func point(_ e: Double) -> CGPoint {
        let u = 1 - e
        return CGPoint(x: u * u * from.x + 2 * u * e * control.x + e * e * to.x, y: u * u * from.y + 2 * u * e * control.y + e * e * to.y)
    }
    var path: Path { Path { $0.move(to: from); $0.addQuadCurve(to: to, control: control) } }
}

/// Where the cursor is drawn at one instant.
struct Pose { var tip: CGPoint; var scale = 1.0; var lean = 0.0; var progress = 1.0; var flight: Flight? }

struct StepDot: Identifiable, Sendable { let id: Int; let at: CGPoint; let prev: CGPoint? }
struct Ripple: Identifiable, Sendable { let id = UUID(); let at: CGPoint; let start: Date; static let life = 0.35 }
struct TargetGlow: Sendable { let rect: CGRect; let start: Date; var end: Date? }

/// Shimmer plus x-ray pass. Outlines appear left to right, just ahead of the shimmer band, then fade together.
struct ScanPass: Sendable {
    let id = UUID()
    let window: CGRect, rects: [CGRect], delays: [Double]
    let start: Date
    static let sweep = 0.7, fadeAt = 0.63, fade = 0.25, total = 0.88

    init(window: CGRect, frames: [CGRect], bounds: CGRect, start: Date) {
        let area = max(window.width * window.height, 1)
        // Skip slivers, off-screen frames and big containers; cap at 60 per spec.
        let keep = frames.filter { $0.width > 3 && $0.height > 3 && bounds.intersects($0) && $0.width * $0.height < 0.6 * area }.prefix(60)
        self.window = window; self.start = start
        rects = keep.sorted { $0.minX < $1.minX }
        delays = rects.map { 0.03 + 0.40 * Motion.clamp(($0.midX - window.minX) / max(window.width, 1), 0, 1) }
    }
}

/// Everything the overlay draws. All points are overlay points: main screen, top-left origin (same as accessibility frames).
@MainActor @Observable final class OverlayModel {
    var screen = CGSize(width: 1440, height: 900)
    var tip = CGPoint.zero
    var placed = false
    var cursorVisible = false
    private(set) var mode = CursorMode.idle
    private(set) var modeSince = Date.distantPast
    var dip = false
    var bubble: String?
    var flight: Flight?
    var steps: [StepDot] = []
    var ripples: [Ripple] = []
    var target: TargetGlow?
    var scan: ScanPass?
    var takeover: Date?
    var dim = false
    var dimCenter = CGPoint.zero
    var reduceMotion = false

    /// The frame clock only runs while something is on screen.
    /// A resting cursor does not need the frame clock (it only bobs 2 points); everything else does.
    var animating: Bool { (cursorVisible && (mode != .idle || flight != nil)) || scan != nil || !ripples.isEmpty || takeover != nil }

    func set(_ m: CursorMode, at now: Date = Date()) { if m != mode { mode = m; modeSince = now } }

    func pose(at now: Date) -> Pose {
        guard let f = flight else { return Pose(tip: tip) }
        let e = Motion.easeInOut(Motion.clamp(now.timeIntervalSince(f.start) / f.duration, 0, 1))
        let s = sin(Double.pi * e)
        // Scale peaks 1.15 mid flight; a slight lean into the direction of travel, pivoting on the tip.
        return Pose(tip: f.point(e), scale: 1 + 0.15 * s, lean: (f.to.x >= f.from.x ? 7 : -7) * s, progress: e, flight: f)
    }

    /// Top-left of a card of `size` placed near the cursor tip and kept on screen.
    func cardOrigin(_ size: CGSize) -> CGPoint {
        let m = 16.0
        var x = tip.x + 30, y = tip.y + 34
        if x + size.width > screen.width - m { x = tip.x - 30 - size.width }
        if y + size.height > screen.height - m { y = tip.y - 26 - size.height }
        return CGPoint(x: Motion.clamp(x, m, max(m, screen.width - m - size.width)), y: Motion.clamp(y, 36, max(36, screen.height - m - size.height)))
    }
}
