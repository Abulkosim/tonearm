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
            write(player(.playing, .init(shuffling: true)), to: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(url.path): \(error)")
        }
        let playing = PlayerView.Preview(shuffling: true)
        let compact = PlayerView.Preview(layout: .compact, shuffling: true)
        let settings = PlayerView.Preview(settingsOpen: true)
        let notRunning = PlayerView.Preview(status: .notRunning)
        let shots: [(String, AnyView)] = [
            ("player-playing", player(.playing, playing)),
            ("player-paused", player(.paused)),
            ("player-progress-hover", player(.playing, .init(progressHover: true))),
            ("player-cover-hover", player(.playing, .init(repeating: true, coverHover: true, coverNote: "Copied"))),
            ("player-warm-cover", player(.playing, playing, cover: .warm)),
            ("player-settings", player(.playing, settings)),
            ("compact", player(.playing, compact)),
            ("compact-warm-cover", player(.paused, compact, cover: .warm)),
            ("nothing-playing", player(.stopped)),
            ("not-running", player(nil, notRunning)),
            ("not-authorized", player(nil, .init(status: .notAuthorized))),
            ("not-installed", player(nil, .init(status: .notInstalled))),
            ("waiting-for-permission", player(nil, askingPermission: true)),
            ("framed-player", framed(player(.playing, playing))),
            ("framed-player-warm", framed(player(.playing, playing, cover: .warm))),
            ("framed-compact", framed(player(.playing, compact))),
            ("framed-settings", framed(player(.playing, settings))),
            ("framed-not-running", framed(player(nil, notRunning))),
        ]
        for (name, view) in shots {
            write(view, to: url.appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    private static func player(_ state: PlayState?, _ preview: PlayerView.Preview = .init(),
                               cover: SampleCover = .teal, askingPermission: Bool = false) -> AnyView {
        let model = PlayerModel(live: false)
        if askingPermission { model.setPreviewAskingPermission() }
        if let state {
            let track = state == .stopped ? nil : Track(
                id: "spotify:track:0000000000000000000000", title: "Sample Song Title",
                artist: "Sample Artist", album: "Sample Album", artworkURL: nil, duration: 214
            )
            model.setPreview(
                Playback(state: state, track: track, position: track == nil ? 0 : 83, volume: 70),
                artwork: track == nil ? nil : sampleArtwork(cover)
            )
        }
        return AnyView(PlayerView(preview: preview).environmentObject(model))
    }

    /// Puts the popover under a mock menu bar on a plain desktop, the way people see it.
    @MainActor
    private static func framed(_ popover: AnyView) -> AnyView {
        let margin: CGFloat = 56
        let menuBar = HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                Text("Sample Song Title")
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.22)))
            Spacer(minLength: 0)
            Image(systemName: "wifi")
            Image(systemName: "battery.75")
            Text("Tue 10:42")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.white)
        .padding(.leading, margin - 8)
        .padding(.trailing, 16)
        .frame(height: 28)
        .background(Color.black.opacity(0.25))

        let desktop = LinearGradient(
            colors: [Color(red: 0.36, green: 0.40, blue: 0.45), Color(red: 0.17, green: 0.19, blue: 0.23)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                menuBar
                popover
                    .popoverWindowShape()
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .padding(.top, 6)
                    .padding(.leading, margin)
                    .padding(.bottom, margin)
            }
            .frame(width: 300 + margin * 2, alignment: .leading)
            .background(desktop)
            .environment(\.colorScheme, .dark)
        )
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

    /// Sample cover colors: the teal one, and a red one like many real covers.
    enum SampleCover {
        case teal, warm
    }

    /// Abstract sample cover drawn in code: a record with a tonearm resting on it.
    static func sampleArtwork(_ cover: SampleCover = .teal) -> NSImage {
        NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
            func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
                NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
            }
            switch cover {
            case .teal:
                NSGradient(starting: color(28, 78, 88), ending: color(12, 36, 44))?.draw(in: rect, angle: -90)
            case .warm:
                NSGradient(starting: color(196, 58, 48), ending: color(120, 26, 30))?.draw(in: rect, angle: -90)
            }

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
            (cover == .teal ? color(238, 124, 92) : color(240, 196, 110)).setFill()
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
