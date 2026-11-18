import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// State of the Liner Notes window: which period it shows, its stats, covers, and an import
/// in progress. Talks to `HistoryStore`; snapshots build one with fixed state instead.
@MainActor
final class LinerNotesModel: ObservableObject {
    enum Phase: Equatable {
        /// Reading the store for the first time.
        case loading
        /// No listens at all: the import screen.
        case empty
        case ready
        case failed(HistoryWords.Problem)
    }

    enum ImportState: Equatable {
        case idle
        case running(filesDone: Int, filesTotal: Int, rowsRead: Int)
        /// `plays`: music listens of 30 s or more the import added, the number the page
        /// calls plays. `ImportResult.added` also counts skips and podcast episodes.
        case finished(ImportResult, plays: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var period: Period
    @Published private(set) var stats: Stats?
    /// True while stats for `period` are on their way; the old ones stay, dimmed.
    @Published private(set) var loadingStats = false
    @Published private(set) var years: [Int] = []
    @Published private(set) var total = 0
    @Published private(set) var importState: ImportState = .idle
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var artwork = ArtworkIndex()

    let timeZone: TimeZone
    let isSnapshot: Bool
    private let store: HistoryStore?
    private let fixedNow: Date?
    private var started = false
    private var startedAt: Date?
    private var lastRefresh: Date?
    private var statsToken = 0
    private var loadingURLs = Set<String>()
    /// The user picked a period; refreshes keep it.
    private var chosePeriod = false

    var now: Date { fixedNow ?? Date() }
    var today: LocalDay { LocalDay(now, timeZone: timeZone) }

    init(store: HistoryStore = .shared, timeZone: TimeZone = .current) {
        self.store = store
        self.timeZone = timeZone
        isSnapshot = false
        fixedNow = nil
        period = .current(.year, timeZone: timeZone)
    }

    /// Fixed state, for snapshots. Nothing is loaded.
    init(snapshot phase: Phase, period: Period, stats: Stats?, years: [Int], total: Int,
         importState: ImportState = .idle, artwork: ArtworkIndex = ArtworkIndex(),
         images: [String: NSImage] = [:], now: Date, timeZone: TimeZone) {
        store = nil
        isSnapshot = true
        fixedNow = now
        self.timeZone = timeZone
        self.phase = phase
        self.period = period
        self.stats = stats
        self.years = years
        self.total = total
        self.importState = importState
        self.artwork = artwork
        self.images = images
        started = true
    }

    // MARK: Loading

    func start() {
        guard !started else { return }
        started = true
        startedAt = Date()
        Task { await refresh() }
    }

    /// The window came to the front: picks up what played meanwhile, without dimming the
    /// page. Skipped right after a refresh, such as the one when the window opens.
    func windowBecameKey() {
        guard started, let lastRefresh, Date().timeIntervalSince(lastRefresh) > 2 else { return }
        Task { await refresh(quiet: true) }
    }

    /// Reads the years and count again, then the stats. Keeps the period the user chose.
    /// `quiet` leaves the page as it is while the stats load, and touches it only if they changed.
    func refresh(quiet: Bool = false) async {
        guard let store else { return }
        lastRefresh = Date()
        do {
            let years = try await store.years(timeZone: timeZone)
            let total = try await store.count()
            self.years = years
            self.total = total
            if total == 0 {
                phase = .empty
                stats = nil
                return
            }
            if !chosePeriod { period = defaultPeriod(kind: period.kind) }
            if stats == nil {
                // The first stats: the placeholder page stays until they are in, so the
                // header never sits over an empty page.
                if phase != .loading { phase = .loading }
                guard await loadStats(dim: false) else { return }
                phase = .ready
                logFirstPage()
            } else {
                if phase != .ready { phase = .ready }
                await loadStats(dim: !quiet)
            }
            if let index = try? await store.artwork(), index != artwork { artwork = index }
            loadImages()
        } catch {
            phase = .failed(HistoryWords.problem(error))
        }
    }

    /// This year when it has listens; otherwise the latest year that does.
    private func defaultPeriod(kind: Period.Kind) -> Period {
        Period.opening(kind, years: years, now: now, timeZone: timeZone)
    }

    /// True when these stats are the ones on the page now; false after an error, or when a
    /// later load took over.
    @discardableResult
    private func loadStats(dim: Bool = true) async -> Bool {
        guard let store else { return false }
        statsToken += 1
        let token = statsToken
        let wanted = period
        if dim { loadingStats = true }
        do {
            let s = try await store.stats(for: wanted, timeZone: timeZone)
            guard token == statsToken else { return false }
            if s != stats { stats = s }
            if loadingStats { loadingStats = false }
            loadImages()
            return true
        } catch {
            guard token == statsToken else { return false }
            loadingStats = false
            phase = .failed(HistoryWords.problem(error))
            return false
        }
    }

    /// With `--log-windows` or `--open-liner-notes`: how long the first page took from the
    /// window opening. scripts/liner-notes-live.sh prints it.
    private func logFirstPage() {
        guard let startedAt, LinerNotesWindow.logsWindows else { return }
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        FileHandle.standardError.write(Data("liner-notes-window: first page in \(ms) ms\n".utf8))
    }

    // MARK: Periods

    func select(_ p: Period) {
        chosePeriod = true
        guard p != period else { return }
        period = p
        if !isSnapshot { Task { await loadStats() } }
    }

    func select(kind: Period.Kind) {
        guard kind != period.kind else { return }
        select(Period.of(kind, containing: anchor))
    }

    /// The day the current period points at when switching kinds: its last day, but not
    /// after today, and inside the years that have listens.
    private var anchor: LocalDay {
        var day = today
        if let days = period.days { day = min(days.upperBound.adding(days: -1), today) }
        if let last = years.last, day.year > last { day = LocalDay(year: last, month: 12, day: 31) }
        if let first = years.first, day.year < first { day = LocalDay(year: first, month: 1, day: 1) }
        return day
    }

    var canGoBack: Bool {
        guard let prev = period.previous, let first = years.first, let days = prev.days else { return false }
        return days.upperBound > LocalDay(year: first, month: 1, day: 1)
    }

    var canGoForward: Bool {
        guard let next = period.next, let days = next.days else { return false }
        return days.lowerBound <= today
    }

    func goBack() { if canGoBack, let p = period.previous { select(p) } }
    func goForward() { if canGoForward, let p = period.next { select(p) } }

    /// From the year menu: the same kind of period in `year`, or that year for all time.
    func select(year: Int) {
        switch period {
        case .allTime, .year:
            select(.year(year))
        case .month(_, let m):
            let day = min(LocalDay(year: year, month: m, day: 1), today)
            select(.month(year: day.year, month: day.month))
        case .week(let d):
            let day = LocalDay(year: year, month: d.month, day: min(d.day, 28))
            select(.week(min(day, today)))
        }
    }

    // MARK: Covers

    func image(artist: String) -> NSImage? { artwork.artists[artist].flatMap { images[$0] } }
    func image(song: Stats.Item) -> NSImage? { artwork.songs[song.id].flatMap { images[$0] } }
    func image(album: Stats.Item) -> NSImage? { artwork.albums[album.id].flatMap { images[$0] } }

    /// The top album's cover, or nil when Tonearm never saw it.
    var topAlbumImage: NSImage? { stats?.music.topAlbums.first.flatMap(image(album:)) }

    /// The name the top album's tile is drawn from when there is no cover.
    var topAlbumName: String {
        stats?.music.topAlbums.first?.name ?? stats?.music.topArtists.first?.name ?? "Liner Notes"
    }

    /// Sleeve colors from the top album's cover, or from its tile.
    var sleeve: SleeveColors {
        if let image = topAlbumImage, let colors = SleeveColors(image: image) { return colors }
        return SleeveColors(name: topAlbumName)
    }

    /// Reads the covers on screen from the ones the player kept (`CoverStore`). Never from
    /// the network: browsing past listening sends nothing anywhere. A cover the player
    /// never kept stays a drawn tile.
    private func loadImages() {
        guard !isSnapshot, let store, let s = stats else { return }
        var urls: [String] = []
        for a in s.music.topArtists { if let u = artwork.artists[a.name] { urls.append(u) } }
        for t in s.music.topTracks { if let u = artwork.songs[t.id] { urls.append(u) } }
        for a in s.music.topAlbums { if let u = artwork.albums[a.id] { urls.append(u) } }
        for u in urls where images[u] == nil && !loadingURLs.contains(u) {
            loadingURLs.insert(u)
            Task {
                let data = await store.covers.data(for: u)
                loadingURLs.remove(u)
                if let data, let image = NSImage(data: data) { images[u] = image }
            }
        }
    }

    // MARK: Import

    func chooseImport() {
        guard !isSnapshot else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .json, .folder]
        panel.prompt = "Import"
        panel.message = "Choose the .zip Spotify sent you, or the folder inside it"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.runImport(urls) }
        }
        if let window = LinerNotesWindow.window {
            panel.beginSheetModal(for: window, completionHandler: run)
        } else {
            panel.begin(completionHandler: run)
        }
    }

    func runImport(_ urls: [URL]) {
        guard let store, !urls.isEmpty else { return }
        if case .running = importState { return }
        importState = .running(filesDone: 0, filesTotal: 0, rowsRead: 0)
        Task {
            do {
                let (result, plays) = try await store.importCountingPlays(urls: urls) { p in
                    Task { @MainActor [weak self] in
                        guard let self, case .running = self.importState else { return }
                        self.importState = .running(filesDone: p.filesDone, filesTotal: p.filesTotal,
                                                    rowsRead: p.rowsRead)
                    }
                }
                importState = .finished(result, plays: plays)
                // Show the latest year the import brought.
                if let last = result.last {
                    chosePeriod = true
                    period = Period.of(period.kind == .allTime ? .allTime : .year,
                                       containing: LocalDay(last, timeZone: timeZone))
                }
                await refresh()
            } catch {
                importState = .failed(Self.message(error))
            }
        }
    }

    func dismissImport() {
        if case .running = importState { return }
        importState = .idle
    }

    static func message(_ error: Error) -> String {
        if let e = error as? ImportError { return e.description }
        return HistoryWords.problem(error).detail
    }
}
