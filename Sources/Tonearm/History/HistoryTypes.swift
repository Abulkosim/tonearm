import Foundation

/// What was played. Ads are never stored; audiobooks and empty rows are skipped on import.
enum ListenKind: Int, Codable {
    case music = 0
    case podcast = 1

    /// Live tracks: "spotify:episode:..." is a podcast episode, anything else is music.
    static func of(spotifyID id: String) -> ListenKind {
        id.hasPrefix("spotify:episode:") ? .podcast : .music
    }
}

/// A listen Tonearm heard itself, open or closed.
struct LiveListen: Equatable {
    var trackID: String
    var kind: ListenKind
    var title: String
    var artist: String
    var album: String
    var artworkURL: String?
    var durationMs: Int64?
    var startedAt: Date
    /// The end of the last stretch of time credited to it.
    var endedAt: Date
    var msPlayed: Int64

    /// Stays the same while the listen is open, so saving it again updates the same row.
    var dedupKey: Int64 {
        let start = Int64((startedAt.timeIntervalSince1970 * 1000).rounded())
        return FNV.hash("live\u{1F}\(start)\u{1F}\(trackID)")
    }
}

/// A calendar day in some time zone, counted in days since 1970-01-01. Pure arithmetic
/// (proleptic Gregorian), so it is fast and the same on every Mac. Encodes as "yyyy-MM-dd".
struct LocalDay: Hashable, Comparable, Codable, CustomStringConvertible {
    let number: Int

    init(number: Int) { self.number = number }

    init(year: Int, month: Int, day: Int) {
        number = Civil.days(year: year, month: month, day: day)
    }

    /// The day `date` falls on in `timeZone`.
    init(_ date: Date, timeZone: TimeZone) {
        let seconds = Int(floor(date.timeIntervalSince1970)) + timeZone.secondsFromGMT(for: date)
        number = Civil.floorDiv(seconds, 86_400)
    }

    var year: Int { Civil.date(days: number).year }
    var month: Int { Civil.date(days: number).month }
    var day: Int { Civil.date(days: number).day }
    /// 0 is Monday, 6 is Sunday.
    var weekday: Int { Civil.floorMod(number + 3, 7) }

    func adding(days: Int) -> LocalDay { LocalDay(number: number + days) }

    /// Local midnight of this day in `timeZone`, for charts. A midnight skipped by a clock
    /// change gives the first moment of the day.
    func date(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = Civil.date(days: number)
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? Date(
            timeIntervalSince1970: TimeInterval(number) * 86_400)
    }

