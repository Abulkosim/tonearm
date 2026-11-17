import Foundation

/// Computes `Stats` from listens in one pass. Pure: the store hands it rows and the
/// track catalog. Strings are grouped once per catalog, so the pass only touches integers.
enum StatsEngine {
    /// A play counts as a listen at 30 s, Spotify's own stream threshold.
    static let listenThresholdMs: Int64 = 30_000
    static let topCount = 10
    static let topShowsCount = 5

    /// Listens sorted by start time.
    struct Rows {
        var start: [Int64] = []
        var ms: [Int64] = []
        var track: [Int32] = []

        mutating func append(start s: Int64, ms m: Int64, track t: Int64) {
            start.append(s)
            ms.append(m)
            track.append(Int32(truncatingIfNeeded: t))
        }

        var count: Int { start.count }
    }

    /// Every track, indexed by its database id, with its names grouped into integers.
    struct Catalog {
        /// By track id: 0 music, 1 podcast, -1 no such track.
        var kind: [Int8] = []
        /// By track id: the artist (or show), song (title + artist) and album (album + artist)
        /// group, or -1 when that name is empty.
        var artist: [Int32] = []
        var song: [Int32] = []
        var album: [Int32] = []
        var artistNames: [String] = []
        var songNames: [(title: String, artist: String)] = []
        var albumNames: [(title: String, artist: String)] = []

        static func load(_ d: SQLiteDB) throws -> Catalog {
            var c = Catalog()
            let maxID = Int(try d.int("SELECT COALESCE(MAX(id), 0) FROM tracks") ?? 0)
            c.kind = Array(repeating: -1, count: maxID + 1)
            c.artist = Array(repeating: -1, count: maxID + 1)
            c.song = c.artist
            c.album = c.artist
            let s = try d.prepare("SELECT id, kind, title, artist, album FROM tracks")
            s.bind([])
            var artists: [String: Int32] = [:]
            var songs: [String: Int32] = [:]
            var albums: [String: Int32] = [:]
            while try s.step() {
                let id = Int(s.int(0))
                guard id >= 0, id <= maxID else { continue }
                let kind = Int8(truncatingIfNeeded: s.int(1))
                let title = s.text(2), artist = s.text(3), album = s.text(4)
                c.kind[id] = kind
                // Shows and music artists live in different groups, even with the same name.
                if !artist.isEmpty {
                    let key = "\(kind)\u{1F}\(artist)"
                    if let g = artists[key] {
                        c.artist[id] = g
                    } else {
                        let g = Int32(c.artistNames.count)
                        artists[key] = g
                        c.artistNames.append(artist)
                        c.artist[id] = g
                    }
                }
                if !title.isEmpty {
                    let key = "\(kind)\u{1F}\(title)\u{1F}\(artist)"
                    if let g = songs[key] {
                        c.song[id] = g
                    } else {
                        let g = Int32(c.songNames.count)
                        songs[key] = g
                        c.songNames.append((title, artist))
                        c.song[id] = g
                    }
                }
                if !album.isEmpty {
                    let key = "\(kind)\u{1F}\(album)\u{1F}\(artist)"
                    if let g = albums[key] {
                        c.album[id] = g
                    } else {
                        let g = Int32(c.albumNames.count)
                        albums[key] = g
                        c.albumNames.append((album, artist))
                        c.album[id] = g
                    }
                }
            }
            return c
        }
    }

    private struct Tally {
        var ms: [Int64]
        var listens: [Int32]
        var seen: [Bool]
        var touched: [Int32] = []

        init(count: Int) {
            ms = Array(repeating: 0, count: count)
            listens = Array(repeating: 0, count: count)
            seen = Array(repeating: false, count: count)
        }

        mutating func add(_ g: Int32, ms m: Int64, listen: Bool) {
            let i = Int(g)
            if !seen[i] {
                seen[i] = true
                touched.append(g)
            }
            ms[i] += m
            if listen { listens[i] += 1 }
        }

        /// Groups with at least one listen of 30 s or more.
        var uniqueListened: Int { touched.reduce(0) { $0 + (listens[Int($1)] > 0 ? 1 : 0) } }

        /// Top `n` by ms, then listens, then name. Groups with no time are left out.
        func top(_ n: Int, where include: (Int32) -> Bool = { _ in true },
                 name: (Int32) -> (String, String?)) -> [Stats.Item] {
            let ranked = touched.filter { ms[Int($0)] > 0 && include($0) }.sorted { a, b in
                let ma = ms[Int(a)], mb = ms[Int(b)]
                if ma != mb { return ma > mb }
                let la = listens[Int(a)], lb = listens[Int(b)]
                if la != lb { return la > lb }
                let (na, aa) = name(a), (nb, ab) = name(b)
                if na != nb { return StatsEngine.precedes(na, nb) }
                return StatsEngine.precedes(aa ?? "", ab ?? "")
            }
            return ranked.prefix(n).map { g in
                let (title, artist) = name(g)
                return Stats.Item(name: title, artist: artist, ms: ms[Int(g)], listens: Int(listens[Int(g)]))
            }
        }
    }

