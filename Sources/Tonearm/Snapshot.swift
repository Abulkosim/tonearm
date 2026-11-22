import AppKit
import ImageIO
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
            ("connecting", player(nil, .init(status: .notRunning, connecting: true))),
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
        case standard, second, long

        var track: Track {
            switch self {
            case .standard:
                return Track(id: "spotify:track:0000000000000000000000", title: "Sample Song Title",
                             artist: "Sample Artist", album: "Sample Album", artworkURL: nil, duration: 214)
            case .second:
                return Track(id: "spotify:track:2222222222222222222222", title: "Another Sample Song",
                             artist: "Another Artist", album: "Sample Album", artworkURL: nil, duration: 187)
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
                              position: Double = 83, askingPermission: Bool = false) -> PlayerModel {
        model(state, cover: cover, song: sample.track, position: position, askingPermission: askingPermission)
    }

    @MainActor
    private static func model(_ state: PlayState?, cover: SampleCover = .teal, song: Track,
                              position: Double = 83, askingPermission: Bool = false) -> PlayerModel {
        let model = PlayerModel(live: false)
        if askingPermission { model.setPreviewAskingPermission() }
        if let state {
            let track = state == .stopped ? nil : song
            model.setPreview(
                Playback(state: state, track: track, position: track == nil ? 0 : position, volume: 70),
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
    private static func menuBar<Label: View>(leading: CGFloat, open: Bool = true,
                                             @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 16) {
            label()
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(open ? 0.22 : 0)))
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
    /// `minHeight` pads the desktop below, so frames of different scenes match in size.
    /// `width` widens the desktop to the right.
    @MainActor
    private static func framed(_ model: PlayerModel, _ preview: PlayerView.Preview,
                               bar: AppSettings? = nil, minHeight: CGFloat = 0, width: CGFloat? = nil) -> AnyView {
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
            .frame(width: width ?? 300 + margin * 2, alignment: .leading)
            .frame(minHeight: minHeight, alignment: .top)
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
    static func write(_ view: AnyView, to url: URL) {
        guard let cg = image(view) else { fail("render failed for \(url.lastPathComponent)") }
        write(cg, to: url)
    }

    @MainActor
    static func image(_ view: AnyView) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage
    }

    static func write(_ cg: CGImage, to url: URL) {
        guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { fail("cannot encode \(url.lastPathComponent)") }
        do {
            try png.write(to: url)
        } catch {
            fail("cannot write \(url.path): \(error)")
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("snapshot: \(message)\n".data(using: .utf8)!)
        exit(1)
    }

    /// Sample cover colors: the teal one, a red one like many real covers, and two for
    /// contrast checks: a nearly white one and a nearly black one.
    enum SampleCover {
        case teal, warm, pale, black
    }

    /// Abstract sample cover drawn in code: a record with a tonearm resting on it.
    static func sampleArtwork(_ cover: SampleCover = .teal) -> NSImage {
        NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
            func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
                NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
            }
            let disc: NSColor, groove: NSColor, label: NSColor
            switch cover {
            case .teal:
                NSGradient(starting: color(28, 78, 88), ending: color(12, 36, 44))?.draw(in: rect, angle: -90)
                (disc, groove, label) = (color(10, 24, 30), color(236, 222, 196, 0.16), color(238, 124, 92))
            case .warm:
                NSGradient(starting: color(196, 58, 48), ending: color(120, 26, 30))?.draw(in: rect, angle: -90)
                (disc, groove, label) = (color(10, 24, 30), color(236, 222, 196, 0.16), color(240, 196, 110))
            case .pale:
                NSGradient(starting: color(252, 250, 245), ending: color(236, 232, 224))?.draw(in: rect, angle: -90)
                (disc, groove, label) = (color(226, 222, 214), color(255, 255, 255, 0.6), color(250, 236, 226))
            case .black:
                NSGradient(starting: color(14, 14, 14), ending: color(0, 0, 0))?.draw(in: rect, angle: -90)
                (disc, groove, label) = (color(6, 6, 6), color(255, 255, 255, 0.05), color(28, 28, 28))
            }

            let center = NSPoint(x: 260, y: 270)
            func circle(_ radius: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2))
            }
            disc.setFill()
            circle(230).fill()
            groove.setStroke()
            var r: CGFloat = 90
            while r < 226 {
                let groove = circle(r)
                groove.lineWidth = 1.5
                groove.stroke()
                r += 9
            }
            label.setFill()
            circle(70).fill()
            disc.setFill()
            circle(7).fill()

            let arm = NSBezierPath()
            arm.move(to: NSPoint(x: 540, y: 540))
            arm.line(to: NSPoint(x: 520, y: 330))
            arm.line(to: NSPoint(x: 420, y: 220))
            arm.lineWidth = 12
            arm.lineCapStyle = .round
            arm.lineJoinStyle = .round
            let armColor = cover == .pale ? color(200, 194, 184) : cover == .black ? color(40, 40, 40)
                : color(236, 222, 196)
            armColor.setStroke()
            arm.stroke()
            armColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 516, y: 516, width: 48, height: 48)).fill()
            return true
        }
    }
}

