import SwiftUI

/// Text that wraps to at most `lines` lines and, when it is longer, ends at a whole word with
/// an ellipsis. SwiftUI's own truncation cuts mid-word ("Константинопо…"), which reads as a
/// bug in a name. Words come from the system's word breaker, so Japanese and Chinese names,
/// which have no spaces, still break between words: inside a word their characters are
/// glued with WORD JOINER, or the text system would wrap between any two of them. An option
/// only fits if each of its words fits on a line; when even the first word is wider than
/// the line (a 40-letter name), the text sits on one line, a little smaller, and is cut.
struct WordClampedText: View {
    var text: String
    var font: Font
    var lines: Int = 1
    var color: Color

    /// The smallest the last resort is set, as a share of `font`. Any smaller can't be read.
    static let minimumScale: CGFloat = 0.8

    var body: some View {
        let options = Self.candidates(text)
        WordClampLayout(lines: lines) {
            // A one-line probe in the same font, for the height and baseline of a line.
            Text("Ag").font(font).lineLimit(1).hidden()
            // The last resort: the whole text on one line, a little smaller, cut at the end.
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(Self.minimumScale)
                .truncationMode(.tail)
            // Each option, then its longest word on one line.
            ForEach(Array(options.enumerated()), id: \.offset) { _, s in
                Text(Self.joinWords(s))
                    .font(font)
                    .foregroundColor(color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.joinWords(Self.longestWord(s))).font(font).lineLimit(1).fixedSize().hidden()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .help(text)
    }

    static let maxCandidates = 40
    static let wordJoiner = "\u{2060}"
    private static let trailing = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",.;:-–—(/·&+|[{\"'«“、。・，"))

    static func longestWord(_ text: String) -> String {
        var longest = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            if let word, word.count > longest.count { longest = word }
        }
        return longest
    }

    /// `text` with WORD JOINER between the characters of each word in a script that may
    /// break between any two characters (Chinese, Japanese, Korean), so lines break only
    /// between words. Other words are left alone: they don't break inside, and a joiner
    /// could split a ligature.
    static func joinWords(_ text: String) -> String {
        var out = ""
        var cursor = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            out += text[cursor..<range.lowerBound]
            if word.count > 1, word.unicodeScalars.contains(where: breaksAnywhere) {
                out += word.map(String.init).joined(separator: wordJoiner)
            } else {
                out += word
            }
            cursor = range.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// Han, kana, Hangul and their marks: the text system may break between any two of these.
    static func breaksAnywhere(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3031...0x3035,
             0x3040...0x30FF, 0x3130...0x318F, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFF66...0xFFDC, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
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
/// offered width with every word on a line, else the last resort, which keeps a full line's
/// height and baseline so whatever sits under it stays in line with its neighbours. The
/// others are placed far outside the bounds, where nothing draws them.
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
        let height = i == Self.scaled ? max(size.height, subviews[0].sizeThatFits(.unspecified).height) : size.height
        return CGSize(width: min(size.width, proposal.width ?? size.width), height: height)
    }

    // Alignment guides (baselines, leading) come from the shown option alone. By default a
    // layout merges every subview's guides, and the hidden ones sit 100,000 points away.
    // The last resort answers with the probe's, the line it stands in for.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        let i = chosen(width: bounds.width, subviews)
        guard i >= Self.scaled else { return nil }
        if i == Self.scaled { return bounds.minY + subviews[0].dimensions(in: .unspecified)[guide] }
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
        let width = ProposedViewSize(width: bounds.width, height: nil)
        for (k, view) in subviews.enumerated() {
            if k == i && k == Self.scaled {
                // Smaller type, on the baseline a full-size line would have.
                let shift = subviews[0].dimensions(in: .unspecified)[.firstTextBaseline]
                    - view.dimensions(in: width)[.firstTextBaseline]
                view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + max(0, shift)), proposal: width)
            } else if k == i && k > Self.scaled {
                view.place(at: bounds.origin, proposal: width)
            } else {
                view.place(at: away, proposal: width)
            }
        }
    }
}
