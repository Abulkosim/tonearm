import AppKit
import SwiftUI

/// Renders every screen a user can see, in every state the code has, so a person can look at
/// all of them after a visible change. CI runs it on every pull request.
///
///     Tonearm --states <dir>
///
/// Writes one PNG per state at 2x, `contact-sheet.png` with all of them captioned, and
/// `report.txt` with each one's size. A state taller than the window the app can give it is
/// marked CLIPPED, and the run fails. So does a light mode render that differs from its dark
/// twin. Needs no Spotify and doesn't touch the user's settings.
@MainActor
enum StateWalk {
    private struct Shot {
        var name: String
        var caption: String
        /// Builds the view when it is rendered, so a playing song's clock starts then.
        var make: @MainActor () -> AnyView
        /// Tallest the window that shows this can be. Nil for things that are not a window.
        var limit: CGFloat?
        /// True for a screen that scrolls when it is taller than `limit` (settings).
        var scrolls = false
        var dark = true
        /// The dark shot this light one should match.
        var twin: String?
    }

    private struct Rendered {
        var shot: Shot
        var file: String
        var image: CGImage
        var size: CGSize
        /// Height with nothing scrolled away or capped.
        var fullHeight: CGFloat
        var clipped: Bool
        var sameAsTwin: Bool?
    }

    /// While true, `pop` builds the window for a screen with no height limit, so nothing in it
    /// is capped or scrolls and its size is the content's full size.
    private static var measuringFullHeight = false

    /// Returns false when a state is clipped or a light render differs from its dark twin.
    static func render(to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Snapshot.fail("cannot create \(dir.path): \(error)")
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }

        var done: [Rendered] = []
        for (i, shot) in allShots().enumerated() {
            NSApplication.shared.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
            func draw() -> CGImage {
                let view = AnyView(shot.make().environment(\.colorScheme, shot.dark ? .dark : .light))
                guard let cg = Snapshot.image(view) else { Snapshot.fail("render failed for \(shot.name)") }
                return cg
            }
            let cg = draw()
            let file = String(format: "%03d", i + 1) + "-\(shot.name).png"
            Snapshot.write(cg, to: dir.appendingPathComponent(file))
            let size = CGSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
            // The same window again on an endless screen, for the height of all its content.
            var fullHeight = size.height
            if shot.limit != nil {
                measuringFullHeight = true
                fullHeight = CGFloat(draw().height) / 2
                measuringFullHeight = false
            }
            // A window taller than its limit runs off the screen. One that doesn't scroll must
            // fit whole; one that scrolls must stay within the limit.
            let clipped = shot.limit.map { limit in
                size.height > limit + 0.5 || (!shot.scrolls && fullHeight > limit + 0.5)
            } ?? false
            let twin = shot.twin.flatMap { name in done.first { $0.shot.name == name } }
            done.append(Rendered(shot: shot, file: file, image: cg, size: size, fullHeight: fullHeight,
                                 clipped: clipped, sameAsTwin: twin.map { samePixels($0.image, cg) }))
        }
        NSApplication.shared.appearance = nil

        var report = "Tonearm state walk: \(done.count) states. Small screen \(Int(WalkScreen.small)) pt, "
            + "large screen \(Int(WalkScreen.large)) pt high.\n"
            + "Columns: file, size shown, full height of the content, the window's height limit, result.\n\n"
        for r in done {
            let size = "\(Int(r.size.width))x\(Int(r.size.height.rounded()))"
            let full = "full \(Int(r.fullHeight.rounded()))"
            let limit = r.shot.limit.map { "max \(Int($0))" } ?? "-"
            var flags = r.clipped ? "CLIPPED" : "ok"
            if r.fullHeight > r.size.height + 0.5 { flags += ", scrolls" }
            if let same = r.sameAsTwin { flags += same ? ", same as \(r.shot.twin ?? "")" : ", DIFFERS from \(r.shot.twin ?? "")" }
            report += "\(r.file)  \(size)  \(full)  \(limit)  \(flags)  \(r.shot.caption)\n"
        }
        let clipped = done.filter(\.clipped)
        let differs = done.filter { $0.sameAsTwin == false }
        report += clipped.isEmpty ? "\nNothing clipped.\n"
            : "\nCLIPPED: \(clipped.map(\.file).joined(separator: ", "))\n"
        report += differs.isEmpty ? "Every light render matches its dark twin.\n"
            : "DIFFERS FROM DARK: \(differs.map(\.file).joined(separator: ", "))\n"
        do {
            try report.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        } catch {
            Snapshot.fail("cannot write report.txt: \(error)")
        }
        print(report, terminator: "")

