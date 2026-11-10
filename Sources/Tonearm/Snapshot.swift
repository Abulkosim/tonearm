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
        let longTitleBar = AppSettings(defaults: UserDefaults(suiteName: "tonearm.snapshot") ?? .standard)
        longTitleBar.menuBarStyle = .songTitle
        longTitleBar.showArtist = true
        longTitleBar.maxTitleLength = AppSettings.defaultTitleLength
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
            ("framed-player", framed(model(.playing), playing)),
            ("framed-player-warm", framed(model(.playing, cover: .warm), playing)),
            ("framed-compact", framed(model(.playing), compact)),
            ("framed-settings", framed(model(.playing), settings)),
            ("framed-not-running", framed(model(nil), notRunning)),
            ("player-long-title", player(.playing, playing, track: .long)),
            ("compact-long-title", player(.playing, compact, track: .long)),
            ("framed-long-title", framed(model(.playing, track: .long), playing, bar: longTitleBar)),
            ("welcome", welcome(spotifyInstalled: true)),
            ("welcome-no-spotify", welcome(spotifyInstalled: false)),
            ("framed-welcome", framedWelcome()),
        ]
        for (name, view) in shots {
            write(view, to: url.appendingPathComponent("\(name).png"))
        }
    }

    /// Sample songs: an ordinary one, and a long Cyrillic title and artist to check cutting.
    enum SampleTrack {
        case standard, long

        var track: Track {
            switch self {
            case .standard:
                return Track(id: "spotify:track:0000000000000000000000", title: "Sample Song Title",
                             artist: "Sample Artist", album: "Sample Album", artworkURL: nil, duration: 214)
            case .long:
                return Track(id: "spotify:track:1111111111111111111111",
                             title: "Песня о далёкой звезде над ночным городом (Remastered 2024)",
                             artist: "Оркестр Северного ветра, Александра Константинопольская",
                             album: "Длинная дорога домой: концерт в Большом зале консерватории",
                             artworkURL: nil, duration: 3725)
            }
        }
    }

    @MainActor
    private static func player(_ state: PlayState?, _ preview: PlayerView.Preview = .init(),
                               cover: SampleCover = .teal, track sample: SampleTrack = .standard,
                               askingPermission: Bool = false) -> AnyView {
        AnyView(PlayerView(preview: preview).environmentObject(
            model(state, cover: cover, track: sample, askingPermission: askingPermission)
        ))
    }

    @MainActor
    private static func model(_ state: PlayState?, cover: SampleCover = .teal, track sample: SampleTrack = .standard,
                              askingPermission: Bool = false) -> PlayerModel {
        let model = PlayerModel(live: false)
        if askingPermission { model.setPreviewAskingPermission() }
        if let state {
            let track = state == .stopped ? nil : sample.track
            model.setPreview(
                Playback(state: state, track: track, position: track == nil ? 0 : 83, volume: 70),
                artwork: track == nil ? nil : sampleArtwork(cover)
            )
        }
        return model
    }

    private static let desktop = LinearGradient(
        colors: [Color(red: 0.36, green: 0.40, blue: 0.45), Color(red: 0.17, green: 0.19, blue: 0.23)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// A mock menu bar: Tonearm's real label on the left, highlighted like an open item,
    /// and a few system items on the right.
    @MainActor
    private static func menuBar<Label: View>(leading: CGFloat, @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 16) {
            label()
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
        .lineLimit(1)
        .padding(.leading, leading)
        .padding(.trailing, 16)
        .frame(height: 28)
        .background(Color.black.opacity(0.25))
    }

    /// Puts the popover under a mock menu bar on a plain desktop, the way people see it.
    /// `bar` sets the menu bar title options; the label comes from `MenuBarLabel`.
    @MainActor
    private static func framed(_ model: PlayerModel, _ preview: PlayerView.Preview,
                               bar: AppSettings? = nil) -> AnyView {
        let margin: CGFloat = 56
        let settings = bar ?? plainBar()
        let popover = PlayerView(preview: preview).environmentObject(model)
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                menuBar(leading: margin - 8) { MenuBarLabel(model: model, settings: settings) }
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

    /// Default menu bar options: song title without the artist.
    private static func plainBar() -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "tonearm.snapshot.plain") ?? .standard)
        settings.menuBarStyle = .songTitle
        settings.showArtist = false
        settings.maxTitleLength = AppSettings.defaultTitleLength
        return settings
    }

    @MainActor
    private static func welcome(spotifyInstalled: Bool) -> AnyView {
        AnyView(Onboarding.snapshotView(spotifyInstalled: spotifyInstalled))
    }

    /// The welcome window on a desktop, under the menu bar icon it points at, the way it
    /// opens on the first launch.
    @MainActor
    private static func framedWelcome() -> AnyView {
        let margin: CGFloat = 56
        let width = WelcomeView.width + margin * 2
        // The real icon sits right above the sketched one, like `WelcomeWindowController.place`.
        let iconFromRight = margin + WelcomeView.arrowTipFromRight
        let window = Onboarding.snapshotView(spotifyInstalled: true)
            .overlay(alignment: .topLeading) {
                // Only the close button: the other two are hidden.
                Circle()
                    .fill(Color(red: 1, green: 0.37, blue: 0.34))
                    .frame(width: 12, height: 12)
                    .padding(.leading, 12)
                    .padding(.top, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)

        let bar = HStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: MenuBarLabel.appGlyph)
                .frame(width: 28, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.22)))
                .padding(.trailing, iconFromRight - 14)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 16) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
                Text("Tue 10:42")
            }
            .padding(.trailing, 16)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.white)
        .frame(height: 28)
        .background(Color.black.opacity(0.25))

        return AnyView(
            VStack(spacing: 0) {
                bar
                window
                    .padding(.top, 12)
                    .padding(.horizontal, margin)
                    .padding(.bottom, margin)
            }
            .frame(width: width)
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
