import SwiftUI

/// Thin progress or volume bar. At rest it is a 4pt white line on a grey track.
/// On hover or drag the fill turns green, the bar thickens and a white knob appears.
struct ScrubBar: View {
    /// 0...1
    var value: Double
    var accessibilityLabel: String
    var accessibilityValueText: String
    /// Shows the hover look without a pointer. Used by snapshots.
    var forceActive = false
    /// Step for VoiceOver increment and decrement.
    var step = 0.05
    /// Called while dragging with the dragged value.
    var onScrub: ((Double) -> Void)?
    /// Called once when the drag ends.
    var onCommit: (Double) -> Void

    init(
        value: Double,
        accessibilityLabel: String,
        accessibilityValueText: String,
        forceActive: Bool = false,
        step: Double = 0.05,
        onScrub: ((Double) -> Void)? = nil,
        onCommit: @escaping (Double) -> Void
    ) {
        self.value = value
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValueText = accessibilityValueText
        self.forceActive = forceActive
        self.step = step
        self.onScrub = onScrub
        self.onCommit = onCommit
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dragValue: Double?
    /// Holds the released value until the model catches up, so the bar does not jump back.
    @State private var pendingValue: Double?

    private static let knob: CGFloat = 12
    private static let thickness: CGFloat = 4

    private var active: Bool {
        isEnabled && (hovering || dragValue != nil || forceActive)
    }

    private var shown: Double {
        min(max(dragValue ?? pendingValue ?? value, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fill = width * shown
            ZStack(alignment: .leading) {
                Capsule().fill(PlayerTheme.barTrack)
                Capsule()
                    .fill(active ? PlayerTheme.green : Color.white)
                    .frame(width: fill > 0 ? max(Self.thickness, fill) : 0)
            }
            .frame(height: Self.thickness)
            .scaleEffect(x: 1, y: active && !reduceMotion ? 1.5 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: fill - Self.knob / 2)
                    .opacity(active ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(drag(width: width))
        }
        .frame(height: Self.knob)
        .onHover { hovering = $0 }
        .animation(PlayerTheme.quick, value: active)
        .onChange(of: value) { newValue in
            if let p = pendingValue, abs(newValue - p) < 0.02 { pendingValue = nil }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(min(1, value + step))
            case .decrement: onCommit(max(0, value - step))
            @unknown default: break
            }
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard isEnabled, width > 0 else { return }
                let v = min(max(g.location.x / width, 0), 1)
                dragValue = v
                onScrub?(v)
            }
            .onEnded { g in
                // Cleared first, so a bar disabled mid-drag never stays frozen.
                dragValue = nil
                guard isEnabled, width > 0 else { return }
                let v = min(max(g.location.x / width, 0), 1)
                pendingValue = v
                onCommit(v)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if pendingValue == v { pendingValue = nil }
                }
            }
    }
}
