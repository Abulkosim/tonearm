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
        case failed(String)
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
        Task { await refresh() }
    }

    /// Reads the years and count again, then the stats. Keeps the period the user chose.
    func refresh() async {
        guard let store else { return }
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
            if phase != .ready { phase = .ready }
            await loadStats()
            if let index = try? await store.artwork() { artwork = index }
            loadImages()
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    /// This year when it has listens; otherwise the latest year that does.
    private func defaultPeriod(kind: Period.Kind) -> Period {
        let current = Period.current(kind, now: now, timeZone: timeZone)
        guard let last = years.last, !years.contains(today.year) else { return current }
        return Period.of(kind, containing: LocalDay(year: last, month: 12, day: 31))
    }

    private func loadStats() async {
        guard let store else { return }
        statsToken += 1
        let token = statsToken
        let wanted = period
        loadingStats = true
        do {
            let s = try await store.stats(for: wanted, timeZone: timeZone)
            guard token == statsToken else { return }
            stats = s
            loadingStats = false
            loadImages()
        } catch {
            guard token == statsToken else { return }
            loadingStats = false
            phase = .failed(Self.message(error))
        }
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

    /// Fetches covers for what is on screen. The player fetches the same covers from Spotify's
    /// image server; nothing about the listener is sent.
    private func loadImages() {
        guard !isSnapshot, let s = stats else { return }
        var urls: [String] = []
        for a in s.music.topArtists { if let u = artwork.artists[a.name] { urls.append(u) } }
        for t in s.music.topTracks { if let u = artwork.songs[t.id] { urls.append(u) } }
        for a in s.music.topAlbums { if let u = artwork.albums[a.id] { urls.append(u) } }
        for u in urls where images[u] == nil && !loadingURLs.contains(u) {
            guard let url = URL(string: u), url.scheme == "https" else { continue }
            loadingURLs.insert(u)
            Task {
                let loaded = try? await URLSession.shared.data(from: url)
                loadingURLs.remove(u)
                if let data = loaded?.0, let image = NSImage(data: data) { images[u] = image }
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
                let before = try await store.playCount()
                let result = try await store.import(urls: urls) { p in
                    Task { @MainActor [weak self] in
                        guard let self, case .running = self.importState else { return }
                        self.importState = .running(filesDone: p.filesDone, filesTotal: p.filesTotal,
                                                    rowsRead: p.rowsRead)
                    }
                }
                let plays = try await store.playCount() - before
                importState = .finished(result, plays: max(0, plays))
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
        return "\(error)"
    }
}
