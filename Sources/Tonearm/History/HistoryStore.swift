import Foundation

/// Every listen, kept on this Mac in SQLite. Nothing here talks to the network.
///
/// The API for the rest of the app (all calls are safe from any thread; async ones run on
/// the store's own queue):
///
///     let store = HistoryStore.shared
///     let result = try await store.import(urls: picked) { p in ... }   // a folder, .zip or .json files
///     let stats = try await store.stats(for: .current(.year))          // or .year(2023), .allTime, ...
///     let years = try await store.years()                              // years that have listens
///     let n = try await store.count()
///     let written = try await store.export(to: url, format: .csv)
///     try await store.deleteAll()
///
/// `PlayRecorder` adds what Tonearm hears live (`save(_:)`). Stats definitions are on `Stats`.
/// The database is ~/Library/Application Support/Tonearm/history.sqlite.
final class HistoryStore: @unchecked Sendable {
    static let shared: HistoryStore = {
        let store = HistoryStore(url: HistoryStore.defaultURL)
        store.compactionDefaults = .standard
        return store
    }()

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Tonearm", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    static let schemaVersion: Int64 = 1

    let url: URL
    private let queue = DispatchQueue(label: "io.github.abulkosim.tonearm.history", qos: .utility)
    /// An unpacked export this old is left over from an import that never finished.
    static let leftoverAge: TimeInterval = 3600
    /// Opened on first use, on `queue`.
    private var database: SQLiteDB?
    /// Live listens that started before this (UTC ms) are dropped: they were deleted.
    private var liveFloor: Int64 = .min
    private var catalogCache: StatsEngine.Catalog?
    /// After an import that changed something, rewrite the file so each table and index
    /// lies in one piece (see `compactNow`). `Tonearm --stats --no-compact` turns it off, to
    /// measure what it saves.
    var compactsAfterImport = true
    /// Where `warm` remembers that it compacted the file once. Databases imported into by
    /// v0.4.0 were never compacted, and would stay slow to read cold until the next import.
    /// Nil (tests, `Tonearm --stats`) skips that.
    var compactionDefaults: UserDefaults?
    static let compactedKey = "historyCompacted"
    /// Set by `Tonearm --stats`: gets "name N ms" for each part of an import, a stats call
    /// and the launch warm-up, so the speed check can say where the time goes.
    var phaseLog: ((String) -> Void)?
    /// Where imports unpack a .zip. Tests use their own.
    var temporaryDirectory = FileManager.default.temporaryDirectory

    /// Covers the player downloaded, beside the database. See `CoverStore`.
    let covers: CoverStore

    init(url: URL) {
        self.url = url
        covers = CoverStore(directory: url.deletingLastPathComponent().appendingPathComponent("Covers", isDirectory: true))
    }

    // MARK: Public API

    func `import`(urls: [URL], progress: ((ImportProgress) -> Void)? = nil) async throws -> ImportResult {
        try await onQueueThrowing { try self.importNow(urls: urls, progress: progress) }
    }

    /// Imports, and counts the plays the import added: music of 30 s or more, the number
    /// Liner Notes and Settings call plays. `ImportResult.added` also counts short plays and
    /// podcast episodes, and a live listen the export replaced is not a new play.
    func importCountingPlays(urls: [URL], progress: ((ImportProgress) -> Void)? = nil) async throws
        -> (result: ImportResult, plays: Int) {
        try await onQueueThrowing {
            let before = try self.playCountNow()
            let result = try self.importNow(urls: urls, progress: progress)
            let after = try self.playCountNow()
            return (result, max(0, after - before))
        }
    }

    /// Stats for `period` in `timeZone`. Throws if the database can't be read, so "no
    /// history" and "history unreadable" look different.
    func stats(for period: Period, timeZone: TimeZone = .current) async throws -> Stats {
        try await onQueueThrowing { try self.statsNow(for: period, timeZone: timeZone) }
    }

    /// Years with at least one listen, oldest first, in `timeZone`.
    func years(timeZone: TimeZone = .current) async throws -> [Int] {
        try await onQueueThrowing { try self.yearsNow(timeZone: timeZone) }
    }

