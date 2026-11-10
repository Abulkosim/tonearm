#!/usr/bin/env swift
// Draws the Tonearm app icon with CoreGraphics and builds Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// Run from the repository root on macOS. Writes:
//   design/icon-1024.png         master image, committed
//   Resources/AppIcon.icns       app icon, committed
//   build/icon/AppIcon.iconset/  intermediate PNGs
//   build/icon/preview-sizes.png small sizes on light and dark, for review
//
// All geometry is in a 1024 x 1024 canvas with y pointing down.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

// Palette: charcoal neutrals, one warm accent for the record label.
let baseTop = color(0x2c2c2f)
let baseBottom = color(0x1b1b1d)
let vinyl = color(0x0c0c0d)
let accent = color(0xe8863f)
let accentDark = color(0xc96f2e)
let metalLight = color(0xe4e4e7)
let metalDark = color(0x9a9aa0)
let steelLight = color(0x5a5a60)
let steelDark = color(0x333337)
let plate = color(0x29292c)

func gradient(_ a: CGColor, _ b: CGColor) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: [a, b] as CFArray, locations: [0, 1])!
}

func makeContext(_ size: Int) -> CGContext {
    CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

/// macOS Big Sur style body: an 824 px rounded square on the 1024 px grid.
func bodyPath() -> CGPath {
    CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
           cornerWidth: 185, cornerHeight: 185, transform: nil)
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
}

func add(_ p: CGPoint, _ v: CGVector, _ k: CGFloat = 1) -> CGPoint {
    CGPoint(x: p.x + v.dx * k, y: p.y + v.dy * k)
}

func unit(_ from: CGPoint, _ to: CGPoint) -> CGVector {
    let dx = to.x - from.x, dy = to.y - from.y
    let len = (dx * dx + dy * dy).squareRoot()
    return CGVector(dx: dx / len, dy: dy / len)
}

/// A rounded bar centered at `center`, lying along `dir`.
func bar(center: CGPoint, dir: CGVector, length: CGFloat, width: CGFloat, radius: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: atan2(dir.dy, dir.dx))
    return CGPath(
        roundedRect: CGRect(x: -length / 2, y: -width / 2, width: length, height: width),
        cornerWidth: radius, cornerHeight: radius, transform: &t
    )
}

