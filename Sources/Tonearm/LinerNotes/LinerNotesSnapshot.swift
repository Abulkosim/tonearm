import AppKit
import SwiftUI

/// Renders the Liner Notes window and the share card from a Spotify export, for review.
/// CI runs it on the fixture from scripts/make-history-fixture.py.
///
///     Tonearm --liner-notes <dir> --history <export folder, .zip or .json>
///
/// Imports into a temporary database (never the user's), then writes PNGs at 2x: every
/// period whole, the first screen of the window as it opens, the empty, importing,
/// imported and failed screens, long names, covers, light and dark; and the share cards
/// at their real 1080 x 1350. Times are in UTC so the pictures are the same on every run.
/// Fails if a share card's text would be under 4.5:1 contrast.
@MainActor
enum LinerNotesSnapshot {
    static let width = LinerNotesWindow.defaultSize.width
    static let windowHeight = LinerNotesWindow.defaultSize.height

    static func render(to dir: URL, history: URL?) -> Bool {
        guard let history else { Snapshot.fail("--liner-notes needs --history <Spotify export>") }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Snapshot.fail("cannot create \(dir.path): \(error)")
        }
        let tz = TimeZone(identifier: "UTC")!
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-liner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = HistoryStore(url: temp.appendingPathComponent("history.sqlite"))

        let imported: ImportResult
        let importedPlays: Int
        let years: [Int]
        let total: Int
        do {
            imported = try store.sync { try $0.importNow(urls: [history]) }
            // A fresh database, so every play in it came from this import.
            importedPlays = try store.sync { try $0.playCountNow() }
            years = try store.sync { try $0.yearsNow(timeZone: tz) }
            total = try store.sync { try $0.countNow() }
        } catch {
            Snapshot.fail("cannot import \(history.path): \(error)")
        }
        guard let last = years.last else { Snapshot.fail("the export has no listens") }
        func stats(_ p: Period) -> Stats {
            do {
                return try store.sync { try $0.statsNow(for: p, timeZone: tz) }
            } catch {
                Snapshot.fail("stats for \(p): \(error)")
            }
        }

        let now = LocalDay(year: last, month: 11, day: 20).date(in: tz).addingTimeInterval(12 * 3600)
        func model(_ period: Period, _ s: Stats? = nil, phase: LinerNotesModel.Phase = .ready,
                   importState: LinerNotesModel.ImportState = .idle, artwork: ArtworkIndex = ArtworkIndex(),
                   images: [String: NSImage] = [:]) -> LinerNotesModel {
            LinerNotesModel(snapshot: phase, period: period, stats: s ?? (phase == .ready ? stats(period) : nil),
                            years: phase == .empty ? [] : years, total: phase == .empty ? 0 : total,
                            importState: importState, artwork: artwork, images: images, now: now, timeZone: tz)
        }

        let periods: [(String, Period)] = [
            ("week", .week(LocalDay(year: last, month: 10, day: 15))),
            ("month", .month(year: last, month: 10)),
            ("year", .year(last - 1)),
            ("all-time", .allTime),
        ]
        let year = Period.year(last - 1)
        let yearStats = stats(year)
        let (artIndex, artImages) = sampleArtwork(yearStats)
        let longStats = longNames(yearStats)

        var report = "Liner Notes snapshots from \(history.lastPathComponent): \(LinerFormat.number(total)) listens, "
            + "years \(years.first ?? 0)-\(last), \(imported.files) files. Time zone UTC.\n\n"
        var failed = false
        // The import screen and All time must give the same number of plays.
        let allTimePlays = stats(.allTime).music.listens
        let playsMatch = importedPlays == allTimePlays
        if !playsMatch { failed = true }
        report += "Import screen: \(LinerFormat.number(importedPlays)) plays added; all time: "
            + "\(LinerFormat.number(allTimePlays)) plays; \(imported.added) entries stored. "
            + (playsMatch ? "Same plays.\n\n" : "PLAYS DIFFER\n\n")
        func write(_ name: String, _ view: AnyView, dark: Bool, scale: CGFloat = 2) {
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = scale
            // A view that grows without bound renders as nothing or as a huge image; note it and go on,
            // so one bad screen doesn't hide the others.
            guard let cg = renderer.cgImage, cg.width > 0, cg.height > 0, cg.height < 20_000 else {
                failed = true
                let size = renderer.cgImage.map { "\($0.width)x\($0.height) px" } ?? "no image"
                report += "\(name).png  RENDER FAILED (\(size))\n"
                return
            }
            Snapshot.write(cg, to: dir.appendingPathComponent("\(name).png"))
            report += "\(name).png  \(Int(CGFloat(cg.width) / scale))x\(Int(CGFloat(cg.height) / scale)) pt\n"
        }

