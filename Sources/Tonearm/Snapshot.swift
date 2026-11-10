import AppKit
import SwiftUI

/// Renders the popover with sample data to PNGs at 2x. Used by CI for screenshots.
///
///     Tonearm --snapshot <dir>       writes one PNG per state into <dir>
///     Tonearm --snapshot out.png     writes only the playing state
enum Snapshot {
    @MainActor
    static func render(to url: URL) {
        if url.pathExtension.lowercased() == "png" {
            write(view(state: .playing), to: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(url.path): \(error)")
        }
        let shots: [(String, AnyView)] = [
            ("player-playing", view(state: .playing)),
            ("player-paused", view(state: .paused)),
            ("player-progress-hover", view(state: .playing, preview: .init(progressHover: true))),
            ("player-settings", view(state: .playing, preview: .init(settingsOpen: true))),
            ("nothing-playing", view(state: .stopped)),
            ("not-running", view(state: nil, preview: .init(status: .notRunning))),
            ("not-authorized", view(state: nil, preview: .init(status: .notAuthorized))),
            ("not-installed", view(state: nil, preview: .init(status: .notInstalled))),
        ]
        for (name, view) in shots {
            write(view, to: url.appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    private static func view(state: PlayState?, preview: PlayerView.Preview = .init()) -> AnyView {
        let model = PlayerModel(live: false)
        if let state {
            let track = state == .stopped ? nil : Track(
                id: "sample", title: "Sample Song Title", artist: "Sample Artist",
                album: "Sample Album", artworkURL: nil, duration: 214
            )
            model.setPreview(
                Playback(state: state, track: track, position: track == nil ? 0 : 83, volume: 70),
                artwork: track == nil ? nil : sampleArtwork()
            )
        }
        return AnyView(PlayerView(preview: preview).environmentObject(model))
    }

    @MainActor
    private static func write(_ view: AnyView, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { fail("render failed for \(url.lastPathComponent)") }
        do {
            try png.write(to: url)
        } catch {
            fail("cannot write \(url.path): \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("snapshot: \(message)\n".data(using: .utf8)!)
        exit(1)
    }

    /// Abstract sample cover drawn in code: a record with a tonearm resting on it.
    static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
            func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
                NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
            }
            NSGradient(starting: color(28, 78, 88), ending: color(12, 36, 44))?.draw(in: rect, angle: -90)

            let center = NSPoint(x: 260, y: 270)
            func circle(_ radius: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2))
            }
            color(10, 24, 30).setFill()
            circle(230).fill()
            color(236, 222, 196, 0.16).setStroke()
            var r: CGFloat = 90
            while r < 226 {
                let groove = circle(r)
                groove.lineWidth = 1.5
                groove.stroke()
                r += 9
            }
            color(238, 124, 92).setFill()
            circle(70).fill()
            color(10, 24, 30).setFill()
            circle(7).fill()

            let arm = NSBezierPath()
            arm.move(to: NSPoint(x: 540, y: 540))
            arm.line(to: NSPoint(x: 520, y: 330))
            arm.line(to: NSPoint(x: 420, y: 220))
            arm.lineWidth = 12
            arm.lineCapStyle = .round
            arm.lineJoinStyle = .round
            color(236, 222, 196).setStroke()
            arm.stroke()
            color(236, 222, 196).setFill()
            NSBezierPath(ovalIn: NSRect(x: 516, y: 516, width: 48, height: 48)).fill()
            return true
        }
    }
}
