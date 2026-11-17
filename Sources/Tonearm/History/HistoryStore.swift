import Foundation

/// Every listen, kept on this Mac in SQLite. Nothing here talks to the network.
///
/// The API for the rest of the app (all calls are safe from any thread; async ones run on
/// the store's own queue):
///
///     let store = HistoryStore.shared
///     let result = try await store.import(urls: picked) { p in ... }   // a folder, .zip or .json files
///     let stats = await store.stats(for: .current(.year))              // or .year(2023), .allTime, ...
///     let years = await store.years()                                  // years that have listens
///     let n = await store.count()
///     let written = try await store.export(to: url, format: .csv)
///     try await store.deleteAll()
///
/// `PlayRecorder` adds what Tonearm hears live (`save(_:)`). Stats definitions are on `Stats`.
/// The database is ~/Library/Application Support/Tonearm/history.sqlite.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore(url: HistoryStore.defaultURL)

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Tonearm", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    static let schemaVersion: Int64 = 1

    let url: URL
    private let queue = DispatchQueue(label: "io.github.abulkosim.tonearm.history", qos: .utility)
    /// Opened on first use, on `queue`.
    private var database: SQLiteDB?
    private var openError: Error?
    /// Live listens that started before this (UTC ms) are dropped: they were deleted.
    private var liveFloor: Int64 = .min
    private var catalogCache: StatsEngine.Catalog?

    init(url: URL) {
        self.url = url
    }

    // MARK: Public API

    func `import`(urls: [URL], progress: ((ImportProgress) -> Void)? = nil) async throws -> ImportResult {
        try await onQueueThrowing { try self.importNow(urls: urls, progress: progress) }
    }

    /// Stats for `period` in `timeZone`. Empty stats if the database can't be read.
    func stats(for period: Period, timeZone: TimeZone = .current) async -> Stats {
        await onQueue { (try? self.statsNow(for: period, timeZone: timeZone)) ?? Stats(period: period.description) }
    }

    /// Years with at least one listen, oldest first, in `timeZone`.
    func years(timeZone: TimeZone = .current) async -> [Int] {
        await onQueue { (try? self.yearsNow(timeZone: timeZone)) ?? [] }
    }

    func count() async -> Int {
        await onQueue { (try? self.countNow()) ?? 0 }
    }

    /// Writes every listen to `url`. Returns how many.
    @discardableResult
    func export(to url: URL, format: ExportFormat) async throws -> Int {
        try await onQueueThrowing { try self.exportNow(to: url, format: format) }
    }

    func deleteAll() async throws {
        try await onQueueThrowing { try self.deleteAllNow() }
    }

    // MARK: Live recording

    /// Stores or updates a listen Tonearm heard. Writes are queued in order.
    func save(_ listen: LiveListen) {
        queue.async { try? self.saveNow(listen) }
    }

    /// Waits for queued writes. Call before the app quits.
    func flush() {
        queue.sync {}
    }

    // MARK: Queue

    private func onQueue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: body()) }
        }
    }

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

    private func db() throws -> SQLiteDB {
        if let database { return database }
        if let openError { throw openError }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let d = try SQLiteDB(path: url.path)
            try Self.migrate(d)
            database = d
            return d
        } catch {
            openError = error
            throw error
        }
    }

    static func migrate(_ d: SQLiteDB) throws {
        try d.exec("PRAGMA journal_mode = WAL")
        try d.exec("PRAGMA synchronous = NORMAL")
        try d.exec("PRAGMA foreign_keys = ON")
        let version = try d.int("PRAGMA user_version") ?? 0
        if version > schemaVersion {
            throw SQLiteError.open("history.sqlite is from a newer Tonearm (schema \(version))")
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
        let found = try HistoryFiles.collect(urls)
        defer { found.cleanUp() }
        guard !found.files.isEmpty else { throw ImportError.noHistoryFiles }
        let d = try db()
        var result = ImportResult()
        let before = try countNow()

        try d.transaction {
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
                let parsed: ExportParser.Parsed
                do {
                    parsed = try ExportParser.parse(Data(contentsOf: file))
                } catch {
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
        }
        if result.files == 0 { throw ImportError.noHistoryFiles }
        catalogCache = nil
        let after = try countNow()
        result.added = after - before + result.replacedLive
        result.duplicates = result.rows - result.skipped - result.added
        return result
    }

    /// Finds listens Tonearm recorded live that an import also has, so they are not
    /// counted twice. A live listen matches an imported row of the same kind and song
    /// (same Spotify URI, or same title and artist) whose play overlaps it in time.
    /// Spotify's numbers win: the live row is deleted.
    private struct LiveMatcher {
        struct Live {
            var id: Int64
            var start: Int64
            var end: Int64
            var claimed = false
        }

        private var rows: [Live] = []
        private var byURI: [String: [Int]] = [:]
        private var byName: [String: [Int]] = [:]

        init(_ d: SQLiteDB) throws {
            let s = try d.prepare("""
            SELECT l.id, l.started_at, l.ended_at, t.kind, t.title, t.artist, t.uri
            FROM listens l JOIN tracks t ON t.id = l.track_id WHERE l.source = 0
            """)
            s.bind([])
            while try s.step() {
                let i = rows.count
                rows.append(Live(id: s.int(0), start: s.int(1), end: s.int(2)))
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
            var best: (index: Int, overlap: Int64)?
            for i in candidates where !rows[i].claimed {
                let overlap = min(hi, rows[i].end) - max(lo, rows[i].start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (i, overlap) }
            }
            if let best { rows[best.index].claimed = true }
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
        catalogCache = nil
    }

    // MARK: Reads

    func countNow() throws -> Int {
        Int(try db().int("SELECT COUNT(*) FROM listens") ?? 0)
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
        let d = try db()
        let catalog = try catalogCache ?? StatsEngine.Catalog.load(d)
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
        let s = try d.prepare(sql)
        s.bind(values)
        var rows = StatsEngine.Rows()
        while try s.step() {
            rows.append(start: s.int(0), ms: s.int(1), track: s.int(2))
        }
        return StatsEngine.stats(rows: rows, catalog: catalog, period: period, timeZone: timeZone)
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

    static func csvField(_ value: Any?) -> String {
        guard let value else { return "" }
        let s: String
        if let b = value as? Bool {
            s = b ? "true" : "false"
        } else {
            s = "\(value)"
        }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Delete

    func deleteAllNow() throws {
        let d = try db()
        try d.transaction {
            try d.exec("DELETE FROM listens; DELETE FROM tracks;")
        }
        try? d.exec("VACUUM")
        catalogCache = nil
        liveFloor = Int64((Date().timeIntervalSince1970 * 1000).rounded(.up))
    }
}