    func count() async throws -> Int {
        try await onQueueThrowing { try self.countNow() }
    }

    /// Music listens of 30 s or more: what Liner Notes calls plays (`Stats.music.listens`
    /// for all time).
    func playCount() async throws -> Int {
        try await onQueueThrowing { try self.playCountNow() }
    }

    /// Cover URLs Tonearm saw while playing, for Liner Notes. Imports have none.
    func artwork() async throws -> ArtworkIndex {
        try await onQueueThrowing { try self.artworkNow() }
    }

    /// Writes every listen to `url`. Returns how many.
    @discardableResult
    func export(to url: URL, format: ExportFormat) async throws -> Int {
        try await onQueueThrowing { try self.exportNow(to: url, format: format) }
    }

    func deleteAll() async throws {
        try await onQueueThrowing { try self.deleteAllNow() }
    }

    /// How many entries and plays there are, and the first and last start time. For settings.
    func summary() async throws -> HistorySummary {
        try await onQueueThrowing { try self.summaryNow() }
    }

    /// Music listens that started before `before` (UTC ms), oldest first, after `cursor`.
    /// For sending history to ListenBrainz a page at a time.
    func musicPage(after cursor: ListenCursor?, before: Int64, limit: Int) async throws -> [StoredListen] {
        try await onQueueThrowing { try self.musicPageNow(after: cursor, before: before, limit: limit) }
    }

    /// The longest play of each music track, and the longest that ran to the end, by track
    /// id. A stand-in for the length of tracks only known from an export, which has no lengths.
    func longestPlays() async throws -> [Int64: PlayLengths] {
        try await onQueueThrowing { try self.longestPlaysNow() }
    }

    /// At launch: reads what the Liner Notes window reads when it opens, so the first open
    /// finds the database open, the track catalog loaded and the file in the cache. On the
    /// store's queue, at utility priority. Does nothing when there is no history file, so it
    /// never makes one.
    func warm(timeZone: TimeZone = .current) {
        queue.async {
            HistoryFiles.removeLeftovers(in: self.temporaryDirectory, olderThan: Self.leftoverAge)
            guard FileManager.default.fileExists(atPath: self.url.path) else { return }
            self.compactOnce()
            do {
                try self.warmNow(timeZone: timeZone)
            } catch {
                NSLog("Tonearm: could not read the history at launch: %@", "\(error)")
            }
        }
    }

    /// The reads behind `warm`, on the calling thread: the years, the count, the covers,
    /// and the stats of the period the window opens on. Returns that period.
    @discardableResult
    func warmNow(timeZone: TimeZone, now: Date = Date()) throws -> Period? {
        let years = try timed("warm years") { try yearsNow(timeZone: timeZone) }
        _ = try timed("warm count") { try countNow() }
        _ = try timed("warm covers") { try artworkNow() }
        guard !years.isEmpty else { return nil }
        let period = Period.opening(.year, years: years, now: now, timeZone: timeZone)
        _ = try statsNow(for: period, timeZone: timeZone)
        return period
    }

    /// Compacts the file the first time this Tonearm warms it (see `compactionDefaults`).
    /// A compaction that fails or is cut off is tried again at the next launch.
    func compactOnce() {
        guard let defaults = compactionDefaults, !defaults.bool(forKey: Self.compactedKey) else { return }
        do {
            try timed("warm compact") { try compactNow() }
            defaults.set(true, forKey: Self.compactedKey)
        } catch {
            NSLog("Tonearm: could not compact the history at launch: %@", "\(error)")
        }
    }

