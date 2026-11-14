import AppKit
import SwiftUI

/// Offscreen renders of every overlay state over a fake app window, for judging the look without showing a window.
public enum OverlayPreview {
    static let size = CGSize(width: 1280, height: 800)
    static let window = CGRect(x: 150, y: 80, width: 980, height: 640)

    struct FakeEl { let rect: CGRect; let label: String; let kind: Int }      // 0 button, 1 sidebar row, 2 list row, 3 field, 4 primary
    static let els: [FakeEl] = [
        FakeEl(rect: CGRect(x: 366, y: 90, width: 30, height: 28), label: "􀈎", kind: 0),
        FakeEl(rect: CGRect(x: 402, y: 90, width: 30, height: 28), label: "􀈑", kind: 0),
        FakeEl(rect: CGRect(x: 438, y: 90, width: 30, height: 28), label: "􀉁", kind: 0),
        FakeEl(rect: CGRect(x: 780, y: 90, width: 72, height: 28), label: "Share", kind: 0),
        FakeEl(rect: CGRect(x: 864, y: 90, width: 250, height: 28), label: "Search", kind: 3),
        FakeEl(rect: CGRect(x: 162, y: 140, width: 176, height: 30), label: "Inbox", kind: 1),
        FakeEl(rect: CGRect(x: 162, y: 174, width: 176, height: 30), label: "Drafts", kind: 1),
        FakeEl(rect: CGRect(x: 162, y: 208, width: 176, height: 30), label: "Sent", kind: 1),
        FakeEl(rect: CGRect(x: 162, y: 242, width: 176, height: 30), label: "Archive", kind: 1),
        FakeEl(rect: CGRect(x: 366, y: 140, width: 748, height: 58), label: "Quarterly filter service", kind: 2),
        FakeEl(rect: CGRect(x: 366, y: 204, width: 748, height: 58), label: "Pump manual, section 4", kind: 2),
        FakeEl(rect: CGRect(x: 366, y: 268, width: 748, height: 58), label: "Notes from Tuesday", kind: 2),
        FakeEl(rect: CGRect(x: 366, y: 664, width: 620, height: 36), label: "Write a reply", kind: 3),
        FakeEl(rect: CGRect(x: 998, y: 664, width: 116, height: 36), label: "Send", kind: 4),
    ]
    static func mid(_ i: Int) -> CGPoint { CGPoint(x: els[i].rect.midX, y: els[i].rect.midY) }

    @MainActor static func model(_ setup: (OverlayModel, Date) -> Void) -> (OverlayModel, Date) {
        let m = OverlayModel(), now = Date()
        m.screen = size; m.placed = true; m.cursorVisible = true
        setup(m, now)
        return (m, now)
    }

