import AppKit
import SwiftUI
import OnboardOverlay

struct PillData: Equatable {
    var state = PillState.idle
    var levels: [Float] = [0, 0, 0, 0, 0]     // newest first
    var transcript = ""
}

/// The recording pill: one capsule that morphs between states.
struct VoicePillView: View {
    let data: PillData
    var preview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let profile: [CGFloat] = [0.4, 0.55, 0.7, 0.85, 1, 0.85, 0.7, 0.55, 0.4]

    private var hasText: Bool { data.state == .thinking && !data.transcript.isEmpty }
    private var width: CGFloat? {
        switch data.state {
        case .idle: 44
        case .listening, .speaking: 120
        case .thinking: hasText ? nil : 72
        case .done: 48
        }
    }
    private var height: CGFloat { data.state == .idle ? 10 : 32 }
    private var morph: Animation { reduceMotion ? UI.fade : UI.pillSpring }

    var body: some View {
        ZStack {
            switch data.state {
            case .idle:
                Color.clear
            case .listening:
                levelBars.transition(swap)
            case .thinking:
                HStack(spacing: 9) {
                    ThinkingDots(animated: !preview && !reduceMotion)
                    if hasText {
                        Text(data.transcript)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: 300)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, hasText ? 14 : 0)
                .transition(swap)
            case .speaking:
                SpeakingBars(animated: !preview && !reduceMotion).transition(swap)
            case .done:
                CheckDraw(size: 20, color: Theme.accent, filled: false, animated: !preview).transition(swap)
            }
        }
        .frame(width: width, height: height)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .clipShape(Capsule())
        .overlay(PrismBorder(Capsule(), lineWidth: 1, glow: 4, active: data.state == .listening))
        .shadow(color: .black.opacity(data.state == .idle ? 0 : 0.3), radius: 10, y: 4)
        .animation(morph, value: data.state)
        .animation(morph, value: hasText)
    }

    private var swap: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)) }

    private func barHeight(_ i: Int) -> CGFloat {
        let level: CGFloat = data.levels.isEmpty ? 0 : CGFloat(data.levels[min(abs(i - 4), data.levels.count - 1)])
        // Levels arrive already normalized to 0...1. A little per-bar variation keeps neighbours from moving as one block.
        let wobble: CGFloat = [0.92, 1.0, 0.86, 1.0, 1.0, 0.95, 0.88, 1.0, 0.9][i]
        return 4 + min(level * wobble, 1) * 18 * Self.profile[i]
    }

    private var levelBars: some View {
        HStack(spacing: 3) {
            ForEach(0..<9, id: \.self) { i in
                // The level ripples out from the middle bar: outer bars read slightly older samples.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white)
                    .frame(width: 3, height: barHeight(i))
            }
        }
        .frame(height: 24)
        .animation(.spring(response: 0.16, dampingFraction: 0.7), value: data.levels)
    }
}

struct ThinkingDots: View {
    var animated = true
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { ctx in
            let t = animated ? ctx.date.timeIntervalSinceReferenceDate : 0.35
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let wave: Double = max(0.0, sin(t * 5.2 - Double(i) * 0.9))
                    Circle().fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.30 + 0.70 * wave)
                        .offset(y: -1.5 * wave)
                }
            }
        }
    }
}

struct SpeakingBars: View {
    var animated = true
    static func height(_ i: Int, _ t: Double) -> CGFloat {
        let wave: Double = 0.5 + 0.5 * sin(t * 4.4 - Double(abs(i - 4)) * 0.75)
        let slow: Double = 0.75 + 0.25 * sin(t * 1.7 + Double(i))
        let amount: Double = 0.25 + 0.75 * wave * slow
        return 4 + 16 * VoicePillView.profile[i] * CGFloat(amount)
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animated)) { ctx in
            let t = animated ? ctx.date.timeIntervalSinceReferenceDate : 0.9
            HStack(spacing: 3) {
                ForEach(0..<9, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent)
                        .frame(width: 3, height: Self.height(i, t))
                }
            }
            .frame(height: 24)
        }
    }
}

struct VoicePillHost: View {
    let model: AppModel
    var body: some View {
        VoicePillView(data: PillData(state: model.pill, levels: model.levels, transcript: model.liveTranscript))
            .padding(.bottom, VoicePillController.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .environment(\.colorScheme, .dark)
    }
}

/// A click-through panel that sits bottom center, 24pt above the Dock area.
@MainActor final class VoicePillController {
    static let pad: CGFloat = 16
    private let panel: NSPanel
    private var observer: NSObjectProtocol?

    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: VoicePillHost(model: model))
        host.sizingOptions = []
        panel.contentView = host
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    func show() { place(); panel.orderFrontRegardless() }

    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: (v.midX - size.width / 2).rounded(), y: v.minY + 24 - Self.pad))
    }
}
