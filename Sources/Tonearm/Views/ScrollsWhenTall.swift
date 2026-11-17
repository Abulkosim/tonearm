import SwiftUI

/// Shows `content` at its own height while that fits under `maxHeight`, and in a scroll view
/// `maxHeight` tall when it doesn't, with soft top and bottom edges so it reads as scrollable.
/// Settings need it: on a short screen they are taller than the window can be, and the rows
/// at the bottom were cut off.
///
/// Give the content at least `edgeTop` of empty space on top and `edgeBottom` below, so the
/// soft edges cover only that space when it is scrolled to either end.
struct ScrollsWhenTall<Content: View>: View {
    static var edgeTop: CGFloat { HeightCap.edgeTop }
    static var edgeBottom: CGFloat { HeightCap.edgeBottom }

    var maxHeight: CGFloat
    /// The color under the content, which the soft edges fade to.
    var background: Color
    /// Snapshots can't draw a ScrollView, because AppKit draws it, so they say how far it is
    /// scrolled, from 0 (top) to 1 (bottom), and get the content moved up instead. Nil in the app.
    var snapshotScroll: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HeightCap(maxHeight: maxHeight, snapshotScroll: snapshotScroll) {
            // A copy that only measures the content's own height. Never drawn and never used.
            content()
                .hidden()
                .disabled(true)
                .accessibilityHidden(true)
            if snapshotScroll == nil {
                ScrollView(.vertical) { content() }
            } else {
                content()
            }
            edge(fromTop: true)
            edge(fromTop: false)
        }
        .clipped()
    }

    private func edge(fromTop: Bool) -> some View {
        LinearGradient(colors: [background, background.opacity(0)],
                       startPoint: fromTop ? .top : .bottom, endPoint: fromTop ? .bottom : .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Lays out the four views of `ScrollsWhenTall`: the measuring copy, the content (or its scroll
/// view), the top edge and the bottom edge.
private struct HeightCap: Layout {
    static let edgeTop: CGFloat = 8
    static let edgeBottom: CGFloat = 12

    var maxHeight: CGFloat
    var snapshotScroll: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let full = natural(width: proposal.width, subviews)
        return CGSize(width: proposal.width ?? full.width, height: min(full.height, max(maxHeight, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let full = natural(width: bounds.width, subviews)
        let overflow = max(0, full.height - bounds.height)
        let fullSize = ProposedViewSize(width: bounds.width, height: full.height)
        subviews[0].place(at: bounds.origin, proposal: fullSize)
        if let snapshotScroll {
            let y = bounds.minY - overflow * min(max(snapshotScroll, 0), 1)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: y), proposal: fullSize)
        } else {
            subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
        // The soft edges show only when there is more to scroll to.
        let top = overflow > 0 ? Self.edgeTop : 0
        let bottom = overflow > 0 ? Self.edgeBottom : 0
        subviews[2].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: top))
        subviews[3].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - bottom),
                          proposal: ProposedViewSize(width: bounds.width, height: bottom))
    }

    private func natural(width: CGFloat?, _ subviews: Subviews) -> CGSize {
        guard let first = subviews.first else { return .zero }
        return first.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}
