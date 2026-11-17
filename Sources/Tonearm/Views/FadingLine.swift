import SwiftUI

/// One line of text. When it is too long for its space it fades out at its end instead of
/// stopping mid-word at an ellipsis. Right-to-left text keeps its start, on the right, and
/// fades on the left.
struct FadingLine: View {
    var text: Text
    var rightToLeft: Bool

    /// Width of the fade at the cut end.
    static let fade: CGFloat = 28

    init(_ text: Text, string: String) {
        self.text = text
        rightToLeft = Self.startsRightToLeft(string)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Right-to-left text sits on the right whether it fits or not, so the lines of
            // one song line up.
            text
                .lineLimit(1)
                .frame(maxWidth: rightToLeft ? .infinity : nil, alignment: .trailing)
            text
                .lineLimit(1)
                .fixedSize()
                // minWidth 0: take the width offered, not the text's whole width.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
                .clipped()
                .mask(mask)
        }
    }

    private var mask: some View {
        HStack(spacing: 0) {
            if rightToLeft { edge(startPoint: .leading, endPoint: .trailing) }
            Color.black
            if !rightToLeft { edge(startPoint: .trailing, endPoint: .leading) }
        }
    }

    private func edge(startPoint: UnitPoint, endPoint: UnitPoint) -> some View {
        LinearGradient(colors: [.clear, .black], startPoint: startPoint, endPoint: endPoint)
            .frame(width: Self.fade)
    }

    /// True when the first letter is from a right-to-left script (Hebrew, Arabic, Syriac,
    /// Thaana, N'Ko and their presentation forms), the way the text system picks a paragraph's
    /// direction. Pure, for tests.
    static func startsRightToLeft(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                if scalar.properties.isAlphabetic { return false }
            }
        }
        return false
    }
}
