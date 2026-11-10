import AppKit
import SwiftUI

/// Settings panel shown inside the popover. Takes no arguments and reads the
/// `AppSettings.shared` and `LaunchAtLogin.shared` singletons, so it needs no
/// environment objects. It has no outer padding or background: the host adds them.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var login = LaunchAtLogin.shared

    static let repoURL = URL(string: "https://github.com/Abulkosim/tonearm")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Menu bar") {
                SegmentedChoice(selection: $settings.menuBarStyle, options: [
                    .init(value: .songTitle, title: "Song title"),
                    .init(value: .iconOnly, title: "Icon only"),
                ])
            }
            if settings.menuBarStyle == .songTitle {
                row("Show artist") {
                    GreenSwitch(isOn: $settings.showArtist, label: "Show artist")
                }
                .transition(.opacity)
                row("Title length") {
                    LengthStepper(value: $settings.maxTitleLength)
                }
                .transition(.opacity)
            }
            row("Launch at login") {
                GreenSwitch(isOn: Binding(get: { login.isOn }, set: { login.setEnabled($0) }),
                            label: "Launch at login")
            }
            if login.needsApproval {
                HStack(spacing: 8) {
                    Text("Needs approval in System Settings")
                        .foregroundColor(Theme.secondary)
                    Spacer(minLength: 8)
                    Button("Open Login Items", action: login.openLoginItems)
                        .buttonStyle(QuietButtonStyle(color: Theme.accent, hover: Theme.accentHover))
                }
                .font(.system(size: 12))
                .frame(height: 24)
                .padding(.bottom, 4)
            }

            Theme.hairline
                .frame(height: 1)
                .padding(.vertical, 8)

            Button(action: { NSApp.terminate(nil) }) {
                HStack {
                    Text("Quit Tonearm")
                    Spacer()
                    Keycap(text: "⌘Q")
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle(color: .white, hover: .white, hoverFill: true))
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, -8)

            HStack {
                Text("Version \(Self.version)")
                    .foregroundColor(Theme.muted)
                Spacer()
                Button("Source on GitHub") { NSWorkspace.shared.open(Self.repoURL) }
                    .buttonStyle(QuietButtonStyle(color: Theme.secondary, hover: .white))
            }
            .font(.system(size: 12))
            .frame(height: 24)
            .padding(.top, 4)
        }
        .font(.system(size: 13))
        .foregroundColor(.white)
        .animation(.easeOut(duration: 0.15), value: settings.menuBarStyle)
        .animation(.easeOut(duration: 0.15), value: login.needsApproval)
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 0)
            content()
        }
        .frame(height: 32)
    }
}

// MARK: - Theme

private enum Theme {
    static let accent = Color(red: 0x1E / 255, green: 0xD7 / 255, blue: 0x60 / 255)
    static let accentHover = Color(red: 0x3B / 255, green: 0xE4 / 255, blue: 0x77 / 255)
    static let secondary = Color(white: 0.70)
    static let muted = Color(white: 0.50)
    static let hairline = Color.white.opacity(0.08)
    static let ease = Animation.easeOut(duration: 0.15)
}

// MARK: - Controls

/// Two or more text segments; the selected one sits on a raised surface.
private struct SegmentedChoice<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(Theme.ease) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle(color: selected ? .white : Theme.secondary, hover: .white))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// A 30x18 switch: grey track when off, green when on, white knob that slides.
private struct GreenSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            withAnimation(Theme.ease) { isOn.toggle() }
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? Theme.accent : Color.white.opacity(0.22))
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: isOn ? 6 : -6)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
            .animation(Theme.ease, value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// "− 30 +" control for the menu bar title length.
private struct LengthStepper: View {
    @Binding var value: Int

    private let range = AppSettings.titleLengthRange
    private let step = AppSettings.titleLengthStep

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", label: "Shorter", enabled: value > range.lowerBound) {
                value = AppSettings.clampLength(value - step)
            }
            Text("\(value)")
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 24)
                .accessibilityLabel("Title length \(value) characters")
            stepButton("plus", label: "Longer", enabled: value < range.upperBound) {
                value = AppSettings.clampLength(value + step)
            }
        }
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(color: enabled ? Theme.secondary : Theme.muted.opacity(0.6),
                                      hover: enabled ? .white : Theme.muted.opacity(0.6),
                                      hoverFill: enabled))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Theme.muted)
            .padding(.horizontal, 4)
            .frame(height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

/// Plain text button: colour change on hover, optional faint surface, dims when pressed.
private struct QuietButtonStyle: ButtonStyle {
    var color: Color
    var hover: Color
    var hoverFill = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, color: color, hover: hover, hoverFill: hoverFill)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let color: Color
    let hover: Color
    let hoverFill: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundColor(hovering ? hover : color)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(hoverFill && hovering ? 0.06 : 0))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Snapshot

extension SettingsView {
    /// Renders the panel to a PNG next to the player snapshot, for CI.
    @MainActor
    static func renderSnapshot(to url: URL) {
        let content = SettingsView()
            .padding(16)
            .frame(width: 300)
            .background(Color(red: 0.07, green: 0.07, blue: 0.07))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write("snapshot: settings render failed\n".data(using: .utf8)!)
            return
        }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }
}