// MARK: - README and website images

/// Renders every picture of Tonearm that the README and the website show, from the app's own
/// views: the animation's frames and the stills. scripts/make-demo.sh runs it.
///
///     Tonearm --demo <dir> [--compare <dir>]
///
/// Liner Notes reads a sample listening history: two years of made-up plays by made-up
/// artists, written as a Spotify extended streaming history export and imported into a
/// temporary database, so every number in the pictures comes from the real import and stats
/// code. With `--compare`, it also checks the stills against the ones in that directory and
/// exits 1 if any is missing or looks different, so the README can't show an old app.
extension Snapshot {
    /// Frames per second of the animation. scripts/make-demo.sh uses the same rate.
    static let demoFPS = 10

    /// The stills the README and the website use, by file name.
    static let demoStills = ["player.png", "compact.png", "liner-notes.png", "share-card.png", "social.png"]

    /// The two songs the player shows in the animation. Both are in the sample history.
    static let demoSongs = [
        Track(id: "spotify:track:4dGlassMorningOlaBrandt0", title: "Glass Morning", artist: "Ola Brandt",
              album: "North of Here", artworkURL: nil, duration: 214),
        Track(id: "spotify:track:4dHarborLightsJuniperVal", title: "Harbor Lights", artist: "Juniper Vale",
              album: "Low Tide Radio", artworkURL: nil, duration: 198),
    ]
    /// Their covers: the player's sample covers.
    static let demoCovers: [SampleCover] = [.teal, .warm]

    /// The animation's canvas, in points: a strip of desktop under the menu bar, wide enough
    /// for the Liner Notes window at its smallest width.
    static let demoCanvas = CGSize(width: 920, height: 724)
    /// The Liner Notes window in the animation: its minimum width, and a little taller.
    static let demoWindow = CGSize(width: 840, height: 600)

    @MainActor
    static func renderDemo(to dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(dir.path): \(error)")
        }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        defer { NSApplication.shared.appearance = nil }

        let history = DemoHistory.load()
        let notes = history.model
        guard let stats = notes.stats else { fail("the sample history has no stats") }

        // The animation: a song plays, the next one fades in with its own colors, then the
        // Liner Notes window opens over the desktop.
        let playing = PlayerView.Preview(shuffling: true)
        func playerFrame(_ song: Int, at seconds: Double) -> CGImage {
            let start: Double = song == 0 ? 83 : 4
            let view = framed(model(.playing, cover: demoCovers[song], song: demoSongs[song], position: start + seconds),
                              playing, minHeight: demoCanvas.height, width: demoCanvas.width)
            guard let cg = image(view) else { fail("render failed for a demo frame") }
            return cg
        }
        guard let notesFrame = image(linerNotesScene(notes)) else { fail("render failed for the Liner Notes frame") }
        let scenes: [(seconds: Double, frame: (Double) -> CGImage)] = [
            (2.5, { playerFrame(0, at: $0) }),
            (2.5, { playerFrame(1, at: $0) }),
            (4, { _ in notesFrame }),
        ]
        let fadeFrames = 3
        var index = 0
        func emit(_ cg: CGImage) {
            index += 1
            write(cg, to: dir.appendingPathComponent(String(format: "frame-%04d.png", index)))
        }
        for (i, scene) in scenes.enumerated() {
            let frames = Int(scene.seconds * Double(demoFPS))
            var last: CGImage?
            for f in 0..<frames {
                let cg = scene.frame(Double(f) / Double(demoFPS))
                emit(cg)
                last = cg
            }
            guard let from = last else { continue }
            let next = scenes[(i + 1) % scenes.count].frame(0)
            for f in 1...fadeFrames {
                emit(blend(from, next, amount: CGFloat(f) / CGFloat(fadeFrames + 1)))
            }
        }

