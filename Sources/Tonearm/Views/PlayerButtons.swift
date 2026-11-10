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
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundColor(color)
            .contentShape(Rectangle())
            .focusOutline(RoundedRectangle(cornerRadius: 4, style: .continuous), isFocused: isFocused)
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
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundColor(.black)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(hovering ? PlayerTheme.greenHover : PlayerTheme.green))
            .contentShape(Circle())
            .focusOutline(Circle().inset(by: -3), isFocused: isFocused)
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
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.black)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 20)
            .frame(height: 32)
            .background(Capsule().fill(hovering && isEnabled ? PlayerTheme.greenHover : PlayerTheme.green))
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Capsule())
            .focusOutline(Capsule().inset(by: -3), isFocused: isFocused)
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
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(hovering || configuration.isPressed ? .white : PlayerTheme.textSecondary)
            .frame(height: 24)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .focusOutline(RoundedRectangle(cornerRadius: 4, style: .continuous), isFocused: isFocused)
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

/// Shuffle and repeat: grey when off, green with a small dot under the glyph when on.
struct ModeButtonStyle: ButtonStyle {
    var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        ModeButtonBody(configuration: configuration, isOn: isOn)
    }
}

private struct ModeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @State var hovering = false
    @Environment(\.isEnabled) var isEnabled
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottom) {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .padding(.bottom, 2)
                    .opacity(isOn ? 1 : 0)
            }
            .contentShape(Rectangle())
            .focusOutline(RoundedRectangle(cornerRadius: 6, style: .continuous), isFocused: isFocused)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .onHover { hovering = $0 }
            .animation(PlayerTheme.quick, value: hovering)
            .animation(PlayerTheme.quick, value: isOn)
            .animation(PlayerTheme.quick, value: configuration.isPressed)
    }

    private var color: Color {
        guard isEnabled else { return PlayerTheme.textSecondary.opacity(0.4) }
        if isOn { return hovering ? PlayerTheme.greenHover : PlayerTheme.green }
        return hovering ? .white : PlayerTheme.textSecondary
    }
}

/// Small dark round button that sits on the cover.
struct CoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CoverButtonBody(configuration: configuration)
    }
}

private struct CoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State var hovering = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.black.opacity(hovering ? 0.8 : 0.6)))
            .contentShape(Circle())
            .focusOutline(Circle(), isFocused: isFocused)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .onHover { hovering = $0 }
            .animation(PlayerTheme.quick, value: hovering)
            .animation(PlayerTheme.quick, value: configuration.isPressed)
    }
}

/// Text that acts as a link: underlined on hover, like song titles in Spotify.
struct LinkText: View {
    var text: String
    var font: Font
    var color: Color
    var enabled = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(font)
                .foregroundColor(color)
                .underline(hovering && enabled)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(PressDimStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// Shows the label as is and dims it while pressed.
struct PressDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressDimBody(configuration: configuration)
    }
}

private struct PressDimBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .focusOutline(RoundedRectangle(cornerRadius: 4, style: .continuous).inset(by: -2), isFocused: isFocused)
    }
}
