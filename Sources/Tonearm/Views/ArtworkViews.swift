import AppKit
import SwiftUI

/// Square cover with rounded corners, or an empty placeholder.
struct CoverView: View {
    var image: NSImage?
    var size: CGFloat

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
                    .font(.system(size: 48))
                    .foregroundColor(PlayerTheme.textSecondary.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Vertical gradient from the cover's main color down to near black.
/// Crossfades when the colors change.
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
            LinearGradient(
                stops: [
                    .init(color: colors.primary.opacity(0.85), location: 0),
                    .init(color: colors.primary.opacity(0.35), location: 0.5),
                    .init(color: colors.primary.opacity(0), location: 0.95),
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
}