    /// Runs `body`, and logs how long it took when `phaseLog` is set.
    private func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard let phaseLog else { return try body() }
        let start = DispatchTime.now()
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            phaseLog(String(format: "%@ %.1f ms", name, ms))
        }
        return try body()
    }

    // MARK: Live recording

    /// Stores or updates a listen Tonearm heard. Writes are queued in order. A failed write
    /// is logged; the next save of the same listen tries again.
    func save(_ listen: LiveListen) {
        queue.async {
            do {
                try self.saveNow(listen)
            } catch {
                NSLog("Tonearm: could not save a listen: %@", "\(error)")
            }
        }
    }

    /// Waits for queued writes. Blocks for as long as an import runs; the app uses
    /// `flush(timeout:)`.
    func flush() {
        queue.sync {}
    }

    /// Waits for queued writes, but no longer than `timeout` seconds.
    func flush(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    // MARK: Queue

    private func onQueueThrowing<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try body() }) }
        }
    }

    /// Runs `body` on the store's queue and waits. For the command line and tests.
    func sync<T>(_ body: (HistoryStore) throws -> T) rethrows -> T {
        try queue.sync { try body(self) }
    }

    // MARK: Database

    /// Opens the database on first use. A failed open is not remembered: the next call
    /// tries again, so a passing problem (a full disk, say) does not stop recording until
    /// relaunch.
    private func db() throws -> SQLiteDB {
        if let database { return database }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = try SQLiteDB(path: url.path)
        try Self.migrate(d)
        database = d
        return d
    }

    static func migrate(_ d: SQLiteDB) throws {
        try d.exec("PRAGMA journal_mode = WAL")
        try d.exec("PRAGMA synchronous = NORMAL")
        try d.exec("PRAGMA foreign_keys = ON")
        let version = try d.int("PRAGMA user_version") ?? 0
        if version > schemaVersion {
            throw HistoryError.newerSchema(version)
        }
        if version < 1 {
            try d.transaction {
                // tracks: one row per distinct song or episode as an export or Spotify names it.
                // listens: one row per play. Times are UTC milliseconds since 1970.
                try d.exec("""
                CREATE TABLE tracks (
                    id INTEGER PRIMARY KEY,
                    kind INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    artist TEXT NOT NULL,
                    album TEXT NOT NULL,
                    uri TEXT NOT NULL,
                    duration_ms INTEGER,
                    artwork_url TEXT,
                    UNIQUE (kind, title, artist, album, uri)
                );
                CREATE TABLE listens (
                    id INTEGER PRIMARY KEY,
                    track_id INTEGER NOT NULL REFERENCES tracks(id),
                    started_at INTEGER NOT NULL,
                    ended_at INTEGER NOT NULL,
                    ms_played INTEGER NOT NULL,
                    source INTEGER NOT NULL,
                    precision INTEGER NOT NULL,
                    skipped INTEGER,
                    shuffle INTEGER,
                    offline INTEGER,
                    incognito INTEGER,
                    reason_start TEXT,
                    reason_end TEXT,
                    dedup_key INTEGER NOT NULL UNIQUE
                );
                CREATE INDEX listens_time ON listens (started_at, ms_played, track_id);
                CREATE INDEX listens_source ON listens (source, ended_at);
                PRAGMA user_version = 1;
                """)
            }
        }
    }

    enum Source: Int64 {
        case live = 0
        case imported = 1
    }

    // MARK: Tracks

    private struct TrackKey: Hashable {
        var kind: Int
        var title: String
        var artist: String
        var album: String
        var uri: String
    }

    private func trackID(_ key: TrackKey, durationMs: Int64?, artworkURL: String?, in d: SQLiteDB,
                         upsert: SQLiteStatement) throws -> Int64 {
        upsert.bind([.int(Int64(key.kind)), .text(key.title), .text(key.artist), .text(key.album), .text(key.uri),
                     .of(durationMs), .of(artworkURL)])
        guard try upsert.step() else { throw SQLiteError.step("no track id") }
        let id = upsert.int(0)
        while try upsert.step() {}
        return id
    }

    private static let trackUpsertSQL = """
    INSERT INTO tracks (kind, title, artist, album, uri, duration_ms, artwork_url) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    ON CONFLICT (kind, title, artist, album, uri) DO UPDATE SET
        duration_ms = COALESCE(excluded.duration_ms, duration_ms),
        artwork_url = COALESCE(excluded.artwork_url, artwork_url)
    RETURNING id
    """

    // MARK: Import

    /// Imports on the calling thread. Use `import(urls:progress:)` from the app.
    func importNow(urls: [URL], progress: ((ImportProgress) -> Void)? = nil) throws -> ImportResult {
        HistoryFiles.removeLeftovers(in: temporaryDirectory, olderThan: Self.leftoverAge)
        let found = try HistoryFiles.collect(urls, temporaryDirectory: temporaryDirectory)
        defer { found.cleanUp() }
        guard !found.files.isEmpty else { throw ImportError.noHistoryFiles }
        let d = try db()
        var result = ImportResult()
        let before = try countNow()
        let changesBefore = d.totalChanges

        try timed("import rows") { try d.transaction {
            var tracks: [TrackKey: Int64] = [:]
            let all = try d.prepare("SELECT id, kind, title, artist, album, uri FROM tracks")
            all.bind([])
            while try all.step() {
                tracks[TrackKey(kind: Int(all.int(1)), title: all.text(2), artist: all.text(3), album: all.text(4),
                                uri: all.text(5))] = all.int(0)
            }
            let upsertTrack = try d.prepare(Self.trackUpsertSQL)
            // A duplicate replaces the stored row only if it is better: a time to the second
            // beats one to the minute, then the earlier end wins. So the result does not
            // depend on the order files are imported in.
            let insert = try d.prepare("""
            INSERT INTO listens (track_id, started_at, ended_at, ms_played, source, precision, skipped, shuffle,
                                 offline, incognito, reason_start, reason_end, dedup_key)
            VALUES (?1, ?2, ?3, ?4, 1, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT (dedup_key) DO UPDATE SET
                track_id = excluded.track_id, started_at = excluded.started_at, ended_at = excluded.ended_at,
                ms_played = excluded.ms_played, source = 1, precision = excluded.precision,
                skipped = excluded.skipped, shuffle = excluded.shuffle, offline = excluded.offline,
                incognito = excluded.incognito, reason_start = excluded.reason_start, reason_end = excluded.reason_end
            WHERE excluded.precision > listens.precision
               OR (excluded.precision = listens.precision AND excluded.ended_at < listens.ended_at)
            """)
            var live = try LiveMatcher(d)

            for (i, file) in found.files.enumerated() {
                // One file's rows at a time. Foundation's JSON objects are autoreleased, and
                // this loop runs on a dispatch queue whose pool drains only when the import
                // is over, so without a pool per file every file would stay in memory.
                let parsed: ExportParser.Parsed? = autoreleasepool {
                    try? ExportParser.parse(Data(contentsOf: file))
                }
                guard let parsed else {
                    result.unreadable.append(file.lastPathComponent)
                    continue
                }
                result.files += 1
                result.rows += parsed.rows
                result.skipped += parsed.skipped
                for r in parsed.records {
                    let key = TrackKey(kind: r.kind.rawValue, title: r.title, artist: r.artist, album: r.album, uri: r.uri)
                    let track: Int64
                    if let known = tracks[key] {
                        track = known
                    } else {
                        track = try trackID(key, durationMs: nil, artworkURL: nil, in: d, upsert: upsertTrack)
                        tracks[key] = track
                    }
                    try insert.run([.int(track), .int(r.startedAt), .int(r.endedAt), .int(r.msPlayed),
                                    .int(Int64(r.precision)), .of(r.skipped), .of(r.shuffle), .of(r.offline),
                                    .of(r.incognito), .of(r.reasonStart), .of(r.reasonEnd), .int(r.dedupKey)])
                    live.claim(r)
                    let start = Date(timeIntervalSince1970: TimeInterval(r.startedAt) / 1000)
                    if result.first.map({ start < $0 }) ?? true { result.first = start }
                    if result.last.map({ start > $0 }) ?? true { result.last = start }
                }
                progress?(ImportProgress(filesDone: i + 1, filesTotal: found.files.count, rowsRead: result.rows))
            }
            result.replacedLive = try live.deleteClaimed(d)
        } }
        if result.files == 0 { throw ImportError.noHistoryFiles }
        catalogCache = nil
        if compactsAfterImport && d.totalChanges != changesBefore {
            do {
                try timed("import compact") { try compactNow() }
            } catch {
                // The listens are in; only the speed of the first read after a launch suffers.
                NSLog("Tonearm: could not compact the history after an import: %@", "\(error)")
            }
        }
        let after = try countNow()
        result.added = after - before + result.replacedLive
        result.duplicates = result.rows - result.skipped - result.added
        return result
    }

    /// Finds listens Tonearm recorded live that an import also has, so they are not
    /// counted twice. A live listen matches an imported row of the same kind and song
    /// (same Spotify URI, or same title and artist) whose play overlaps it in time.
    /// Spotify's numbers win: the live row is deleted.
    ///
    /// Tonearm can split one play into several live rows: when it quits and starts again
    /// mid-song, when recording is turned off and on, or when the song is sought back to
    /// the start. So an imported row takes the live row that overlaps it most, and also
    /// any other that lies mostly inside it, as long as together they did not play longer
    /// than Spotify counted. The length check keeps the next play of the same song (repeat
    /// one) when the export does not have it.
    private struct LiveMatcher {
        struct Live {
            var id: Int64
            var start: Int64
            var end: Int64
            var ms: Int64
            var claimed = false
        }

        /// How much longer than Spotify's count the live pieces of one play may add up to.
        static func tolerance(_ ms: Int64) -> Int64 { 5_000 + ms / 20 }

        private var rows: [Live] = []
        private var byURI: [String: [Int]] = [:]
        private var byName: [String: [Int]] = [:]

        init(_ d: SQLiteDB) throws {
            let s = try d.prepare("""
            SELECT l.id, l.started_at, l.ended_at, t.kind, t.title, t.artist, t.uri, l.ms_played
            FROM listens l JOIN tracks t ON t.id = l.track_id WHERE l.source = 0 ORDER BY l.started_at, l.id
            """)
            s.bind([])
            while try s.step() {
                let i = rows.count
                rows.append(Live(id: s.int(0), start: s.int(1), end: s.int(2), ms: s.int(7)))
                let kind = s.int(3)
                let uri = s.text(6)
                if !uri.isEmpty { byURI["\(kind)\u{1F}\(uri)", default: []].append(i) }
                byName["\(kind)\u{1F}\(s.text(5))\u{1F}\(s.text(4))", default: []].append(i)
            }
        }

        mutating func claim(_ r: ImportRecord) {
            guard !rows.isEmpty, r.msPlayed >= 1000 else { return }
            let slack: Int64 = r.precision == 0 ? 60_000 : 5_000
            let lo = r.startedAt - slack, hi = r.endedAt + slack
            var candidates = byURI["\(r.kind.rawValue)\u{1F}\(r.uri)"] ?? []
            if r.uri.isEmpty || candidates.isEmpty {
                candidates = byName["\(r.kind.rawValue)\u{1F}\(r.artist)\u{1F}\(r.title)"] ?? []
            }
            var hits: [(index: Int, overlap: Int64)] = []
            for i in candidates where !rows[i].claimed {
                let overlap = min(hi, rows[i].end) - max(lo, rows[i].start)
                if overlap > 0 { hits.append((i, overlap)) }
            }
            // Most overlap first; the earlier row on a tie.
            hits.sort { $0.overlap != $1.overlap ? $0.overlap > $1.overlap : $0.index < $1.index }
            guard let best = hits.first else { return }
            rows[best.index].claimed = true
            var played = rows[best.index].ms
            let limit = r.msPlayed + Self.tolerance(r.msPlayed)
            for hit in hits.dropFirst() {
                let row = rows[hit.index]
                let span = max(1, row.end - row.start)
                guard hit.overlap * 2 >= span, played + row.ms <= limit else { continue }
                rows[hit.index].claimed = true
                played += row.ms
            }
        }

        func deleteClaimed(_ d: SQLiteDB) throws -> Int {
            let delete = try d.prepare("DELETE FROM listens WHERE id = ?1 AND source = 0")
            var n = 0
            for row in rows where row.claimed {
                try delete.run([.int(row.id)])
                n += 1
            }
            return n
        }
    }

    // MARK: Live

    func saveNow(_ listen: LiveListen) throws {
        let startMs = Int64((listen.startedAt.timeIntervalSince1970 * 1000).rounded())
        guard startMs >= liveFloor else { return }
        let d = try db()
        let upsertTrack = try d.prepare(Self.trackUpsertSQL)
        let key = TrackKey(kind: listen.kind.rawValue, title: listen.title, artist: listen.artist, album: listen.album,
                           uri: listen.trackID)
        let track = try trackID(key, durationMs: listen.durationMs, artworkURL: listen.artworkURL, in: d,
                                upsert: upsertTrack)
        let endMs = max(startMs, Int64((listen.endedAt.timeIntervalSince1970 * 1000).rounded()))
        try d.run("""
        INSERT INTO listens (track_id, started_at, ended_at, ms_played, source, precision, dedup_key)
        VALUES (?1, ?2, ?3, ?4, 0, 1, ?5)
        ON CONFLICT (dedup_key) DO UPDATE SET track_id = excluded.track_id, ended_at = excluded.ended_at,
            ms_played = excluded.ms_played
        WHERE listens.source = 0
        """, [.int(track), .int(startMs), .int(endMs), .int(listen.msPlayed), .int(listen.dedupKey)])
        // A track the catalog already has keeps its names, so the catalog stays good. Only a
        // new one needs it read again. Saves come often while music plays.
        if let c = catalogCache, track >= 0, Int(track) < c.kind.count, c.kind[Int(track)] >= 0 { return }
        catalogCache = nil
    }

    // MARK: Reads

    func countNow() throws -> Int {
        Int(try db().int("SELECT COUNT(*) FROM listens") ?? 0)
    }

    func playCountNow() throws -> Int {
        // The same rule as StatsEngine: every kind but podcasts (1) is music.
        Int(try db().int("""
        SELECT COUNT(*) FROM listens l JOIN tracks t ON t.id = l.track_id
        WHERE t.kind >= 0 AND t.kind != 1 AND l.ms_played >= ?1
        """, [.int(StatsEngine.listenThresholdMs)]) ?? 0)
    }

    func summaryNow() throws -> HistorySummary {
        // Plays by the same rule as playCountNow.
        let s = try db().prepare("""
        SELECT COUNT(*), MIN(l.started_at), MAX(l.started_at),
               COALESCE(SUM(CASE WHEN t.kind >= 0 AND t.kind != 1 AND l.ms_played >= ?1 THEN 1 ELSE 0 END), 0)
        FROM listens l JOIN tracks t ON t.id = l.track_id
        """)
        s.bind([.int(StatsEngine.listenThresholdMs)])
        guard try s.step() else { return HistorySummary() }
        func date(_ ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }
        let summary = HistorySummary(count: Int(s.int(0)), first: date(s.optionalInt(1)), last: date(s.optionalInt(2)),
                                     plays: Int(s.int(3)))
        while try s.step() {}
        return summary
    }

    func musicPageNow(after cursor: ListenCursor?, before: Int64, limit: Int) throws -> [StoredListen] {
        let s = try db().prepare("""
        SELECT l.id, l.started_at, l.ms_played, t.id, t.title, t.artist, t.album, t.uri, t.duration_ms,
               l.skipped, l.reason_end
        FROM listens l JOIN tracks t ON t.id = l.track_id
        WHERE t.kind = 0 AND l.started_at < ?1 AND (l.started_at > ?2 OR (l.started_at = ?2 AND l.id > ?3))
        ORDER BY l.started_at, l.id LIMIT ?4
        """)
        s.bind([.int(before), .int(cursor?.startedAt ?? .min), .int(cursor?.id ?? .min), .int(Int64(limit))])
        var rows: [StoredListen] = []
        while try s.step() {
            rows.append(StoredListen(id: s.int(0), startedAt: s.int(1), msPlayed: s.int(2), trackID: s.int(3),
                                     title: s.text(4), artist: s.text(5), album: s.text(6), uri: s.text(7),
                                     durationMs: s.optionalInt(8), skipped: s.optionalInt(9).map { $0 != 0 },
                                     reasonEnd: s.optionalText(10)))
        }
        return rows
    }

    func longestPlaysNow() throws -> [Int64: PlayLengths] {
        let s = try db().prepare("""
        SELECT l.track_id, MAX(l.ms_played), MAX(CASE WHEN l.reason_end = 'trackdone' THEN l.ms_played END)
        FROM listens l JOIN tracks t ON t.id = l.track_id
        WHERE t.kind = 0 GROUP BY l.track_id
        """)
        s.bind([])
        var longest: [Int64: PlayLengths] = [:]
        while try s.step() { longest[s.int(0)] = PlayLengths(longest: s.int(1), finished: s.optionalInt(2)) }
        return longest
    }

    func artworkNow() throws -> ArtworkIndex {
        let s = try db().prepare("""
        SELECT title, artist, album, artwork_url FROM tracks
        WHERE kind = 0 AND artwork_url IS NOT NULL AND artwork_url != '' ORDER BY id
        """)
        s.bind([])
        var index = ArtworkIndex()
        while try s.step() {
            index.add(title: s.text(0), artist: s.text(1), album: s.text(2), url: s.text(3))
        }
        return index
    }

    func yearsNow(timeZone: TimeZone) throws -> [Int] {
        let s = try db().prepare("SELECT started_at FROM listens ORDER BY started_at")
        s.bind([])
        var clock = LocalClock(timeZone: timeZone)
        var years: [Int] = []
        var lastDay = Int.min
        while try s.step() {
            let day = clock.day(utcMillis: s.int(0))
            guard day.number != lastDay else { continue }
            lastDay = day.number
            let y = day.year
            if years.last != y { years.append(y) }
        }
        return years
    }

    func statsNow(for period: Period, timeZone: TimeZone) throws -> Stats {
        let d = try timed("stats open") { try db() }
        let catalog = try timed("stats catalog") { try catalogCache ?? StatsEngine.Catalog.load(d) }
        catalogCache = catalog
        // Every listen up to two days past the period, sorted: earlier ones tell which
        // artists are new. The extra days cover any time zone offset.
        var sql = "SELECT started_at, ms_played, track_id FROM listens"
        var values: [SQLValue] = []
        if let days = period.days {
            sql += " WHERE started_at < ?1"
            values.append(.int(Int64(days.upperBound.number + 2) * 86_400_000))
        }
        sql += " ORDER BY started_at"
        let rows = try timed("stats rows") {
            let s = try d.prepare(sql)
            s.bind(values)
            var rows = StatsEngine.Rows()
            while try s.step() {
                rows.append(start: s.int(0), ms: s.int(1), track: s.int(2))
            }
            return rows
        }
        return timed("stats compute") {
            StatsEngine.stats(rows: rows, catalog: catalog, period: period, timeZone: timeZone)
        }
    }

    /// Rewrites the database file in order, each table and index in one run of pages, and
    /// empties the write-ahead log.
    ///
    /// An import writes listens, tracks and three indexes at once, so their pages end up
    /// interleaved across the file. The first stats call after a launch then reads the time
    /// index and the tracks page by page from all over the disk: 300 to 800 ms at 217k
    /// listens on CI, against 40 ms once the pages are cached. In order, the same read is a
    /// few long sequential ones. Live recording appends in time order, so it stays close.
    ///
    /// VACUUM needs free disk space of about twice the file and, in WAL mode, writes the new
    /// copy into the WAL. If it fails half way, say on a full disk, the database stays as it
    /// was, and the WAL is still emptied so that copy doesn't stay on disk.
    func compactNow() throws {
        let d = try db()
        defer { _ = try? d.int("PRAGMA wal_checkpoint(TRUNCATE)") }
        try d.exec("VACUUM")
    }

    // MARK: Export

    static let exportColumns = ["started_at", "ended_at", "ms_played", "kind", "title", "artist", "album",
                                "spotify_uri", "duration_ms", "artwork_url", "source", "skipped", "shuffle",
                                "offline", "incognito", "reason_start", "reason_end"]

    func exportNow(to url: URL, format: ExportFormat) throws -> Int {
        let d = try db()
        let s = try d.prepare("""
        SELECT l.started_at, l.ended_at, l.ms_played, t.kind, t.title, t.artist, t.album, t.uri, t.duration_ms,
               t.artwork_url, l.source, l.skipped, l.shuffle, l.offline, l.incognito, l.reason_start, l.reason_end
        FROM listens l JOIN tracks t ON t.id = l.track_id ORDER BY l.started_at, l.id
        """)
        s.bind([])
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let out = FileHandle(forWritingAtPath: url.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { try? out.close() }
        var buffer = ""
        func flush(force: Bool = false) {
            if force || buffer.utf8.count > 1 << 16 {
                out.write(Data(buffer.utf8))
                buffer = ""
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func time(_ ms: Int64) -> String { iso.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000)) }
        func flag(_ v: Int64?) -> Bool? { v.map { $0 != 0 } }

        var n = 0
        switch format {
        case .csv:
            buffer += Self.exportColumns.joined(separator: ",") + "\n"
        case .json:
            buffer += "[\n"
        }
        while try s.step() {
            let kind = s.int(3) == 1 ? "podcast" : "music"
            let source = s.int(10) == 0 ? "live" : "import"
            let fields: [Any?] = [time(s.int(0)), time(s.int(1)), s.int(2), kind, s.text(4), s.text(5), s.text(6),
                                  s.optionalText(7).flatMap { $0.isEmpty ? nil : $0 }, s.optionalInt(8),
                                  s.optionalText(9), source, flag(s.optionalInt(11)), flag(s.optionalInt(12)),
                                  flag(s.optionalInt(13)), flag(s.optionalInt(14)), s.optionalText(15),
                                  s.optionalText(16)]
            switch format {
            case .csv:
                buffer += fields.map(Self.csvField).joined(separator: ",") + "\n"
            case .json:
                var object: [String: Any] = [:]
                for (key, value) in zip(Self.exportColumns, fields) { object[key] = value ?? NSNull() }
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                buffer += (n == 0 ? "" : ",\n") + String(decoding: data, as: UTF8.self)
            }
            n += 1
            flush()
        }
        if format == .json { buffer += "\n]\n" }
        flush(force: true)
        return n
    }

    /// One CSV field. Text that starts like a formula (=, +, -, @, tab or return) gets a
    /// leading ' so Excel and Numbers show it rather than run it; song titles come from
    /// Spotify and from imported files, so they can start with anything.
    static func csvField(_ value: Any?) -> String {
        guard let value else { return "" }
        var s: String
        if let b = value as? Bool {
            s = b ? "true" : "false"
        } else if let text = value as? String {
            s = text
            if let first = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { s = "'" + s }
        } else {
            s = "\(value)"
        }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Delete

    /// Deletes every listen and leaves no copy of them on disk. SQLite keeps old pages in
    /// the main file until a vacuum and in history.sqlite-wal until a checkpoint, and it
    /// reuses the WAL rather than shrinking it. So: zero freed pages, rebuild the file, copy
    /// the WAL back and cut it to zero bytes. Then the kept covers go too.
    func deleteAllNow() throws {
        let d = try db()
        try d.exec("PRAGMA secure_delete = ON")
        try d.transaction {
            try d.exec("DELETE FROM listens; DELETE FROM tracks;")
        }
        catalogCache = nil
        liveFloor = Int64((Date().timeIntervalSince1970 * 1000).rounded(.up))
        try d.exec("VACUUM")
        // The first column is 1 if another connection kept the checkpoint from finishing.
        guard try d.int("PRAGMA wal_checkpoint(TRUNCATE)") == 0 else {
            throw SQLiteError.step("could not clear history.sqlite-wal; the database is busy")
        }
        try covers.deleteAllNow()
        // Unpacked exports from an import that was cut off hold the same listens.
        HistoryFiles.removeLeftovers(in: temporaryDirectory, olderThan: 0)
    }
}

/// Cover URLs by artist, song and album, keyed like `Stats.Item.id`: the artist's name, or
/// "title<US>artist" and "album<US>artist". The newest track with a cover wins.
struct ArtworkIndex: Equatable {
    var artists: [String: String] = [:]
    var songs: [String: String] = [:]
    var albums: [String: String] = [:]

    mutating func add(title: String, artist: String, album: String, url: String) {
        if !artist.isEmpty { artists[artist] = url }
        if !title.isEmpty { songs["\(title)\u{1F}\(artist)"] = url }
        if !album.isEmpty { albums["\(album)\u{1F}\(artist)"] = url }
    }
}
