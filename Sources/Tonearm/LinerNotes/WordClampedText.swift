import SwiftUI

/// Text that wraps to at most `lines` lines and, when it is longer, ends at a whole word with
/// an ellipsis. SwiftUI's own truncation cuts mid-word ("Константинопо…"), which reads as a
/// bug in a name. Words come from the system's word breaker, so Japanese and Chinese names,
/// which have no spaces, still break between words. An option only fits if each of its words
/// fits on a line; when even the first word is wider than the line (a 40-letter name), the
/// text sits on one line, set smaller.
struct WordClampedText: View {
    var text: String
    var font: Font
    var lines: Int = 1
    var color: Color

    var body: some View {
        let options = Self.candidates(text)
        WordClampLayout(lines: lines) {
            // A one-line probe in the same font, for the height of a line.
            Text("Ag").font(font).lineLimit(1).hidden()
            // The last resort: the whole text on one line, scaled down until it fits.
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            // Each option, then its longest word on one line.
            ForEach(Array(options.enumerated()), id: \.offset) { _, s in
                Text(s)
                    .font(font)
                    .foregroundColor(color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.longestWord(s)).font(font).lineLimit(1).fixedSize().hidden()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .help(text)
    }

    static let maxCandidates = 40
    private static let trailing = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",.;:-–—(/·&+|[{\"'«“、。・，"))

    static func longestWord(_ text: String) -> String {
        var longest = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            if let word, word.count > longest.count { longest = word }
        }
        return longest
    }

    /// The whole text, then shorter and shorter word prefixes with an ellipsis, longest first.
    static func candidates(_ text: String) -> [String] {
        var ends: [String.Index] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) {
            _, range, _, _ in ends.append(range.upperBound)
        }
        var out = [text]
        // Every word end but the last: cutting after the last word would only drop punctuation.
        for end in ends.dropLast().reversed() {
            var prefix = String(text[..<end])
            while let last = prefix.unicodeScalars.last, trailing.contains(last) {
                prefix.unicodeScalars.removeLast()
            }
            guard !prefix.isEmpty else { continue }
            let option = prefix + "…"
            if option != out.last { out.append(option) }
            if out.count >= maxCandidates { break }
        }
        return out
    }
}

/// Subview 0 gives the line height, subview 1 is the scaled last resort, then come pairs of
/// (option, its longest word). Shows the first option that fits in `lines` lines at the
/// offered width with every word on a line, else the last resort. The others are placed far
/// outside the bounds, where nothing draws them.
private struct WordClampLayout: Layout {
    var lines: Int

    private static let scaled = 1
    private static let firstOption = 2

    private func chosen(width: CGFloat?, _ subviews: Subviews) -> Int {
        guard subviews.count >= Self.firstOption + 2 else { return 0 }
        let line = subviews[0].sizeThatFits(.unspecified).height
        let limit = line * CGFloat(lines) + line * 0.5
        let proposal = ProposedViewSize(width: width, height: nil)
        let maxWidth = width.map { $0.isFinite ? $0 + 0.5 : .infinity } ?? .infinity
        for i in stride(from: Self.firstOption, to: subviews.count - 1, by: 2)
        where subviews[i + 1].sizeThatFits(.unspecified).width <= maxWidth
            && subviews[i].sizeThatFits(proposal).height <= limit {
            return i
        }
        return Self.scaled
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let i = chosen(width: proposal.width, subviews)
        guard i >= Self.scaled else { return .zero }
        let size = subviews[i].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: min(size.width, proposal.width ?? size.width), height: size.height)
    }

    // Alignment guides (baselines, leading) come from the shown option alone. By default a
    // layout merges every subview's guides, and the hidden ones sit 100,000 points away.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        let i = chosen(width: bounds.width, subviews)
        guard i >= Self.scaled else { return nil }
        return bounds.minY + subviews[i].dimensions(in: ProposedViewSize(width: bounds.width, height: nil))[guide]
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        let i = chosen(width: bounds.width, subviews)
        guard i >= Self.scaled else { return nil }
        return bounds.minX + subviews[i].dimensions(in: ProposedViewSize(width: bounds.width, height: nil))[guide]
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let i = chosen(width: bounds.width, subviews)
        let away = CGPoint(x: bounds.minX - 100_000, y: bounds.minY - 100_000)
        for (k, view) in subviews.enumerated() {
            if k == i && k >= Self.scaled {
                view.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
            } else {
                view.place(at: away, proposal: ProposedViewSize(width: bounds.width, height: nil))
            }
        }
    }
}