    var description: String {
        let c = Civil.date(days: number)
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    /// Parses "yyyy-MM-dd".
    init?(string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    static func < (a: LocalDay, b: LocalDay) -> Bool { a.number < b.number }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let day = LocalDay(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad day \(s)"))
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Days from civil dates and back (Howard Hinnant's algorithms).
enum Civil {
    static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
    static func floorMod(_ a: Int, _ b: Int) -> Int { a - floorDiv(a, b) * b }

    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func date(days z: Int) -> (year: Int, month: Int, day: Int) {
        let z = z + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

/// Turns UTC milliseconds into local seconds quickly, for rows sorted by time. It looks
/// the offset up once and keeps it until the zone's next clock change.
struct LocalClock {
    let timeZone: TimeZone
    private var offset = 0
    private var validFrom = Int64.max
    private var validUntil = Int64.min

    init(timeZone: TimeZone) { self.timeZone = timeZone }

    /// Seconds since 1970-01-01 00:00 local time.
    mutating func localSeconds(utcMillis ms: Int64) -> Int {
        if ms < validFrom || ms >= validUntil {
            let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            offset = timeZone.secondsFromGMT(for: date)
            validFrom = ms
            if let next = timeZone.nextDaylightSavingTimeTransition(after: date) {
                validUntil = Int64((next.timeIntervalSince1970 * 1000).rounded(.down))
                if validUntil <= ms { validUntil = ms + 1 }
            } else {
                validUntil = .max
            }
        }
        return Civil.floorDiv(Int(ms), 1000) + offset
    }

    mutating func day(utcMillis ms: Int64) -> LocalDay {
        LocalDay(number: Civil.floorDiv(localSeconds(utcMillis: ms), 86_400))
    }
}

/// A span of listening to summarize, in the user's time zone.
enum Period: Hashable, CustomStringConvertible {
    /// The Monday-to-Sunday week that contains this day.
    case week(LocalDay)
    case month(year: Int, month: Int)
    case year(Int)
    case allTime

    enum Kind: String, CaseIterable { case week, month, year, allTime }

    /// The period of `kind` that contains `now`.
    static func current(_ kind: Kind, now: Date = Date(), timeZone: TimeZone = .current) -> Period {
        let day = LocalDay(now, timeZone: timeZone)
        switch kind {
        case .week: return .week(day)
        case .month: return .month(year: day.year, month: day.month)
        case .year: return .year(day.year)
        case .allTime: return .allTime
        }
    }

    /// The period Liner Notes opens on: the one of `kind` holding today when this year has
    /// listens, else the one at the end of the latest year that does.
    static func opening(_ kind: Kind, years: [Int], now: Date = Date(), timeZone: TimeZone = .current) -> Period {
        let current = Period.current(kind, now: now, timeZone: timeZone)
        guard let last = years.last, !years.contains(LocalDay(now, timeZone: timeZone).year) else { return current }
        return Period.of(kind, containing: LocalDay(year: last, month: 12, day: 31))
    }

    /// The days covered, end exclusive. Nil for all time.
    var days: Range<LocalDay>? {
        switch self {
        case .week(let d):
            let monday = d.adding(days: -d.weekday)
            return monday..<monday.adding(days: 7)
        case .month(let y, let m):
            let start = LocalDay(year: y, month: m, day: 1)
            let end = m == 12 ? LocalDay(year: y + 1, month: 1, day: 1) : LocalDay(year: y, month: m + 1, day: 1)
            return start..<end
        case .year(let y):
            return LocalDay(year: y, month: 1, day: 1)..<LocalDay(year: y + 1, month: 1, day: 1)
        case .allTime:
            return nil
        }
    }

    /// The period before this one. All time has none.
    var previous: Period? {
        switch self {
        case .week(let d): return .week(d.adding(days: -7))
        case .month(let y, let m): return m == 1 ? .month(year: y - 1, month: 12) : .month(year: y, month: m - 1)
        case .year(let y): return .year(y - 1)
        case .allTime: return nil
        }
    }

    /// "week:2024-03-11" (the Monday), "month:2024-03", "year:2024", "all".
    var description: String {
        switch self {
        case .week: return "week:\(days!.lowerBound)"
        case .month(let y, let m): return String(format: "month:%04d-%02d", y, m)
        case .year(let y): return "year:\(y)"
        case .allTime: return "all"
        }
    }

    /// Parses `description`. A week may name any of its days.
    init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "all" || s == "alltime" { self = .allTime; return }
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "week":
            guard let d = LocalDay(string: parts[1]) else { return nil }
            self = .week(d)
        case "month":
            let ym = parts[1].split(separator: "-")
            guard ym.count == 2, let y = Int(ym[0]), let m = Int(ym[1]), (1...12).contains(m) else { return nil }
            self = .month(year: y, month: m)
        case "year":
            guard let y = Int(parts[1]) else { return nil }
            self = .year(y)
        default:
            return nil
        }
    }

    static func == (a: Period, b: Period) -> Bool { a.description == b.description }
    func hash(into hasher: inout Hasher) { hasher.combine(description) }
}

/// What an import did. Every row read is added, a duplicate, or skipped.
struct ImportResult: Codable, Equatable {
    /// Streaming history files read.
    var files = 0
    /// Rows in those files.
    var rows = 0
    /// New listens stored.
    var added = 0
    /// Rows already stored: the same export twice, overlapping files, or both export kinds.
    var duplicates = 0
    /// Rows with nothing to show (no song or episode name), audiobooks and ads.
    var skipped = 0
    /// Listens Tonearm recorded itself that the export also has; the export's copy replaced them.
    var replacedLive = 0
    /// Files that were not valid streaming history JSON.
    var unreadable: [String] = []
    /// The earliest and latest listen in the files, if any.
    var first: Date?
    var last: Date?
}

struct ImportProgress {
    var filesDone: Int
    var filesTotal: Int
    var rowsRead: Int
}

enum ImportError: Error, CustomStringConvertible {
    /// No StreamingHistory*.json, Streaming_History_*.json or endsong*.json was found.
    case noHistoryFiles
    case unzipFailed(String)

    var description: String {
        switch self {
        case .noHistoryFiles:
            return "No listening history found. Choose the folder or .zip Spotify sent, or its StreamingHistory files."
        case .unzipFailed(let name): return "Could not open \(name)."
        }
    }
}

enum ExportFormat: String, CaseIterable {
    case csv, json
}

/// Listening for one period. Music and podcasts are counted apart; everything at the top
/// level is music. Milliseconds are exact; use `minutes` to show them.
///
/// Definitions (scripts/history-twin.py implements the same ones):
/// - A listen is placed at its start time, in the time zone the stats were made for.
/// - `listens` counts plays of 30 s or more (Spotify's own stream threshold). Minutes count
///   every millisecond, short plays included.
/// - Unique tracks, artists and albums count only plays of 30 s or more.
/// - Top lists rank by milliseconds, then listens, then name. Tracks are title + artist,
///   albums are album + artist, so the same title by two artists is two tracks.
/// - `newArtists`: artists whose first play of 30 s or more, ever, falls in the period.
/// - `daily` has every day of the period (for all time, first to last day with music).
/// - `heatmap[weekday][hour]`, Monday first, local hour of the start.
/// - `longestStreak`: most consecutive days in the period with a play of 30 s or more.
struct Stats: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var name: String
        /// For tracks and albums.
        var artist: String?
        var ms: Int64
        var listens: Int

        var id: String { "\(name)\u{1F}\(artist ?? "")" }
        var minutes: Double { Double(ms) / 60_000 }
    }

    struct DayTotal: Codable, Equatable {
        var day: LocalDay
        var ms: Int64
        var minutes: Double { Double(ms) / 60_000 }
    }

    struct Streak: Codable, Equatable {
        var days: Int
        var start: LocalDay
        var end: LocalDay
    }

    struct NewArtists: Codable, Equatable {
        var count = 0
        var top: [Item] = []
    }

    struct Music: Codable, Equatable {
        var ms: Int64 = 0
        var listens = 0
        var uniqueTracks = 0
        var uniqueArtists = 0
        var uniqueAlbums = 0
        var topArtists: [Item] = []
        var topTracks: [Item] = []
        var topAlbums: [Item] = []
        var daily: [DayTotal] = []
        /// 7 rows (Monday first) of 24 hours, in milliseconds.
        var heatmap: [[Int64]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var longestStreak: Streak?
        var busiestDay: DayTotal?
        var newArtists = NewArtists()

        var minutes: Double { Double(ms) / 60_000 }
    }

    struct Podcasts: Codable, Equatable {
        var ms: Int64 = 0
        var listens = 0
        var shows = 0
        var topShows: [Item] = []

        var minutes: Double { Double(ms) / 60_000 }
    }

    var period: String
    /// First day and the day after the last; nil for all time.
    var start: LocalDay?
    var end: LocalDay?
    var music = Music()
    var podcasts = Podcasts()

    var isEmpty: Bool { music.ms == 0 && podcasts.ms == 0 && music.listens == 0 && podcasts.listens == 0 }
}

/// How much history there is. `first` and `last` are start times; nil when it is empty.
struct HistorySummary: Equatable {
    /// Every stored entry: plays, short plays and podcast episodes.
    var count = 0
    var first: Date?
    var last: Date?
    /// Music played 30 s or more: what Liner Notes calls plays.
    var plays = 0
}

/// A place in the listens, oldest first: the start time and row id of the last one read.
struct ListenCursor: Codable, Equatable {
    var startedAt: Int64
    var id: Int64
}

/// A stored music listen, for sending to ListenBrainz. Times are UTC milliseconds.
struct StoredListen: Equatable {
    var id: Int64
    var startedAt: Int64
    var msPlayed: Int64
    var trackID: Int64
    var title: String
    var artist: String
    var album: String
    var uri: String
    var durationMs: Int64?
    /// From an extended export: whether the user skipped to the next song, and why the play
    /// ended ("trackdone" when the song played to its end). Nil for live and account data.
    var skipped: Bool? = nil
    var reasonEnd: String? = nil

    var cursor: ListenCursor { ListenCursor(startedAt: startedAt, id: id) }
}

/// What the history knows of a track's length from its plays, for exports that have no
/// lengths: the longest play, and the longest one that ran to the end of the song.
struct PlayLengths: Equatable {
    var longest: Int64
    var finished: Int64?
}
