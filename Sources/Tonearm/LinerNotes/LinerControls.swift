import AppKit
import SwiftUI

// Controls for the Liner Notes window, drawn in SwiftUI rather than by AppKit, so they look
// the same in the window and in the snapshots CI renders (ImageRenderer can't draw AppKit).

/// A filled button for the one main action, or a quiet one with a hairline.
struct LinerButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        LinerButtonBody(configuration: configuration, kind: kind, large: large)
    }
}

private struct LinerButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: LinerButtonStyle.Kind
    let large: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let p = LinerPalette(scheme)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .medium))
            .foregroundColor(kind == .primary ? p.buttonText : p.primary)
            .lineLimit(1)
            .padding(.horizontal, large ? 20 : 12)
            .frame(height: large ? 40 : 28)
            .background(shape.fill(kind == .primary ? p.buttonFill : (hovering ? p.raised : Color.clear)))
            .overlay(shape.strokeBorder(kind == .primary ? Color.clear : p.hairline, lineWidth: 1))
            .overlay(shape.strokeBorder(p.accent, lineWidth: isFocused ? 2 : 0))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : (hovering && kind == .primary ? 0.9 : 1)) : 0.4)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(PlayerTheme.quick, value: hovering)
    }
}

/// A glyph button, 28 pt square, that gets a surface on hover.
struct LinerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinerIconBody(configuration: configuration)
    }
}

private struct LinerIconBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let p = LinerPalette(scheme)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isEnabled ? (hovering ? p.primary : p.secondary) : p.muted.opacity(0.5))
            .frame(minWidth: 28, minHeight: 28)
            .background(shape.fill(hovering && isEnabled ? p.raised : Color.clear))
            .overlay(shape.strokeBorder(p.accent, lineWidth: isFocused ? 2 : 0))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(PlayerTheme.quick, value: hovering)
    }
}

/// Week / Month / Year / All time. The selected one is a raised surface with a hairline.
struct KindPicker: View {
    var selection: Period.Kind
    var choose: (Period.Kind) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = LinerPalette(scheme)
        HStack(spacing: 2) {
            ForEach(Array(Period.Kind.allCases.enumerated()), id: \.element) { i, kind in
                Button { choose(kind) } label: {
                    Text(kind.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(kind == selection ? p.primary : p.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(kind == selection ? p.page : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(kind == selection ? p.hairline : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .help("\(kind.label) (⌘\(i + 1))")
                .accessibilityAddTraits(kind == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.raised))
    }
}

/// A native pop-up menu at the pointer, for the list of years.
@MainActor
final class LinerMenu: NSObject {
    private var handler: (Int) -> Void = { _ in }

    /// Items are (title, tag, checked); a nil entry is a separator.
    func show(_ items: [(String, Int, Bool)?], pick: @escaping (Int) -> Void) {
        handler = pick
        let menu = NSMenu()
        for entry in items {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let (title, tag, checked) = entry
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func choose(_ sender: NSMenuItem) { handler(sender.tag) }
}