    /// Code point order, the same as Python's, so the twin agrees on ties.
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }

    static func stats(rows: Rows, catalog c: Catalog, period: Period, timeZone: TimeZone) -> Stats {
        var out = Stats(period: period.description)
        let range = period.days
        out.start = range?.lowerBound
        out.end = range?.upperBound
        let lo = range?.lowerBound.number ?? Int.min
        let hi = range?.upperBound.number ?? Int.max

        var artists = Tally(count: c.artistNames.count)
        var songs = Tally(count: c.songNames.count)
        var albums = Tally(count: c.albumNames.count)
        var shows = Tally(count: c.artistNames.count)
        var firstHeard = [Int](repeating: Int.max, count: c.artistNames.count)
        var dailyMs: [Int: Int64] = [:]
        var listenDays = Set<Int>()
        var firstMusicDay = Int.max, lastMusicDay = Int.min
        var clock = LocalClock(timeZone: timeZone)

        for i in 0..<rows.count {
            let t = Int(rows.track[i])
            guard t >= 0, t < c.kind.count else { continue }
            let kind = c.kind[t]
            guard kind >= 0 else { continue }
            let ms = rows.ms[i]
            let listen = ms >= listenThresholdMs
            let local = clock.localSeconds(utcMillis: rows.start[i])
            let day = Civil.floorDiv(local, 86_400)
            let a = c.artist[t]
            // The minimum, not the first seen: rows are sorted by UTC time, and a clock
            // change at midnight can put a later row on an earlier local day.
            if kind == 0, listen, a >= 0, day < firstHeard[Int(a)] { firstHeard[Int(a)] = day }
            guard day >= lo, day < hi else { continue }

            if kind == 1 {
                out.podcasts.ms += ms
                if listen { out.podcasts.listens += 1 }
                if a >= 0 { shows.add(a, ms: ms, listen: listen) }
                continue
            }
            out.music.ms += ms
            if listen {
                out.music.listens += 1
                listenDays.insert(day)
            }
            if a >= 0 { artists.add(a, ms: ms, listen: listen) }
            let s = c.song[t]
            if s >= 0 { songs.add(s, ms: ms, listen: listen) }
            let al = c.album[t]
            if al >= 0 { albums.add(al, ms: ms, listen: listen) }
            dailyMs[day, default: 0] += ms
            firstMusicDay = min(firstMusicDay, day)
            lastMusicDay = max(lastMusicDay, day)
            let hour = (local - day * 86_400) / 3600
            out.music.heatmap[Civil.floorMod(day + 3, 7)][hour] += ms
        }

        let artistName: (Int32) -> (String, String?) = { (c.artistNames[Int($0)], nil) }
        out.music.uniqueArtists = artists.uniqueListened
        out.music.uniqueTracks = songs.uniqueListened
        out.music.uniqueAlbums = albums.uniqueListened
        out.music.topArtists = artists.top(topCount, name: artistName)
        out.music.topTracks = songs.top(topCount) { (c.songNames[Int($0)].title, c.songNames[Int($0)].artist) }
        out.music.topAlbums = albums.top(topCount) { (c.albumNames[Int($0)].title, c.albumNames[Int($0)].artist) }
        out.podcasts.shows = shows.uniqueListened
        out.podcasts.topShows = shows.top(topShowsCount, name: artistName)

        // New artists: first heard in the period, ranked like top artists.
        let isNew: (Int32) -> Bool = { firstHeard[Int($0)] >= lo && firstHeard[Int($0)] < hi }
        out.music.newArtists.count = artists.touched.reduce(0) { $0 + (isNew($1) ? 1 : 0) }
        out.music.newArtists.top = artists.top(topCount, where: isNew, name: artistName)

        // Days: the whole period, or first to last day with music for all time.
        let first = range?.lowerBound.number ?? firstMusicDay
        let last = range.map { $0.upperBound.number - 1 } ?? lastMusicDay
        if first <= last {
            out.music.daily = (first...last).map { Stats.DayTotal(day: LocalDay(number: $0), ms: dailyMs[$0] ?? 0) }
        }
        var busiest: Stats.DayTotal?
        for (day, ms) in dailyMs where ms > 0 {
            if let b = busiest, b.ms > ms || (b.ms == ms && b.day.number < day) { continue }
            busiest = Stats.DayTotal(day: LocalDay(number: day), ms: ms)
        }
        out.music.busiestDay = busiest
        out.music.longestStreak = longestStreak(listenDays)
        return out
    }

    /// The longest run of consecutive days; the earliest wins a tie.
    static func longestStreak(_ days: Set<Int>) -> Stats.Streak? {
        var best: Stats.Streak?
        for day in days.sorted() where !days.contains(day - 1) {
            var end = day
            while days.contains(end + 1) { end += 1 }
            let length = end - day + 1
            if length > (best?.days ?? 0) || (length == best?.days && day < best!.start.number) {
                best = Stats.Streak(days: length, start: LocalDay(number: day), end: LocalDay(number: end))
            }
        }
        return best
    }
}