    @MainActor static func write<V: View>(_ view: V, _ name: String, to dir: URL, scale: CGFloat = 2) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        r.scale = scale
        guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent(name))
    }

    @MainActor static func shot<Extra: View>(_ name: String, to dir: URL, _ m: OverlayModel, _ now: Date, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        write(ZStack(alignment: .topLeading) { FakeDesktop(); OverlayRoot(model: m, fixedNow: now); extra() }.frame(width: size.width, height: size.height).clipped(), name, to: dir)
    }

    @MainActor public static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let idle = model { m, _ in m.tip = CGPoint(x: 640, y: 420); m.bubble = "Looking for the Share button" }
        shot("overlay_idle.png", to: dir, idle.0, idle.1)

        // Mid flight: the dashed guide (preview only) shows the whole arc the cursor follows.
        var arc = Path()
        let fly = model { m, now in
            let probe = Flight(from: CGPoint(x: 300, y: 560), to: mid(3), start: now)
            let f = Flight(from: probe.from, to: probe.to, start: now.addingTimeInterval(-probe.duration * 0.56))
            m.tip = f.from; m.flight = f; m.set(.acting, at: now.addingTimeInterval(-1)); m.bubble = "Opening the share sheet"; arc = f.path
        }
        shot("overlay_flight.png", to: dir, fly.0, fly.1) { arc.stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 5])) }

        let click = model { m, now in
            let pts = [mid(5), mid(10), mid(13)]
            m.steps = pts.enumerated().map { StepDot(id: $0.offset + 1, at: $0.element, prev: $0.offset > 0 ? pts[$0.offset - 1] : nil) }
            m.tip = pts[2]; m.dip = true; m.set(.acting, at: now.addingTimeInterval(-1)); m.bubble = "Sending the reply"
            m.ripples = [Ripple(at: pts[2], start: now.addingTimeInterval(-0.09))]
        }
        shot("overlay_click.png", to: dir, click.0, click.1)

        let xray = model { m, now in
            m.tip = CGPoint(x: 640, y: 470); m.set(.thinking, at: now.addingTimeInterval(-1.75)); m.bubble = "Reading the window"
            m.scan = ScanPass(window: window, frames: els.map(\.rect), bounds: CGRect(origin: .zero, size: size), start: now.addingTimeInterval(-0.40))
        }
        shot("overlay_xray.png", to: dir, xray.0, xray.1)

        let take = model { m, now in
            m.tip = CGPoint(x: 640, y: 470); m.set(.thinking, at: now.addingTimeInterval(-1)); m.bubble = "Taking a look"
            m.takeover = now.addingTimeInterval(-0.42)
        }
        shot("overlay_takeover.png", to: dir, take.0, take.1)

        let target = model { m, now in
            m.tip = mid(3); m.set(.acting, at: now.addingTimeInterval(-1)); m.bubble = "Share"
            m.target = TargetGlow(rect: els[3].rect, start: now.addingTimeInterval(-0.11))
        }
        shot("overlay_target.png", to: dir, target.0, target.1)

        let q = "Open this email draft?", d = "To: sam@example.com\nFilter service on Thursday\n\nHi Sam, the quarterly filter change is booked for Thursday at 9. I will bring the new cartridges."
        let cardSize = NSHostingView(rootView: ApprovalCard(question: q, detail: d)).fittingSize
        var origin = CGPoint.zero
        let ask = model { m, now in
            m.tip = CGPoint(x: 470, y: 300); m.set(.waiting, at: now.addingTimeInterval(-1.35)); m.dim = true
            origin = m.cardOrigin(cardSize)
            m.dimCenter = CGPoint(x: origin.x + cardSize.width / 2, y: origin.y + cardSize.height / 2)
        }
        shot("overlay_approval.png", to: dir, ask.0, ask.1) { ApprovalCard(question: q, detail: d).offset(x: origin.x, y: origin.y) }

        // Close-up of the arrow in each mode, on dark and on light, to judge the shape and contrast.
        let modes: [(CursorMode, Double)] = [(.idle, 1), (.thinking, 1.75), (.acting, 1), (.waiting, 1.35)]
        let strip = ZStack(alignment: .topLeading) {
            Theme.background.frame(width: 280, height: 60)
            Color(white: 0.95).frame(width: 280, height: 60).offset(y: 60)
            ForEach(0..<8, id: \.self) { i in
                let mode = modes[i % 4]
                let pm = model { m, now in m.screen = CGSize(width: 70, height: 60); m.tip = CGPoint(x: 26, y: 20); m.set(mode.0, at: now.addingTimeInterval(-mode.1)) }
                OverlayRoot(model: pm.0, fixedNow: pm.1).frame(width: 70, height: 60, alignment: .topLeading).offset(x: Double(i % 4) * 70, y: Double(i / 4) * 60)
            }
        }
        write(strip.frame(width: 280, height: 120, alignment: .topLeading), "overlay_cursor_zoom.png", to: dir, scale: 8)
    }
}

/// A dark stand-in for an app window on a desktop, drawn from the same rects the x-ray outlines.
struct FakeDesktop: View {
    var body: some View {
        let w = OverlayPreview.window
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.22), Color(red: 0.05, green: 0.07, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Color.black.opacity(0.55).frame(height: 24)
            Text("Mail   File   Edit   View   Message   Window   Help").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8)).offset(x: 44, y: 4)
            ZStack(alignment: .topLeading) {
                Color(red: 0.115, green: 0.12, blue: 0.125)
                Color.white.opacity(0.035).frame(width: 200)
                Color.white.opacity(0.03).frame(height: 48)
                HStack(spacing: 8) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 12, height: 12) } }.offset(x: 16, y: 18)
            }
            .frame(width: w.width, height: w.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            .offset(x: w.minX, y: w.minY)
            ForEach(Array(OverlayPreview.els.enumerated()), id: \.offset) { _, e in
                Text(e.label)
                    .font(.system(size: e.kind == 2 ? 13 : 12, weight: e.kind == 4 ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(e.kind == 3 ? 0.35 : 0.8))
                    .padding(.horizontal, e.kind == 0 ? 0 : 10)
                    .frame(width: e.rect.width, height: e.rect.height, alignment: e.kind == 0 || e.kind == 4 ? .center : .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(e.kind == 4 ? Color(red: 0.2, green: 0.45, blue: 0.95) : Color.white.opacity(e.kind == 1 ? (e.label == "Inbox" ? 0.10 : 0) : 0.06)))
                    .offset(x: e.rect.minX, y: e.rect.minY)
            }
        }
        .frame(width: OverlayPreview.size.width, height: OverlayPreview.size.height, alignment: .topLeading)
    }
}