/// Fills `path` with a two-tone gradient running across `dir`, which reads as a round metal part.
func fillMetal(_ ctx: CGContext, _ path: CGPath, center: CGPoint, dir: CGVector, width: CGFloat,
               _ light: CGColor, _ dark: CGColor) {
    let normal = CGVector(dx: -dir.dy, dy: dir.dx)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(light, dark),
        start: add(center, normal, -width / 2), end: add(center, normal, width / 2),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let body = bodyPath()

    // Drop shadow under the body, as in Apple's icon template.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(baseBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient(baseTop, baseBottom),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

    // Record, cropped by the lower left of the body.
    let rc = CGPoint(x: 400, y: 624)
    let rr: CGFloat = 340
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.45))
    ctx.setFillColor(vinyl)
    ctx.fillEllipse(in: circle(rc, rr))
    ctx.restoreGState()

    // Grooves, with two wider gaps between tracks.
    ctx.setLineWidth(1.5)
    var r: CGFloat = 128
    while r < rr - 10 {
        let gap = abs(r - 196) < 4 || abs(r - 264) < 4
        ctx.setStrokeColor(color(0xffffff, gap ? 0.0 : 0.045))
        ctx.strokeEllipse(in: circle(rc, r))
        r += 6
    }
    // Light catching the grooves on two opposite sides.
    ctx.saveGState()
    ctx.addEllipse(in: circle(rc, rr - 6))
    ctx.addEllipse(in: circle(rc, 124))
    ctx.clip(using: .evenOdd)
    // Stacked wedges of falling width give the sheen a soft edge.
    for base in [CGFloat.pi * 1.18, CGFloat.pi * 0.18] {
        for step in 1...8 {
            let spread = 0.05 * CGFloat(step)
            let wedge = CGMutablePath()
            wedge.move(to: rc)
            wedge.addArc(center: rc, radius: rr, startAngle: base - spread, endAngle: base + spread, clockwise: false)
            wedge.closeSubpath()
            ctx.addPath(wedge)
            ctx.setFillColor(color(0xffffff, 0.007))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xffffff, 0.10))
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: circle(rc, rr - 1))

    // Label and spindle.
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: circle(rc, 112))
    ctx.setStrokeColor(accentDark)
    ctx.setLineWidth(3)
    ctx.strokeEllipse(in: circle(rc, 74))
    ctx.setFillColor(color(0x161618))
    ctx.fillEllipse(in: circle(rc, 11))

    // Tonearm: pivot top right, stylus resting on the grooves.
    let pivot = CGPoint(x: 750, y: 280)
    let stylus = CGPoint(x: 600, y: 590)
    let shellDir = CGVector(dx: -0.7071, dy: 0.7071)
    let elbow = add(stylus, shellDir, -84)
    let armDir = unit(pivot, elbow)
    let tail = add(pivot, armDir, -132)
    let weightCenter = add(pivot, armDir, -100)
    let shellCenter = add(elbow, shellDir, 56)

    let armWidth: CGFloat = 26
    let tube = CGMutablePath()
    tube.move(to: tail)
    tube.addLine(to: elbow)
    let tubeShape = tube.copy(strokingWithWidth: armWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let shell = bar(center: shellCenter, dir: shellDir, length: 120, width: 54, radius: 14)
    let cartridge = bar(center: add(shellCenter, shellDir, 26), dir: shellDir, length: 50, width: 40, radius: 8)
    let normal = CGVector(dx: -shellDir.dy, dy: shellDir.dx)
    let lift = bar(center: add(add(shellCenter, shellDir, -14), normal, 40), dir: normal, length: 36, width: 12, radius: 6)
    let weight = bar(center: weightCenter, dir: armDir, length: 72, width: 66, radius: 12)

    // Base plate under the pivot.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.40))
    ctx.setFillColor(plate)
    ctx.fillEllipse(in: circle(pivot, 88))
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xffffff, 0.08))
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: circle(pivot, 87))

    // One shadow for the whole arm, cast down and to the right onto the record.
    let silhouette = CGMutablePath()
    for p in [tubeShape, shell, lift, weight] { silhouette.addPath(p) }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 12, height: -18), blur: 18, color: color(0x000000, 0.55))
    ctx.addPath(silhouette)
    ctx.setFillColor(steelDark)
    ctx.fillPath(using: .winding)
    ctx.restoreGState()

    fillMetal(ctx, tubeShape, center: pivot, dir: armDir, width: armWidth, metalLight, metalDark)
    fillMetal(ctx, weight, center: weightCenter, dir: armDir, width: 66, steelLight, steelDark)
    fillMetal(ctx, lift, center: shellCenter, dir: normal, width: 12, metalLight, metalDark)
    fillMetal(ctx, shell, center: shellCenter, dir: shellDir, width: 54, metalLight, metalDark)
    fillMetal(ctx, cartridge, center: shellCenter, dir: shellDir, width: 40, steelLight, steelDark)

    // Bearing on top of the pivot.
    fillMetal(ctx, CGPath(ellipseIn: circle(pivot, 48), transform: nil),
              center: pivot, dir: CGVector(dx: 1, dy: 0), width: 96, metalLight, metalDark)
    ctx.setFillColor(plate)
    ctx.fillEllipse(in: circle(pivot, 20))

    ctx.restoreGState()

    // Hairline on the body edge.
    ctx.addPath(body)
    ctx.setStrokeColor(color(0xffffff, 0.07))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

func writePNG(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(path)") }
}

/// Halves the image until one step from `size`, which keeps thin lines smooth.
func scaled(_ image: CGImage, to size: Int) -> CGImage {
    var current = image
    while current.width / 2 >= size {
        let next = current.width / 2
        let ctx = makeContext(next)
        ctx.interpolationQuality = .high
        ctx.draw(current, in: CGRect(x: 0, y: 0, width: next, height: next))
        current = ctx.makeImage()!
    }
    if current.width == size { return current }
    let ctx = makeContext(size)
    ctx.interpolationQuality = .high
    ctx.draw(current, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

let fm = FileManager.default
let iconset = "build/icon/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
for dir in [iconset, "design", "Resources"] {
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
}

let master: CGImage = {
    let ctx = makeContext(Int(canvas))
    drawIcon(ctx)
    return ctx.makeImage()!
}()
writePNG(master, "design/icon-1024.png")

for base in [16, 32, 128, 256, 512] {
    writePNG(scaled(master, to: base), "\(iconset)/icon_\(base)x\(base).png")
    writePNG(scaled(master, to: base * 2), "\(iconset)/icon_\(base)x\(base)@2x.png")
}

// Preview sheet: 128, 64, 32 and 16 px on a light and a dark backdrop.
do {
    let w = 1024, h = 256
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color(0xececec))
    ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    ctx.setFillColor(color(0x1e1e1e))
    ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
    for half in 0..<2 {
        var x = CGFloat(half * w / 2 + 40)
        for size in [128, 64, 32, 16] {
            let s = CGFloat(size)
            ctx.draw(scaled(master, to: size), in: CGRect(x: x, y: (CGFloat(h) - s) / 2, width: s, height: s))
            x += s + 48
        }
    }
    writePNG(ctx.makeImage()!, "build/icon/preview-sizes.png")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote design/icon-1024.png, Resources/AppIcon.icns, build/icon/preview-sizes.png")
