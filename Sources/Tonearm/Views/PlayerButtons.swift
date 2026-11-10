import SwiftUI

/// Grey glyph that turns white on hover and shrinks a little on press.
struct IconButtonStyle: ButtonStyle {
    /// Keeps the glyph white, for a toggle that is on.
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, isActive: isActive)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool
    @State var hovering = false
    @Environment(\.isEnabled) var isEnabled
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        configuration.label
            .foregroundColor(color)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .onHover { hovering = $0 }
            .animation(PlayerTheme.quick, value: hovering)
            .animation(PlayerTheme.quick, value: configuration.isPressed)
    }

    private var color: Color {
        guard isEnabled else { return PlayerTheme.textSecondary.opacity(0.4) }
        return hovering || isActive || configuration.isPressed ? .white : PlayerTheme.textSecondary
    }
}

/// The round green play button.
struct PlayButtonStyle: ButtonStyle {
    var diameter: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        PlayButtonBody(configuration: configuration, diameter: diameter)
    }
}

private struct PlayButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    @State var hovering = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        configuration.label
            .foregroundColor(.black)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(hovering ? PlayerTheme.greenHover : PlayerTheme.green))
            .contentShape(Circle())
            .scaleEffect(scale)
            .onHover { hovering = $0 }
            .animation(PlayerTheme.quick, value: hovering)
            .animation(PlayerTheme.quick, value: configuration.isPressed)
    }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if configuration.isPressed { return 0.94 }
        return hovering ? 1.06 : 1
    }
}

/// Green capsule for the one main action on a status screen.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State var hovering = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.isEnabled) var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 20)
            .frame(height: 32)
            .background(Capsule().fill(hovering && isEnabled ? PlayerTheme.greenHover : PlayerTheme.green))
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .onHover { hovering = $0 }
            .animation(PlayerTheme.quick, value: hovering)
            .animation(PlayerTheme.quick, value: configuration.isPressed)
    }
}

/// Plain text action: grey, white on hover.
struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration)
    }
}

private struct TextButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(hovering || configuration.isPressed ? .white : PlayerTheme.textSecondary)
            .frame(height: 24)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(PlayerTheme.quick, value: hovering)
    }
}

/// Play and pause glyph that morphs when the state flips.
struct PlayPauseGlyph: View {
    var isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 14, *) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            } else {
                ZStack {
                    Image(systemName: "pause.fill")
                        .opacity(isPlaying ? 1 : 0)
                        .scaleEffect(reduceMotion || isPlaying ? 1 : 0.6)
                    Image(systemName: "play.fill")
                        .opacity(isPlaying ? 0 : 1)
                        .scaleEffect(reduceMotion || !isPlaying ? 1 : 0.6)
                }
            }
        }
        // The play triangle reads as off-center without a small nudge.
        .offset(x: isPlaying ? 0 : 1)
        .animation(PlayerTheme.medium, value: isPlaying)
    }
}