        // The stills.
        let first = model(.playing, cover: demoCovers[0], song: demoSongs[0])
        write(framed(first, playing), to: dir.appendingPathComponent("player.png"))
        write(framed(first, PlayerView.Preview(layout: .compact, shuffling: true)),
              to: dir.appendingPathComponent("compact.png"))
        write(AnyView(window(notes, size: LinerNotesWindow.defaultSize).environment(\.colorScheme, .dark)),
              to: dir.appendingPathComponent("liner-notes.png"))
        guard let card = ShareCard.make(notes)?.render() else { fail("no share card for the sample history") }
        write(card, to: dir.appendingPathComponent("share-card.png"))
        let social = ImageRenderer(content: socialScene(notes, player: first))
        social.scale = 1
        guard let socialImage = social.cgImage else { fail("render failed for social.png") }
        write(socialImage, to: dir.appendingPathComponent("social.png"))

        var report = """
            Sample history: \(history.rows) rows imported, \(LinerFormat.number(history.total)) entries stored.
            Liner Notes shows \(notes.period): \(LinerFormat.number(Int(stats.music.ms / 60_000))) minutes, \
            \(LinerFormat.number(stats.music.listens)) plays, top artist \(stats.music.topArtists.first?.name ?? "none"), \
            top song \(stats.music.topTracks.first?.name ?? "none"), top album \(stats.music.topAlbums.first?.name ?? "none").
            Animation: \(index) frames at \(demoFPS) fps.

            """
        var stale = false
        if let i = CommandLine.arguments.firstIndex(of: "--compare"), i + 1 < CommandLine.arguments.count {
            let committed = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            report += "Compared with \(committed.path):\n"
            for name in demoStills {
                let result = compare(dir.appendingPathComponent(name), committed.appendingPathComponent(name))
                if !result.same { stale = true }
                report += "  \(name)  \(result.note)\n"
            }
            if stale {
                report += "\nThe pictures in \(committed.path) are out of date. Run scripts/make-demo.sh and commit them.\n"
            }
        }
        do {
            try report.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write report.txt: \(error)")
        }
        print(report, terminator: "")
        if stale { exit(1) }
    }

    /// The Liner Notes window, with a title bar like the real one, in dark mode.
    @MainActor
    private static func window(_ notes: LinerNotesModel, size: CGSize) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Liner Notes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 28)
            .background(Color(white: 0.16))
            Rectangle().fill(Color.black).frame(height: 1)
            LinerNotesView(model: notes)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
        }
        .frame(width: size.width)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    /// The last scene of the animation: the player has closed and Liner Notes is open.
    @MainActor
    private static func linerNotesScene(_ notes: LinerNotesModel) -> AnyView {
        let player = model(.playing, cover: demoCovers[1], song: demoSongs[1])
        return AnyView(
            VStack(spacing: 0) {
                menuBar(leading: 56 - 8, open: false) { MenuBarLabel(model: player, settings: plainBar()) }
                window(notes, size: demoWindow)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .padding(.top, 28)
                Spacer(minLength: 0)
            }
            .frame(width: demoCanvas.width, height: demoCanvas.height)
            .background(desktop)
            .environment(\.colorScheme, .dark)
        )
    }

    /// The website's social preview, 1200 x 630: the player open over the Liner Notes window.
    @MainActor
    private static func socialScene(_ notes: LinerNotesModel, player: PlayerModel) -> some View {
        let size = CGSize(width: 1200, height: 630)
        return ZStack(alignment: .topLeading) {
            desktop
            window(notes, size: demoWindow)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                .padding(.leading, size.width - demoWindow.width - 48)
                .padding(.top, 64)
            framedOver(player)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// The menu bar across the whole width and the open player under it, with no desktop
    /// behind, to lay over another picture.
    @MainActor
    private static func framedOver(_ player: PlayerModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            menuBar(leading: 56 - 8) { MenuBarLabel(model: player, settings: plainBar()) }
            PlayerView(preview: PlayerView.Preview(shuffling: true)).environmentObject(player)
                .popoverWindowShape()
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                .padding(.top, 6)
                .padding(.leading, 56)
        }
    }

    /// Compares two PNGs pixel by pixel. They count as the same when they have the same size
    /// and under 0.1% of pixels differ by more than 16 levels in a channel, which allows for
    /// antialiasing noise between runs but not for a moved or changed control.
    static func compare(_ fresh: URL, _ committed: URL) -> (same: Bool, note: String) {
        guard FileManager.default.fileExists(atPath: committed.path) else { return (false, "MISSING") }
        guard let a = pixels(fresh), let b = pixels(committed) else { return (false, "UNREADABLE") }
        guard a.width == b.width, a.height == b.height else {
            return (false, "DIFFERENT SIZE: \(b.width)x\(b.height) px committed, \(a.width)x\(a.height) px now")
        }
        var differing = 0
        for p in stride(from: 0, to: a.bytes.count, by: 4) {
            for c in 0..<4 where abs(Int(a.bytes[p + c]) - Int(b.bytes[p + c])) > 16 {
                differing += 1
                break
            }
        }
        let share = Double(differing) / Double(a.width * a.height)
        let note = String(format: "%.3f%% of pixels differ", share * 100)
        return share < 0.001 ? (true, "same (\(note))") : (false, "DIFFERENT: \(note)")
    }

    private static func pixels(_ url: URL) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                                      bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        return drawn ? (cg.width, cg.height, bytes) : nil
    }

    /// Draws `to` over `from` at the given opacity.
    private static func blend(_ from: CGImage, _ to: CGImage, amount: CGFloat) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: from.width, height: from.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fail("cannot blend demo frames") }
        let rect = CGRect(x: 0, y: 0, width: from.width, height: from.height)
        ctx.draw(from, in: rect)
        ctx.setAlpha(amount)
        ctx.draw(to, in: rect)
        guard let out = ctx.makeImage() else { fail("cannot blend demo frames") }
        return out
    }
}

