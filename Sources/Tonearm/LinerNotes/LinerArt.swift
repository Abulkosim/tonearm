import AppKit
import SwiftUI

/// The colors of a record sleeve: the top and bottom of a tone shift in one hue, dark enough
/// that white text, and white text at `secondaryOpacity`, always reads on both (WCAG 4.5:1).
/// The hero in the window and the share card are painted with it.
struct SleeveColors: Equatable {
    var top: PaletteColor
    var bottom: PaletteColor

    /// Text roles on a sleeve: white, and white at this opacity.
    static let secondaryOpacity = 0.75
    /// Brightest the top may be. White at 75% on it is still above 4.5:1.
    static let maxLuminance = 0.085

    init(top: PaletteColor, bottom: PaletteColor) {
        self.top = top
        self.bottom = bottom
    }

    /// From a cover's palette (see `ArtworkPalette`).
    init(palette: ArtworkPalette) {
        let top = Self.darken(palette.primary, to: Self.maxLuminance)
        let (h, s, v) = top.hsb
        self.init(top: top, bottom: PaletteColor(hue: h, saturation: min(s * 1.05, 0.75), brightness: v * 0.55))
    }

    /// From a cover image, or nil when it has no usable pixels.
    init?(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let palette = ArtworkPalette(image: cg) else { return nil }
        self.init(palette: palette)
    }

    /// The colors of the generated tile for `name`, so a sleeve without a cover matches its tile.
    init(name: String) {
        self.init(palette: ArtworkPalette.tones(for: NameTile.colors(for: name).face))
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [top.color, bottom.color], startPoint: .top, endPoint: .bottom)
    }

    /// Lowers brightness, keeping hue and saturation, until the luminance is at most `limit`.
    static func darken(_ c: PaletteColor, to limit: Double) -> PaletteColor {
        let (h, s, v0) = c.hsb
        var v = v0
        var out = c
        while out.luminance > limit && v > 0.02 {
            v *= 0.95
            out = PaletteColor(hue: h, saturation: s, brightness: v)
        }
        return out
    }

    /// `fg` at `opacity` over `bg`, as drawn.
    static func blend(_ fg: PaletteColor, _ opacity: Double, over bg: PaletteColor) -> PaletteColor {
        PaletteColor(r: fg.r * opacity + bg.r * (1 - opacity), g: fg.g * opacity + bg.g * (1 - opacity),
                     b: fg.b * opacity + bg.b * (1 - opacity))
    }

    static func contrast(_ a: PaletteColor, _ b: PaletteColor) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The lowest contrast of either text role on either end of the sleeve.
    var minimumTextContrast: Double {
        let white = PaletteColor(r: 1, g: 1, b: 1)
        return [top, bottom].flatMap { bg in
            [Self.contrast(white, bg), Self.contrast(Self.blend(white, Self.secondaryOpacity, over: bg), bg)]
        }.min() ?? 0
    }
}

/// A square that stands in for a cover Tonearm never saw: a color field with a record sliding
/// out of the corner and the name's initials. The same name always gets the same tile.
struct NameTile: View {
    var name: String
    var size: CGFloat

    struct Colors {
        var face: PaletteColor
        var disc: PaletteColor
        var label: PaletteColor
    }

    /// Hue and saturation from a hash of the name; brightness set so white initials read.
    static func colors(for name: String) -> Colors {
        let h = UInt64(bitPattern: FNV.hash(name.precomposedStringWithCanonicalMapping))
        let hue = Double(h % 360) / 360
        let saturation = 0.36 + Double((h >> 12) % 26) / 100
        var v = 0.62
        var face = PaletteColor(hue: hue, saturation: saturation, brightness: v)
        while face.luminance > 0.16 && v > 0.1 {
            v *= 0.96
            face = PaletteColor(hue: hue, saturation: saturation, brightness: v)
        }
        let disc = PaletteColor(hue: hue, saturation: min(saturation + 0.1, 0.8), brightness: v * 0.32)
        let label = PaletteColor(hue: hue, saturation: saturation * 0.8, brightness: min(v * 1.25, 0.9))
        return Colors(face: face, disc: disc, label: label)
    }

    /// One or two letters: the first letter of the first two words that start with one.
    static func initials(_ name: String) -> String {
        var letters: [Character] = []
        name.enumerateSubstrings(in: name.startIndex..<name.endIndex, options: .byWords) { word, _, _, stop in
            if let first = word?.first, first.isLetter || first.isNumber {
                letters.append(first)
                if letters.count == 2 { stop = true }
            }
        }
        // CJK words are often a whole name: one character is enough there.
        if let first = letters.first, first.unicodeScalars.first.map({ $0.value >= 0x2E80 }) == true {
            letters = [first]
        }
        if letters.isEmpty, let first = name.trimmingCharacters(in: .whitespaces).first { letters = [first] }
        return String(letters).uppercased()
    }

    var body: some View {
        let c = Self.colors(for: name)
        let disc = size * 1.1
        let label = size * 0.36
        ZStack(alignment: .topLeading) {
            c.face.color
            Circle()
                .fill(c.disc.color)
                .frame(width: disc, height: disc)
                .offset(x: size * 0.38, y: size * 0.34)
            Circle()
                .fill(c.label.color)
                .frame(width: label, height: label)
                .offset(x: size * 0.93 - label / 2, y: size * 0.89 - label / 2)
            if size >= 28 {
                Text(Self.initials(name))
                    // Big tiles keep the letters small, so a shelf of them stays quiet.
                    .font(LinerType.serif(min(size * 0.3, 26)))
                    .foregroundColor(.white.opacity(0.94))
                    .lineLimit(1)
                    .padding(.leading, size * 0.11)
                    .padding(.top, size * 0.08)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A cover when Tonearm has one, the name's tile when not.
struct ArtTile: View {
    var image: NSImage?
    var name: String
    var size: CGFloat
    var radius: CGFloat = 4

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                NameTile(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// The small Tonearm mark for the share card: a black record with the icon's orange label.
struct TonearmMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(.sRGB, red: 0.05, green: 0.05, blue: 0.055, opacity: 1))
            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: max(1, size * 0.02))
                .padding(size * 0.16)
            Circle().fill(LinerPalette.rgb(0xE8863F)).frame(width: size * 0.4, height: size * 0.4)
            Circle().fill(Color.black.opacity(0.85)).frame(width: size * 0.07, height: size * 0.07)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A cover or tile as wide as the space it is given, and as tall. Stacks first measure their
/// children with an infinite width; then it answers with `fallback`, so it never grows without
/// bound the way `aspectRatio` does.
struct SquareArt: View {
    var image: NSImage?
    var name: String
    var radius: CGFloat = 6
    var fallback: CGFloat = 160

    var body: some View {
        SquareLayout(fallback: fallback) {
            GeometryReader { geo in
                ArtTile(image: image, name: name, size: geo.size.width, radius: radius)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SquareLayout: Layout {
    var fallback: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width.map { $0.isFinite ? $0 : fallback } ?? fallback
        return CGSize(width: w, height: w)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let side = bounds.width
        for view in subviews {
            view.place(at: bounds.origin, proposal: ProposedViewSize(width: side, height: side))
        }
    }
}