        guard let sheet = contactSheet(done) else { Snapshot.fail("cannot draw the contact sheet") }
        Snapshot.write(sheet, to: dir.appendingPathComponent("contact-sheet.png"))
        return clipped.isEmpty && differs.isEmpty
    }

    // MARK: - States

    private static func allShots() -> [Shot] {
        var s: [Shot] = []
        let bigLimit = WalkScreen.large - 8
        func add(_ name: String, _ caption: String, _ view: @autoclosure @escaping @MainActor () -> AnyView,
                 limit: CGFloat? = WalkScreen.popLimit, scrolls: Bool = false) {
            s.append(Shot(name: name, caption: caption, make: view, limit: limit, scrolls: scrolls))
        }

        // App status. Each is what the window shows while Spotify is in that state.
        add("not-installed", "Spotify not installed", pop(idle()) { $0.status = .notInstalled })
        add("not-running", "Spotify not running", pop(idle()) { $0.status = .notRunning })
        add("starting", "Open Spotify clicked, waiting for it to start", pop(idle()) {
            $0.status = .notRunning
            $0.launching = true
        })
        add("connecting", "Spotify process up, not answering yet", pop(idle()) {
            $0.status = .notRunning
            $0.connecting = true
        })
        add("asking-permission", "macOS permission prompt open", pop(asking()))
        add("permission-denied", "Automation permission denied", pop(idle()) { $0.status = .notAuthorized })
        add("quit-mid-play", "Spotify quit while a song played (stale song in the model)",
            pop(playing(Samples.song)) { $0.status = .notRunning })
        add("nothing-playing", "Spotify open, nothing playing", pop(playing(nil, state: .stopped)))
        add("loading-cover", "Song known, cover still loading", pop(playing(Samples.song, cover: nil)))
        add("playing", "Playing", pop(playing(Samples.song)))
        add("paused", "Paused", pop(playing(Samples.song, state: .paused)))
        add("progress-hover", "Pointer on the progress bar", pop(playing(Samples.song)) { $0.progressHover = true })
        add("cover-hover", "Pointer on the cover", pop(playing(Samples.song)) { $0.coverHover = true })
        add("cover-copied", "Song link copied", pop(playing(Samples.song)) {
            $0.coverHover = true
            $0.coverNote = "Copied"
        })
        add("cover-no-link", "Local file: no link to copy", pop(playing(Samples.local, cover: nil)) {
            $0.coverHover = true
            $0.coverNote = "No link"
        })

        // Compact layout.
        add("compact-playing", "Compact, playing", pop(playing(Samples.song), layout: .compact))
        add("compact-paused", "Compact, paused", pop(playing(Samples.song, state: .paused), layout: .compact))
        add("compact-nothing-playing", "Compact, nothing playing",
            pop(playing(nil, state: .stopped), layout: .compact))
        add("compact-no-cover", "Compact, no cover", pop(playing(Samples.local, cover: nil), layout: .compact))
        add("compact-not-running", "Compact chosen, Spotify not running (falls back to large)",
            pop(idle(), layout: .compact) { $0.status = .notRunning })

        // Song text and numbers, in both layouts.
        let texts: [(String, String, Track)] = [
            ("long-latin", "Very long title, artist and album", Samples.longLatin),
            ("long-cyrillic", "Long Cyrillic title, artist and album", Samples.longCyrillic),
            ("one-char", "One-character title, artist and album", Samples.oneChar),
            ("cyrillic", "Cyrillic", Samples.cyrillic),
            ("cjk", "Japanese", Samples.cjk),
            ("cjk-long", "Long Japanese", Samples.cjkLong),
            ("arabic", "Arabic, right to left", Samples.arabic),
            ("arabic-long", "Long Arabic, right to left", Samples.arabicLong),
            ("mixed-rtl", "Latin and Arabic mixed", Samples.mixed),
            ("emoji", "Emoji", Samples.emoji),
            ("empty-title", "No title, artist only", Samples.emptyTitle),
        ]
        for (name, caption, track) in texts {
            add("text-\(name)", caption, pop(playing(track)))
            add("text-\(name)-compact", "\(caption), compact", pop(playing(track), layout: .compact))
        }
        add("ad", "Ad: no artist, album, cover or link", pop(playing(Samples.ad, position: 12, cover: nil)))
        add("ad-compact", "Ad, compact", pop(playing(Samples.ad, position: 12, cover: nil), layout: .compact))
        add("episode", "Podcast episode over an hour", pop(playing(Samples.episode, position: 1834)))
        add("episode-compact", "Podcast episode, compact",
            pop(playing(Samples.episode, position: 1834), layout: .compact))
        add("local-file", "Local file, no cover", pop(playing(Samples.local, cover: nil)))
        add("no-duration", "Unknown length, at 0", pop(playing(Samples.noDuration, position: 0)))
        add("no-duration-later", "Unknown length, 42 s in", pop(playing(Samples.noDuration, position: 42)))
        add("no-duration-compact", "Unknown length, compact",
            pop(playing(Samples.noDuration, position: 42), layout: .compact))
        add("position-start", "At 0:00", pop(playing(Samples.song, position: 0)))
        add("position-end", "At the very end", pop(playing(Samples.song, position: 214)))
        add("position-end-compact", "At the very end, compact",
            pop(playing(Samples.song, position: 214), layout: .compact))
        add("volume-0", "Volume 0", pop(playing(Samples.song, volume: 0)))
        add("volume-100", "Volume 100", pop(playing(Samples.song, volume: 100)))
        add("shuffle-repeat", "Shuffle and repeat on", pop(playing(Samples.song, shuffle: true, repeating: true)))
        add("shuffle-repeat-compact", "Shuffle and repeat on, compact",
            pop(playing(Samples.song, shuffle: true, repeating: true), layout: .compact))

        // Cover colors, for contrast.
        let covers: [(String, Snapshot.SampleCover)] = [
            ("teal", .teal), ("warm", .warm), ("pale", .pale), ("black", .black),
        ]
        for (name, cover) in covers {
            add("cover-\(name)", "Cover: \(name)", pop(playing(Samples.song, cover: cover)))
            add("cover-\(name)-compact", "Cover: \(name), compact",
                pop(playing(Samples.song, cover: cover), layout: .compact))
        }

        // Settings. They scroll when they are taller than the window can be.
        add("settings-small-top", "Settings, small screen, top",
            pop(playing(Samples.song)) { $0.settingsOpen = true }, scrolls: true)
        add("settings-small-bottom", "Settings, small screen, scrolled to the bottom",
            pop(playing(Samples.song)) {
                $0.settingsOpen = true
                $0.settingsScroll = 1
            }, scrolls: true)
        add("settings-large", "Settings, 1440 x 900 screen",
            pop(playing(Samples.song), screen: WalkScreen.large) { $0.settingsOpen = true },
            limit: bigLimit, scrolls: true)
        add("settings-icon-only", "Settings: icon only, compact, shortcuts on",
            pop(playing(Samples.song), screen: WalkScreen.large) {
                $0.settingsOpen = true
                $0.settings = settings { s in
                    s.menuBarStyle = .iconOnly
                    s.layout = .compact
                    s.globalShortcuts = true
                }
            }, limit: bigLimit, scrolls: true)
        add("settings-every-note", "Settings: notifications blocked, login item needs approval",
            pop(playing(Samples.song), screen: WalkScreen.large) {
                $0.settingsOpen = true
                $0.notificationsDenied = true
                $0.loginNeedsApproval = true
                $0.settings = settings { s in
                    s.showArtist = true
                    s.notifyOnTrackChange = true
                }
            }, limit: bigLimit, scrolls: true)
        add("settings-every-note-small-bottom", "Settings: every note, small screen, bottom",
            pop(playing(Samples.song)) {
                $0.settingsOpen = true
                $0.settingsScroll = 1
                $0.notificationsDenied = true
                $0.loginNeedsApproval = true
                $0.canCheckForUpdates = false
            }, scrolls: true)
        add("settings-length-min", "Settings: shortest title length",
            pop(playing(Samples.song)) {
                $0.settingsOpen = true
                $0.settings = settings { $0.maxTitleLength = AppSettings.titleLengthRange.lowerBound }
            }, scrolls: true)
        add("settings-length-max", "Settings: longest title length",
            pop(playing(Samples.song)) {
                $0.settingsOpen = true
                $0.settings = settings { $0.maxTitleLength = AppSettings.titleLengthRange.upperBound }
            }, scrolls: true)
        add("settings-not-running", "Settings while Spotify isn't running",
            pop(idle()) {
                $0.status = .notRunning
                $0.settingsOpen = true
            }, scrolls: true)

        // Settings > History and ListenBrainz. The whole panel, then the real window scrolled to them.
        let march2019 = HistorySettingsModel.date(2019, 3, 4)
        let full = HistorySummary(count: 48_872, first: march2019, last: HistorySettingsModel.date(2026, 11, 16))
        let since = ListenBrainzSync.ms(HistorySettingsModel.date(2026, 11, 1))
        let sending = ListenBrainzSync.HistorySend(
            before: since, first: ListenBrainzSync.ms(march2019),
            cursor: ListenCursor(startedAt: ListenBrainzSync.ms(HistorySettingsModel.date(2021, 6, 2)), id: 1),
            sent: 14_000)
        let connected = ListenBrainzSync.Saved(userName: "rob_listens", sent: 112, live: [.init(from: since)],
                                               history: sending)
        var waiting = ListenBrainzSync.Saved(userName: "rob_listens", sent: 112, live: [.init(from: since)])
        waiting.pending = (0..<3).map {
            LBListen(key: "s\($0)", listenedAt: 1_700_000_000 + Int64($0) * 300, track: "Song", artist: "Artist")
        }
        var done = connected
        done.history?.finished = HistorySettingsModel.date(2026, 11, 2)
        done.history?.sent = 39_410
        let imported = HistorySettingsModel.Note(action: .imported, text: HistorySettingsModel.describe(
            ImportResult(files: 7, rows: 51_000, added: 48_872, duplicates: 1_203, skipped: 925,
                         unreadable: ["notes.json"], first: march2019, last: HistorySettingsModel.date(2026, 10, 30))))
        let exported = HistorySettingsModel.Note(action: .exported,
                                                 text: "Saved 48,872 listens to Tonearm listens 2026-11-17.csv.",
                                                 file: URL(fileURLWithPath: "/tmp/listens.csv"))
        let deleteFailed = HistorySettingsModel.Note(action: .deleted, text: "Could not delete: the database is busy",
                                                     isError: true)
        add("settings-history-empty", "History: nothing stored, recording off, ListenBrainz off",
            panel(.preview(summary: HistorySummary()), .preview(connection: .noToken)) { $0.recordHistory = false },
            limit: nil)
        add("settings-history-importing", "History: importing; ListenBrainz on, token typed",
            panel(.preview(summary: full, importing: ImportProgress(filesDone: 3, filesTotal: 7, rowsRead: 31_204)),
                  .preview(connection: .noToken), token: "0a1b2c3d-4e5f") { $0.listenBrainz = true },
            limit: nil)
        add("settings-history-imported", "History: import done; ListenBrainz refused the token, 3 waiting",
            panel(.preview(summary: full, note: imported),
                  .preview(connection: .tokenRejected, saved: waiting,
                           problem: "ListenBrainz no longer accepts the token. Paste a new one."),
                  token: "wrong") { $0.listenBrainz = true },
            limit: nil)
        add("settings-history-delete", "History: delete confirmation; ListenBrainz sending earlier listens",
            panel(.preview(summary: full, confirmingDelete: true), .preview(connection: .connected, saved: connected)) {
                $0.listenBrainz = true
            }, limit: nil)
        add("settings-history-offline", "History: exported; ListenBrainz offline with listens waiting",
            panel(.preview(summary: full, note: exported),
                  .preview(connection: .connected, saved: waiting, problem: "Can't reach ListenBrainz.",
                           retryAt: Date().addingTimeInterval(120))) { $0.listenBrainz = true },
            limit: nil)
        add("settings-history-sent", "History: recording off, delete failed; earlier listens all sent",
            panel(.preview(summary: full, note: deleteFailed), .preview(connection: .connected, saved: done)) {
                $0.listenBrainz = true
                $0.recordHistory = false
            }, limit: nil)
        add("settings-large-history", "Settings, 1440 x 900 screen, scrolled to History",
            pop(playing(Samples.song), screen: WalkScreen.large) {
                $0.settingsOpen = true
                $0.settingsScroll = 0.62
                $0.settings = settings { $0.listenBrainz = true }
                $0.listenBrainz = ListenBrainzSync.preview(connection: .connected, saved: connected)
            }, limit: bigLimit, scrolls: true)
        add("settings-small-history", "Settings, small screen, scrolled to History",
            pop(playing(Samples.song)) {
                $0.settingsOpen = true
                $0.settingsScroll = 0.6
            }, scrolls: true)

        // Welcome window.
        let welcomeLimit = WalkScreen.small - 12
        add("welcome", "Welcome window", AnyView(Onboarding.snapshotView(spotifyInstalled: true)), limit: welcomeLimit)
        add("welcome-no-spotify", "Welcome window, Spotify not installed",
            AnyView(Onboarding.snapshotView(spotifyInstalled: false)), limit: welcomeLimit)

        // Menu bar label, on a dark and a light menu bar.
        let bars: [(String, String, PlayerModel, AppSettings)] = [
            ("icon-only", "Icon only style", playing(Samples.song), settings { $0.menuBarStyle = .iconOnly }),
            ("not-running", "Spotify not running", idle(), settings()),
            ("nothing-playing", "Nothing playing", playing(nil, state: .stopped), settings()),
            ("playing", "Playing", playing(Samples.song), settings()),
            ("paused", "Paused", playing(Samples.song, state: .paused), settings()),
            ("artist", "Playing, with artist", playing(Samples.song), settings { $0.showArtist = true }),
            ("long", "Long title cut at 24", playing(Samples.longLatin), settings { $0.showArtist = true }),
            ("long-60", "Long title cut at 60", playing(Samples.longLatin), settings {
                $0.showArtist = true
                $0.maxTitleLength = 60
            }),
            ("short-15", "Title cut at 15", playing(Samples.longLatin), settings { $0.maxTitleLength = 15 }),
            ("cjk", "Japanese", playing(Samples.cjkLong), settings { $0.showArtist = true }),
            ("arabic", "Arabic", playing(Samples.arabicLong), settings { $0.showArtist = true }),
            ("mixed-rtl", "Arabic title, Latin artist", playing(Samples.arabicLatinArtist), settings {
                $0.showArtist = true
            }),
            ("emoji", "Emoji", playing(Samples.emoji), settings { $0.showArtist = true }),
            ("empty-title", "No title, artist on", playing(Samples.emptyTitle), settings { $0.showArtist = true }),
            ("ad", "Ad", playing(Samples.ad, cover: nil), settings { $0.showArtist = true }),
        ]
        for dark in [true, false] {
            for (name, caption, model, bar) in bars {
                let look = dark ? "dark" : "light"
                let view = menuBar(model, bar, dark: dark)
                s.append(Shot(name: "menubar-\(look)-\(name)", caption: "Menu bar, \(look): \(caption)",
                              make: { view }, limit: nil, dark: dark))
            }
        }

        // Light appearance. The window and welcome pin dark mode in SwiftUI, so these must match
        // their dark twins pixel for pixel, and the run fails if one doesn't. That catches a view
        // that follows the system's light mode. It can't see what AppKit draws, such as the
        // window itself, which ImageRenderer doesn't render.
        add("cover-pale-paused", "Cover: pale, paused", pop(playing(Samples.song, state: .paused, cover: .pale)))
        let lightTwins = ["paused", "compact-paused", "nothing-playing", "not-running",
                          "settings-small-top", "cover-pale-paused", "welcome"]
        for name in lightTwins {
            guard let dark = s.first(where: { $0.name == name }) else { continue }
            s.append(Shot(name: "light-\(name)", caption: "Light mode: \(dark.caption)", make: dark.make,
                          limit: dark.limit, scrolls: dark.scrolls, dark: false, twin: name))
        }
        return s
    }

    // MARK: - Building blocks

    private static let defaultsSuite = "tonearm.states"

    /// Settings kept in their own defaults suite, starting from the app's defaults.
    private static func settings(_ edit: (AppSettings) -> Void = { _ in }) -> AppSettings {
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            Snapshot.fail("cannot open the \(defaultsSuite) defaults")
        }
        let s = AppSettings(defaults: defaults)
        s.menuBarStyle = .songTitle
        s.showArtist = false
        s.maxTitleLength = AppSettings.defaultTitleLength
        s.layout = .large
        s.globalShortcuts = false
        s.notifyOnTrackChange = false
        s.recordHistory = true
        s.listenBrainz = false
        edit(s)
        return s
    }

    /// The player window, 300 points wide and as tall as it wants to be.
    private static func pop(_ model: PlayerModel, layout: PlayerLayout = .large, screen: CGFloat = WalkScreen.small,
                            _ edit: (inout PlayerView.Preview) -> Void = { _ in }) -> AnyView {
        var preview = PlayerView.Preview()
        preview.layout = layout
        preview.screenHeight = measuringFullHeight ? 100_000 : screen
        preview.settings = settings { $0.layout = layout }
        edit(&preview)
        return AnyView(PlayerView(preview: preview).environmentObject(model))
    }

    /// The settings panel alone at its full height, with History and ListenBrainz in a given state.
    private static func panel(_ history: HistorySettingsModel, _ listenBrainz: ListenBrainzSync, token: String = "",
                              _ edit: (AppSettings) -> Void = { _ in }) -> AnyView {
        AnyView(
            SettingsView(settings: settings(edit), history: history, listenBrainz: listenBrainz, token: token)
                .padding(16)
                .frame(width: 300)
                .background(PlayerTheme.fallback)
        )
    }

    /// Before Spotify answers: no song, status from the preview.
    private static func idle() -> PlayerModel {
        PlayerModel(live: false)
    }

    private static func asking() -> PlayerModel {
        let model = PlayerModel(live: false)
        model.setPreviewAskingPermission()
        return model
    }

    private static func playing(_ track: Track?, state: PlayState = .playing, position: Double = 83,
                                volume: Int = 70, shuffle: Bool = false, repeating: Bool = false,
                                cover: Snapshot.SampleCover? = .teal) -> PlayerModel {
        let model = PlayerModel(live: false)
        let shown = state == .stopped ? nil : track
        let playback = Playback(state: state, track: shown, position: shown == nil ? 0 : position,
                                volume: volume, shuffling: shuffle, repeating: repeating)
        model.setPreview(playback, artwork: shown == nil ? nil : cover.map { Snapshot.sampleArtwork($0) })
        return model
    }

    /// Tonearm's real label in a mock menu bar. macOS draws the real one in the menu bar's
    /// own text color, black on a light bar and white on a dark one.
    private static func menuBar(_ model: PlayerModel, _ settings: AppSettings, dark: Bool) -> AnyView {
        let ink: Color = dark ? .white : .black
        return AnyView(
            HStack(spacing: 16) {
                MenuBarLabel(model: model, settings: settings)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ink.opacity(dark ? 0.22 : 0.12)))
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
                Text("Tue 10:42")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(dark ? Color(white: 0.14) : Color(white: 0.92))
        )
    }

    private static func samePixels(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data
        else { return false }
        return (da as Data) == (db as Data)
    }

    // MARK: - Contact sheet

    /// All states in a grid at 1x, each with its file name, caption and size under it.
    private static func contactSheet(_ cells: [Rendered]) -> CGImage? {
        let columns = 8
        let cellWidth: CGFloat = 420
        let gap: CGFloat = 24
        let captionHeight: CGFloat = 50
        let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
        // A cell wider than the column is scaled down whole, keeping its proportions.
        func drawSize(_ cell: Rendered) -> CGSize {
            let scale = min(1, cellWidth / cell.size.width)
            return CGSize(width: cell.size.width * scale, height: cell.size.height * scale)
        }
        let rowHeights = rows.map { row in (row.map { drawSize($0).height }.max() ?? 0) + captionHeight + gap }
        let width = gap + CGFloat(columns) * (cellWidth + gap)
        let height = gap + rowHeights.reduce(0, +)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.33, green: 0.34, blue: 0.36, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Top-left origin, like the views.
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        graphics.imageInterpolation = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let nameStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ]
        let captionStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(white: 0.88, alpha: 1), .paragraphStyle: paragraph,
        ]
        let flagStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 1, green: 0.45, blue: 0.4, alpha: 1), .paragraphStyle: paragraph,
        ]

        var y = gap
        for (row, rowHeight) in zip(rows, rowHeights) {
            for (i, cell) in row.enumerated() {
                let x = gap + CGFloat(i) * (cellWidth + gap)
                let shown = drawSize(cell)
                let rect = NSRect(x: x, y: y, width: shown.width, height: shown.height)
                NSImage(cgImage: cell.image, size: cell.size)
                    .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                let top = y + shown.height + 6
                let file = (cell.file as NSString).deletingPathExtension
                NSAttributedString(string: file, attributes: nameStyle)
                    .draw(in: NSRect(x: x, y: top, width: cellWidth, height: 16))
                let size = "\(Int(cell.size.width)) x \(Int(cell.size.height.rounded()))"
                let caption = NSMutableAttributedString(string: "\(cell.shot.caption) · \(size)", attributes: captionStyle)
                if cell.clipped {
                    caption.append(NSAttributedString(string: "  CLIPPED", attributes: flagStyle))
                }
                if cell.sameAsTwin == false {
                    caption.append(NSAttributedString(string: "  DIFFERS FROM DARK", attributes: flagStyle))
                }
                caption.draw(in: NSRect(x: x, y: top + 17, width: cellWidth, height: 16))
            }
            y += rowHeight
        }
        return ctx.makeImage()
    }
}