/// Two years of made-up listening, 2024 and 2025, for the README and website pictures.
/// Every artist, album and song name is invented. The same every run: the random numbers
/// come from a fixed seed.
private enum DemoHistory {
    struct Loaded {
        var model: LinerNotesModel
        var rows: Int
        var total: Int
    }

    /// Artist, album, then each song with its length in seconds. Earlier artists and songs
    /// get played more.
    static let catalog: [(artist: String, album: String, songs: [(String, Int)])] = [
        ("Juniper Vale", "Low Tide Radio",
         [("Harbor Lights", 198), ("Paper Boats", 231), ("Low Tide Radio", 241), ("Salt in the Air", 187),
          ("Slow Return", 263)]),
        ("Ola Brandt", "North of Here",
         [("Glass Morning", 214), ("North of Here", 225), ("Kestrel", 176), ("Long Way Round", 252)]),
        ("The Quiet Orbits", "Static Summer", [("Static Summer", 205), ("Night Bus", 243), ("Wire and Wool", 199)]),
        ("Mina Sato", "Small Hours", [("Small Hours", 218), ("Lantern", 192), ("After the Rain", 236)]),
        ("Teodor Lind", "Winter Tapes", [("Winter Tapes", 251), ("Snowlight", 207), ("Radiator", 184)]),
        ("Ama Sefa", "Golden Hour Club", [("Golden Hour Club", 229), ("Sunday Market", 201)]),
        ("Moth Parade", "Ceiling Fan", [("Ceiling Fan", 188), ("Porch Light", 214)]),
        ("Ines Calloway", "Rooms", [("Rooms", 246), ("Hallway Song", 203)]),
    ]
    /// A long tail of artists with one song each, played now and then.
    static let tailFirst = ["Lena", "Otto", "Rafa", "Noor", "Kai", "Yuki", "Tomas", "Ada", "Elio", "Sami"]
    static let tailLast = ["Varga", "Holm", "Okoye", "Duarte", "Quist", "Moreau", "Ferro", "Nyberg"]
    static let tailTitles = ["Hello Again", "Open Water", "Late Train", "Common Ground", "Blue Hour"]

    struct Song {
        var title: String
        var artist: String
        var album: String
        var uri: String
        var ms: Int
        var weight: Double
    }

