import SwiftUI

/// Colors, timings and formatting shared by the player views.
enum PlayerTheme {
    static let green = rgb(0x1E, 0xD7, 0x60)
    static let greenHover = rgb(0x3B, 0xE4, 0x77)
    /// Bottom of the background gradient.
    static let base = rgb(0x12, 0x12, 0x12)
    /// Background when there are no artwork colors.
    static let fallback = rgb(0x18, 0x18, 0x18)
    static let placeholder = rgb(0x28, 0x28, 0x28)
    static let textSecondary = rgb(0xB3, 0xB3, 0xB3)
    static let barTrack = Color.white.opacity(0.3)
    static let hairline = Color.white.opacity(0.08)

    /// Corner radius of the popover window: 10pt like system menus before macOS 26,
    /// rounder on macOS 26.
    static var windowRadius: CGFloat {
        if #available(macOS 26, *) { return 14 }
        return 10
    }

    /// Hover and press feedback.
    static let quick = Animation.easeOut(duration: 0.15)
    /// Glyph and panel changes.
    static let medium = Animation.easeOut(duration: 0.2)
    /// Cover crossfade.
    static let fade = Animation.easeInOut(duration: 0.35)
    /// Background color crossfade.
    static let slowFade = Animation.easeInOut(duration: 0.6)

    /// `m:ss`, or `h:mm:ss` past an hour.
    static func time(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}
