import AppKit
import OnboardCore
import OnboardOverlay

/// STUB: the app shell (menu bar item, command bar, voice pill). To be implemented.
public enum OnboardApp {
    @MainActor public static func run() { print("Onboard UI not built yet"); exit(0) }
}

public enum UIPreview {
    @MainActor public static func render(to dir: URL) {}
}