        for dark in [true, false] {
            let look = dark ? "dark" : "light"
            // The window as it opens: the first screen must answer the question.
            write("window-\(look)", window(model(year)), dark: dark)
            for (name, period) in periods {
                write("page-\(name)-\(look)", page(model(period)), dark: dark)
            }
            write("empty-\(look)", window(model(.allTime, phase: .empty)), dark: dark)
            write("importing-\(look)", window(model(.allTime, phase: .empty, importState: .running(
                filesDone: 3, filesTotal: 7, rowsRead: 31_208))), dark: dark)
            write("imported-\(look)", window(model(year, importState: .finished(imported, plays: importedPlays))),
                  dark: dark)
            write("nothing-played-\(look)", window(model(.week(LocalDay(year: years[0] - 1, month: 6, day: 3)))),
                  dark: dark)
            let shareModel = model(year)
            if let card = ShareCard.make(shareModel)?.render() {
                let sheet = ShareSheet(model: shareModel, image: NSImage(cgImage: card, size: ShareCard.size)) {}
                write("share-sheet-\(look)", AnyView(sheet), dark: dark)
            }
        }
        write("import-failed-dark", window(model(.allTime, phase: .empty, importState: .failed(
            ImportError.noHistoryFiles.description))), dark: true)
        write("failed-dark", window(model(year, phase: .failed("history.sqlite is from a newer Tonearm (schema 2)"))), dark: true)
        write("page-year-covers-dark", page(model(year, artwork: artIndex, images: artImages)), dark: true)
        write("page-long-names-dark", page(model(year, longStats)), dark: true)
        write("page-long-names-light", page(model(year, longStats)), dark: false)
        write("window-narrow-dark", AnyView(LinerNotesView(model: model(year))
            .frame(width: LinerNotesWindow.minSize.width, height: LinerNotesWindow.minSize.height, alignment: .top)
            .clipped()), dark: true)

        // Share cards at their real size, one pixel per point.
        let cards: [(String, LinerNotesModel)] = [
            ("share-card-year", model(year)),
            ("share-card-all-time", model(.allTime)),
            ("share-card-week", model(periods[0].1)),
            ("share-card-covers", model(year, artwork: artIndex, images: artImages)),
            ("share-card-long-names", model(year, longStats)),
            ("share-card-pale-cover", model(year, artwork: artIndex, images: coverOverride(artIndex, yearStats, .pale))),
            ("share-card-black-cover", model(year, artwork: artIndex, images: coverOverride(artIndex, yearStats, .black))),
        ]
        report += "\nShare cards, lowest text contrast:\n"
        for (name, m) in cards {
            guard let card = ShareCard.make(m) else { Snapshot.fail("no share card for \(name)") }
            write(name, AnyView(card), dark: true, scale: 1)
            let contrast = m.sleeve.minimumTextContrast
            let ok = contrast >= 4.5
            if !ok { failed = true }
            report += String(format: "  %@  %.2f:1 %@\n", name, contrast, ok ? "ok" : "TOO LOW")
        }

        // The player with its new Liner Notes button, both layouts.
        let player = PlayerModel(live: false)
        player.setPreview(Playback(state: .playing, track: Snapshot.SampleTrack.standard.track, position: 83, volume: 70),
                          artwork: Snapshot.sampleArtwork(.teal))
        write("player-large", AnyView(PlayerView(preview: .init()).environmentObject(player)), dark: true)
        write("player-compact", AnyView(PlayerView(preview: .init(layout: .compact)).environmentObject(player)),
              dark: true)
        NSApplication.shared.appearance = nil

