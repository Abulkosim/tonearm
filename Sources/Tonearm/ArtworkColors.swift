import AppKit
import ImageIO
import SwiftUI

/// Background colors derived from the cover: a muted, saturated `primary` and a darker
/// `secondary` of the same hue. Both are dark enough for white text.
struct ArtworkColors: Equatable {
    var primary: Color
    var secondary: Color
}

extension ArtworkColors {
    init(palette: ArtworkPalette) {
        primary = palette.primary.color
        secondary = palette.secondary.color
    }

    init?(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let palette = ArtworkPalette(image: cg)
        else { return nil }
        self.init(palette: palette)
    }

    /// Decodes a small thumbnail straight from encoded image data. Safe off the main thread.
    init?(data: Data) {
        guard let palette = ArtworkPalette(data: data) else { return nil }
        self.init(palette: palette)
    }
}

/// Plain sRGB components in 0...1.
struct PaletteColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hue h: Double, saturation s: Double, brightness v: Double) {
        let h6 = (h - floor(h)) * 6
        let i = Int(h6) % 6
        let f = h6 - floor(h6)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: self.init(r: v, g: t, b: p)
        case 1: self.init(r: q, g: v, b: p)
        case 2: self.init(r: p, g: v, b: t)
        case 3: self.init(r: p, g: q, b: v)
        case 4: self.init(r: t, g: p, b: v)
        default: self.init(r: v, g: p, b: q)
        }
    }

    /// Hue in 0..<1, saturation and brightness in 0...1.
    var hsb: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio against white.
    var contrastWithWhite: Double { 1.05 / (luminance + 0.05) }
}

/// Picks a dominant vivid color from a cover and turns it into two readable background tones.
struct ArtworkPalette: Equatable {
    var primary: PaletteColor
    var secondary: PaletteColor

    static let side = 32

    init(primary: PaletteColor, secondary: PaletteColor) {
        self.primary = primary
        self.secondary = secondary
    }

    init?(data: Data) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.side * 2,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        self.init(image: thumb)
    }

    init?(image: CGImage) {
        guard let pixels = Self.downsample(image), let base = Self.dominant(rgba: pixels) else { return nil }
        self = Self.tones(for: base)
    }

    /// Draws the image into a `side` x `side` premultiplied RGBA8 sRGB buffer.
    static func downsample(_ image: CGImage) -> [UInt8]? {
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? pixels : nil
    }

    /// Buckets vivid pixels by hue and returns the average color of the heaviest hue range.
    /// Near-black, near-white and greyish pixels are skipped. Falls back to the overall
    /// average for covers with no vivid pixels.
    static func dominant(rgba: [UInt8]) -> PaletteColor? {
        struct Bucket {
            var weight = 0.0, r = 0.0, g = 0.0, b = 0.0
            mutating func add(_ c: PaletteColor, _ w: Double) {
                weight += w; r += c.r * w; g += c.g * w; b += c.b * w
            }
        }
        let bins = 24
        var buckets = [Bucket](repeating: Bucket(), count: bins)
        var all = Bucket()
        var opaque = 0.0
        var i = 0
        while i + 3 < rgba.count {
            let a = Double(rgba[i + 3]) / 255
            if a >= 0.5 {
                let c = PaletteColor(r: min(1, Double(rgba[i]) / 255 / a),
                            g: min(1, Double(rgba[i + 1]) / 255 / a),
                            b: min(1, Double(rgba[i + 2]) / 255 / a))
                all.add(c, 1)
                opaque += 1
                let (h, s, v) = c.hsb
                if v >= 0.15 && s >= 0.2 {
                    buckets[min(bins - 1, Int(h * Double(bins)))].add(c, s * (0.4 + 0.6 * v))
                }
            }
            i += 4
        }
        guard opaque > 0 else { return nil }

        var best = -1, bestWeight = 0.0
        for k in 0..<bins {
            let w = buckets[(k + bins - 1) % bins].weight + buckets[k].weight + buckets[(k + 1) % bins].weight
            if w > bestWeight { best = k; bestWeight = w }
        }
        // Require a few percent of the cover to be vivid, or the color is noise.
        if best >= 0 && bestWeight >= opaque * 0.03 {
            var sum = Bucket()
            for k in [(best + bins - 1) % bins, best, (best + 1) % bins] {
                sum.weight += buckets[k].weight
                sum.r += buckets[k].r; sum.g += buckets[k].g; sum.b += buckets[k].b
            }
            return PaletteColor(r: sum.r / sum.weight, g: sum.g / sum.weight, b: sum.b / sum.weight)
        }
        return PaletteColor(r: all.r / opaque, g: all.g / opaque, b: all.b / opaque)
    }

    /// Mutes and darkens `base` so white text on it reads well (contrast >= 4.5),
    /// and derives a darker secondary of the same hue.
    static func tones(for base: PaletteColor) -> ArtworkPalette {
        let (h, s0, v0) = base.hsb
        let s = min(s0, 0.65)
        var v = min(max(v0, 0.3), 0.58)
        var primary = PaletteColor(hue: h, saturation: s, brightness: v)
        while primary.luminance > 0.15 && v > 0.05 {
            v *= 0.93
            primary = PaletteColor(hue: h, saturation: s, brightness: v)
        }
        let secondary = PaletteColor(hue: h, saturation: min(s * 1.05, 0.7), brightness: v * 0.42)
        return ArtworkPalette(primary: primary, secondary: secondary)
    }
}
