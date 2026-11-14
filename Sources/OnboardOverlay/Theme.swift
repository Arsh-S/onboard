import SwiftUI

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
    public static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    public static let snappy = Animation.spring(response: 0.25, dampingFraction: 1.0)
    public static let pop = Animation.spring(response: 0.4, dampingFraction: 0.6)
}
