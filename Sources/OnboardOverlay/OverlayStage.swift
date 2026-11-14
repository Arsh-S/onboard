import AppKit
import OnboardCore

/// STUB: the on-screen stage (agent cursor, x-ray scan, ripples, approval card). To be implemented.
@MainActor public final class OverlayStage: AgentStage {
    public static let shared = OverlayStage()
    /// Called when the agent wants to say something (the UI speaks it and shows it).
    public var onSpeak: ((String) async -> Void)?
    public init() {}
    public func scan(window: CGRect, elements: [UIElement]) async {}
    public func glide(to: CGPoint, frame: CGRect?, thought: String) async {}
    public func click(at: CGPoint) async {}
    public func thought(_ text: String) {}
    public func speak(_ text: String) async { await onSpeak?(text) }
    public func approve(_ question: String, detail: String) async -> Bool { true }
    public func rest() {}
}

public enum OverlayPreview {
    @MainActor public static func render(to dir: URL) {}
}