/// Screen heights the walk measures against, in points. Outside `StateWalk`, which runs on
/// the main actor, so default arguments can use them.
private enum WalkScreen {
    /// Height under the menu bar and above the Dock on the smallest screen to design for: a
    /// 13-inch MacBook Air at its Larger Text setting (1024 x 640), less the menu bar (24)
    /// and a Dock at the bottom (56).
    static let small: CGFloat = 560
    /// The same on a 1440 x 900 screen, the default on most MacBooks.
    static let large: CGFloat = 820
    /// The player window's limit on the small screen: `PlayerView` leaves an 8 point gap.
    static let popLimit: CGFloat = small - 8
}

// MARK: - Sample songs

private enum Samples {
    static func track(_ id: String, _ title: String, _ artist: String, _ album: String,
                      _ duration: Double) -> Track {
        Track(id: id, title: title, artist: artist, album: album, artworkURL: nil, duration: duration)
    }

    static let song = track("spotify:track:0000000000000000000000", "Sample Song Title", "Sample Artist",
                            "Sample Album", 214)
    static let longLatin = track(
        "spotify:track:3333333333333333333333",
        "The Unbearable Lightness of Being Somewhere Else Entirely (Extended Club Mix, 2024 Remaster)",
        "Mariana Constantinopoulou-Vanderbilt, The Northern Wind Orchestra and Friends",
        "Collected Recordings From the Long Winter Sessions, Volume Three (Deluxe Edition)", 431)
    static let longCyrillic = Snapshot.SampleTrack.long.track
    static let oneChar = track("spotify:track:4444444444444444444444", "X", "Ø", "1", 61)
    static let cyrillic = track("spotify:track:5555555555555555555555", "Группа крови", "Кино", "Группа крови", 286)
    static let cjk = track("spotify:track:6666666666666666666666", "夜に駆ける", "YOASOBI", "THE BOOK", 261)
    static let cjkLong = track(
        "spotify:track:7777777777777777777777",
        "千と千尋の神隠し サウンドトラック「あの夏へ」ピアノ・ソロ・バージョン",
        "久石譲と新日本フィルハーモニー交響楽団", "千と千尋の神隠し サウンドトラック", 323)
    static let arabic = track("spotify:track:8888888888888888888888", "أغنية عن البحر والليل الطويل", "فيروز",
                              "أجمل الأغاني", 245)
    static let arabicLong = track(
        "spotify:track:9999999999999999999999",
        "يا حبيبي تعال الحقني شوف اللي جرالي من بعدك يا حبيبي (نسخة مطولة)",
        "أم كلثوم وفرقة الموسيقى العربية", "روائع الطرب الأصيل", 2710)
    static let mixed = track("spotify:track:1212121212121212121212", "Habibi (حبيبي) Remix 2024",
                             "DJ Example & فرقة النور", "Nights (ليالي)", 198)
    static let arabicLatinArtist = track("spotify:track:1313131313131313131313", "أغنية عن البحر",
                                         "Sample Artist", "Sample Album", 198)
    static let emoji = track("spotify:track:1414141414141414141414", "🔥 Fire on the Dancefloor 💃🕺",
                             "The 😀 Emoji Band", "✨ Sparkles ✨", 177)
    static let emptyTitle = track("spotify:track:1515151515151515151515", "", "Unknown Artist", "", 200)
    static let ad = track("spotify:ad:00000000000000000000000000000000", "Spotify", "", "", 30)
    static let episode = track(
        "spotify:episode:1616161616161616161616",
        "#212: How Records Are Made, From the Lacquer to the Press, With a Visit to the Last Plant in Town",
        "The Long Listen", "The Long Listen", 5520)
    static let local = track("spotify:local:Some+Artist:Demo+Tapes:Basement+Take+3:187", "Basement Take 3",
                             "Some Artist", "Demo Tapes", 187)
    static let noDuration = track("spotify:track:1717171717171717171717", "Live Stream of Unknown Length",
                                  "Sample Artist", "Sample Album", 0)
}