    /// SplitMix64: small, and the same on every machine.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
    }

    static func catalogSongs() -> [Song] {
        var random = Random(state: 7)
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        func uri() -> String {
            "spotify:track:" + String((0..<22).map { _ in chars[Int(random.next() % 62)] })
        }
        var songs: [Song] = []
        for (a, entry) in catalog.enumerated() {
            for (s, song) in entry.songs.enumerated() {
                let weight = 1 / pow(Double(a + 1), 1.1) / pow(Double(s + 1), 0.8)
                songs.append(Song(title: song.0, artist: entry.artist, album: entry.album, uri: uri(),
                                  ms: song.1 * 1000, weight: weight))
            }
        }
        for first in tailFirst {
            for last in tailLast {
                let title = tailTitles[random.int(0...tailTitles.count - 1)]
                songs.append(Song(title: title, artist: "\(first) \(last)", album: "\(title) (Single)", uri: uri(),
                                  ms: random.int(150...280) * 1000, weight: 0.02))
            }
        }
        return songs
    }

    /// Rows in Spotify's extended streaming history format.
    static func exportRows() -> [[String: Any]] {
        let songs = catalogSongs()
        let total = songs.reduce(0) { $0 + $1.weight }
        var random = Random(state: 2024)
        func pick() -> Song {
            var x = random.unit() * total
            for song in songs {
                x -= song.weight
                if x <= 0 { return song }
            }
            return songs[songs.count - 1]
        }
        // How often a session starts in each hour of the day (UTC).
        let hours: [Double] = [1, 0.5, 0.2, 0, 0, 0, 0.3, 2, 4, 3, 2, 2, 3, 3, 2, 2, 3, 4, 5, 6, 7, 6, 4, 2]
        let hourTotal = hours.reduce(0, +)
        func startHour() -> Int {
            var x = random.unit() * hourTotal
            for (h, w) in hours.enumerated() {
                x -= w
                if x <= 0 { return h }
            }
            return 20
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")

        var rows: [[String: Any]] = []
        let first = LocalDay(year: 2024, month: 1, day: 1)
        let last = LocalDay(year: 2025, month: 12, day: 31)
        for number in first.number...last.number {
            let day = LocalDay(number: number)
            if random.unit() < 0.06 { continue }
            var minutes = 30 + random.unit() * 60 + (day.weekday >= 5 ? 25 : 0)
            if random.unit() < 0.03 { minutes *= 3 }
            let midnight = TimeInterval(day.number) * 86_400
            while minutes > 0 {
                var clock = midnight + TimeInterval(startHour() * 3600 + random.int(0...3599))
                var session = Double(random.int(15...70))
                while session > 0, minutes > 0 {
                    let song = pick()
                    let skipped = random.unit() < 0.12
                    let ms = skipped ? random.int(4...28) * 1000 : song.ms
                    clock += TimeInterval(ms / 1000)
                    rows.append([
                        "ts": formatter.string(from: Date(timeIntervalSince1970: clock)),
                        "platform": "OS X", "ms_played": ms, "conn_country": "ZZ",
                        "master_metadata_track_name": song.title,
                        "master_metadata_album_artist_name": song.artist,
                        "master_metadata_album_album_name": song.album,
                        "spotify_track_uri": song.uri,
                        "episode_name": NSNull(), "episode_show_name": NSNull(), "spotify_episode_uri": NSNull(),
                        "reason_start": "trackdone", "reason_end": skipped ? "fwdbtn" : "trackdone",
                        "shuffle": true, "skipped": skipped, "offline": false, "incognito_mode": false,
                    ])
                    session -= Double(ms) / 60_000
                    minutes -= Double(ms) / 60_000
                }
            }
        }
        return rows
    }

    /// Writes the export, imports it into a temporary database, and builds the Liner Notes
    /// model for 2025, with the covers of the two songs the player showed.
    @MainActor
    static func load() -> Loaded {
        let tz = TimeZone(identifier: "UTC")!
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let export = temp.appendingPathComponent("Spotify Extended Streaming History")
        let rows = exportRows()
        do {
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: rows)
            try data.write(to: export.appendingPathComponent("Streaming_History_Audio_2024-2025_0.json"))
        } catch {
            Snapshot.fail("cannot write the sample history: \(error)")
        }
        let store = HistoryStore(url: temp.appendingPathComponent("history.sqlite"))
        let period = Period.year(2025)
        let years: [Int], total: Int, stats: Stats
        do {
            _ = try store.sync { try $0.importNow(urls: [export]) }
            years = try store.sync { try $0.yearsNow(timeZone: tz) }
            total = try store.sync { try $0.countNow() }
            stats = try store.sync { try $0.statsNow(for: period, timeZone: tz) }
        } catch {
            Snapshot.fail("cannot import the sample history: \(error)")
        }
        var artwork = ArtworkIndex()
        var images: [String: NSImage] = [:]
        for (song, cover) in zip(Snapshot.demoSongs, Snapshot.demoCovers) {
            let key = "demo:\(song.title)"
            artwork.add(title: song.title, artist: song.artist, album: song.album, url: key)
            images[key] = Snapshot.sampleArtwork(cover)
        }
        let now = LocalDay(year: 2026, month: 1, day: 5).date(in: tz).addingTimeInterval(12 * 3600)
        let model = LinerNotesModel(snapshot: .ready, period: period, stats: stats, years: years, total: total,
                                    artwork: artwork, images: images, now: now, timeZone: tz)
        return Loaded(model: model, rows: rows.count, total: total)
    }
}