        do {
            try report.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        } catch {
            Snapshot.fail("cannot write report.txt: \(error)")
        }
        print(report, terminator: "")
        return !failed
    }

    /// The whole page, as tall as its content.
    private static func page(_ model: LinerNotesModel) -> AnyView {
        AnyView(LinerNotesView(model: model).frame(width: width))
    }

    /// What the window shows when it opens at its default size.
    private static func window(_ model: LinerNotesModel) -> AnyView {
        AnyView(LinerNotesView(model: model).frame(width: width, height: windowHeight, alignment: .top).clipped())
    }

    /// Covers for the top album, the top three artists and a few songs, as if Tonearm had
    /// heard them play. The rest keep their generated tiles.
    private static func sampleArtwork(_ s: Stats) -> (ArtworkIndex, [String: NSImage]) {
        var index = ArtworkIndex()
        let covers: [Snapshot.SampleCover] = [.warm, .teal, .pale, .black]
        var images: [String: NSImage] = [:]
        for (i, c) in covers.enumerated() { images["sample:\(i)"] = Snapshot.sampleArtwork(c) }
        if let album = s.music.topAlbums.first { index.albums[album.id] = "sample:0" }
        for (i, a) in s.music.topArtists.prefix(3).enumerated() { index.artists[a.name] = "sample:\(i + 1)" }
        for (i, t) in s.music.topTracks.prefix(4).enumerated() { index.songs[t.id] = "sample:\(i % 4)" }
        for (i, a) in s.music.topAlbums.dropFirst().prefix(2).enumerated() { index.albums[a.id] = "sample:\(i + 1)" }
        return (index, images)
    }

    /// The same covers, with the top album's swapped for `cover`.
    private static func coverOverride(_ index: ArtworkIndex, _ s: Stats,
                                      _ cover: Snapshot.SampleCover) -> [String: NSImage] {
        var images = sampleArtwork(s).1
        if let album = s.music.topAlbums.first, let key = index.albums[album.id] {
            images[key] = Snapshot.sampleArtwork(cover)
        }
        return images
    }

    /// The year with the longest names Tonearm is likely to meet, in several scripts.
    private static func longNames(_ s: Stats) -> Stats {
        var s = s
        let artists = [
            "Оркестр Северного ветра, Александра Константинопольская",
            "Supercalifragilisticexpialidociousnessmentalism",
            "宇多田ヒカルと坂本龍一と東京フィルハーモニー交響楽団",
            "سامي يوسف وفرقة الأوركسترا السيمفونية الملكية",
            "Florence + The Machine & The London Symphony Orchestra",
        ]
        let songs = [
            "Песня о далёкой звезде над ночным городом (Remastered 2024)",
            "Concerto for Piano and Orchestra No. 2 in C Minor, Op. 18: II. Adagio sostenuto",
            "夜に駆ける、そしてまた夜明けまで歩き続ける長い道",
            "Untitled",
            "The Long and Winding Road That Leads to Your Door (Naked Version, 2013 Remaster)",
        ]
        let albums = [
            "Длинная дорога домой: концерт в Большом зале консерватории",
            "Rachmaninoff: Piano Concertos Nos. 2 & 3; Rhapsody on a Theme of Paganini (Live)",
        ]
        for (i, name) in artists.enumerated() where i < s.music.topArtists.count { s.music.topArtists[i].name = name }
        for (i, name) in songs.enumerated() where i < s.music.topTracks.count {
            s.music.topTracks[i].name = name
            s.music.topTracks[i].artist = artists[i]
        }
        for (i, name) in albums.enumerated() where i < s.music.topAlbums.count {
            s.music.topAlbums[i].name = name
            s.music.topAlbums[i].artist = artists[i]
        }
        for (i, name) in artists.enumerated() where i < s.music.newArtists.top.count {
            s.music.newArtists.top[i].name = name
        }
        return s
    }
}
