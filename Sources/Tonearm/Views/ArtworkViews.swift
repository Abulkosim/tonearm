import AppKit
import SwiftUI

/// Square cover with rounded corners, or an empty placeholder.
struct CoverView: View {
    var image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                PlayerTheme.placeholder
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.18))
                    .foregroundColor(PlayerTheme.textSecondary.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Spotify's now-playing look: the cover's main color, deepened, fading down into #121212.
/// Without colors it is the plain neutral surface. Crossfades when the colors change.
struct ArtworkBackground: View {
    var colors: ArtworkColors?

    var body: some View {
        ZStack {
            PlayerTheme.base
            layer
                .id(key)
                .transition(.opacity)
        }
        .animation(PlayerTheme.slowFade, value: key)
    }

    @ViewBuilder private var layer: some View {
        if let colors {
            let top = Self.deepen(colors.primary)
            LinearGradient(
                stops: [
                    .init(color: top, location: 0),
                    .init(color: top.opacity(0.8), location: 0.3),
                    .init(color: top.opacity(0.42), location: 0.6),
                    .init(color: top.opacity(0.12), location: 0.85),
                    .init(color: top.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            PlayerTheme.fallback
        }
    }

    /// Identity of the current colors. ArtworkColors is not required to be Equatable.
    private var key: String {
        guard let colors else { return "none" }
        return "\(colors.primary)|\(colors.secondary)"
    }

    /// Same hue, more saturated and darker, so the tint reads as a color rather than as
    /// brownish grey, and white text on it stays easy to read. Grey covers stay grey.
    static func deepen(_ color: Color) -> Color {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let sat = s < 0.12 ? s : min(max(s * 1.3, 0.55), 0.85)
        var v = 0.5
        var out = PaletteColor(hue: Double(h), saturation: Double(sat), brightness: v)
        while out.luminance > 0.06 && v > 0.1 {
            v *= 0.94
            out = PaletteColor(hue: Double(h), saturation: Double(sat), brightness: v)
        }
        return out.color
    }
}

/// Buttons shown on the cover while the pointer is over it.
struct CoverActions: View {
    var canCopy: Bool
    var copied: Bool
    var open: () -> Void
    var copy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if copied {
                Text("Copied")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .transition(.opacity)
            }
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "link")
            }
            .buttonStyle(CoverButtonStyle())
            .disabled(!canCopy)
            .help("Copy song link")
            .accessibilityLabel("Copy song link")

            Button(action: open) {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(CoverButtonStyle())
            .help("Open in Spotify")
            .accessibilityLabel("Open in Spotify")
        }
        .animation(PlayerTheme.medium, value: copied)
    }
}
