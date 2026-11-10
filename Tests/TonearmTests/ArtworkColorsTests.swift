import AppKit
import XCTest
@testable import Tonearm

final class ArtworkColorsTests: XCTestCase {
    /// Draws rectangles of solid color into a 300x300 image.
    private func image(_ fills: [(CGRect, PaletteColor)], background: PaletteColor) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ r: CGRect, _ c: PaletteColor) {
            ctx.setFillColor(CGColor(colorSpace: space, components: [c.r, c.g, c.b, 1])!)
            ctx.fill(r)
        }
        fill(CGRect(x: 0, y: 0, width: 300, height: 300), background)
        for (r, c) in fills { fill(r, c) }
        return ctx.makeImage()!
    }

    private func assertReadable(_ p: ArtworkPalette, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(p.primary.contrastWithWhite, 4.5, file: file, line: line)
        XCTAssertLessThan(p.secondary.luminance, p.primary.luminance, file: file, line: line)
    }

    func testSolidRed() throws {
        let p = try XCTUnwrap(ArtworkPalette(image: image([], background: PaletteColor(r: 0.9, g: 0.1, b: 0.1))))
        XCTAssertGreaterThan(p.primary.r, p.primary.g)
        XCTAssertGreaterThan(p.primary.r, p.primary.b)
        XCTAssertLessThanOrEqual(p.primary.hsb.s, 0.66)
        assertReadable(p)
    }

    func testSkipsBlackAndWhite() throws {
        // Mostly black with a white band and a smaller blue square: blue should win.
        let img = image([
            (CGRect(x: 0, y: 0, width: 300, height: 100), PaletteColor(r: 1, g: 1, b: 1)),
            (CGRect(x: 100, y: 150, width: 90, height: 90), PaletteColor(r: 0.15, g: 0.35, b: 0.9)),
        ], background: PaletteColor(r: 0.02, g: 0.02, b: 0.02))
        let p = try XCTUnwrap(ArtworkPalette(image: img))
        XCTAssertGreaterThan(p.primary.b, p.primary.r)
        XCTAssertGreaterThan(p.primary.b, p.primary.g)
        assertReadable(p)
    }

    func testDominantHueWins() throws {
        // 2/3 green, 1/3 orange.
        let img = image([(CGRect(x: 0, y: 0, width: 100, height: 300), PaletteColor(r: 0.95, g: 0.55, b: 0.1))],
                        background: PaletteColor(r: 0.2, g: 0.75, b: 0.3))
        let p = try XCTUnwrap(ArtworkPalette(image: img))
        XCTAssertGreaterThan(p.primary.g, p.primary.r)
        assertReadable(p)
    }

    func testGreyscaleStaysGrey() throws {
        let img = image([(CGRect(x: 0, y: 0, width: 150, height: 300), PaletteColor(r: 0.8, g: 0.8, b: 0.8))],
                        background: PaletteColor(r: 0.3, g: 0.3, b: 0.3))
        let p = try XCTUnwrap(ArtworkPalette(image: img))
        XCTAssertLessThan(p.primary.hsb.s, 0.05)
        assertReadable(p)
    }

    func testBrightYellowIsReadable() throws {
        let p = try XCTUnwrap(ArtworkPalette(image: image([], background: PaletteColor(r: 1, g: 0.95, b: 0.2))))
        assertReadable(p)
    }

    func testFromEncodedData() throws {
        let rep = NSBitmapImageRep(cgImage: image([], background: PaletteColor(r: 0.1, g: 0.3, b: 0.8)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertNotNil(ArtworkColors(data: png))
        XCTAssertNil(ArtworkColors(data: Data([1, 2, 3])))
    }

    func testHSBRoundTrip() {
        let c = PaletteColor(r: 0.8, g: 0.4, b: 0.2)
        let (h, s, v) = c.hsb
        let back = PaletteColor(hue: h, saturation: s, brightness: v)
        XCTAssertEqual(back.r, c.r, accuracy: 0.0001)
        XCTAssertEqual(back.g, c.g, accuracy: 0.0001)
        XCTAssertEqual(back.b, c.b, accuracy: 0.0001)
    }

    @MainActor
    func testPreviewComputesColors() {
        let model = PlayerModel(live: false)
        model.setPreview(Playback(state: .paused, track: nil, position: 0, volume: 50),
                         artwork: Snapshot.sampleArtwork())
        XCTAssertNotNil(model.artworkColors)
    }

    @MainActor
    func testArtworkCacheEvictsOldest() {
        let cache = ArtworkCache(limit: 2)
        let img = NSImage(size: NSSize(width: 1, height: 1))
        let urls = (0..<3).map { URL(string: "https://i.scdn.co/image/\($0)")! }
        cache[urls[0]] = ArtworkCache.Entry(image: img, colors: nil)
        cache[urls[1]] = ArtworkCache.Entry(image: img, colors: nil)
        _ = cache[urls[0]] // touch, so 1 is oldest
        cache[urls[2]] = ArtworkCache.Entry(image: img, colors: nil)
        XCTAssertNotNil(cache[urls[0]])
        XCTAssertNil(cache[urls[1]])
        XCTAssertEqual(cache.count, 2)
    }
}
