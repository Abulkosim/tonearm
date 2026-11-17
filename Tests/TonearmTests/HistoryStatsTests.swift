import XCTest
@testable import Tonearm

/// Stats on a small history worked out by hand.
final class HistoryStatsTests: XCTestCase {
    private var dir: URL!
    private var store: HistoryStore!
    private let utc = TimeZone(identifier: "UTC")!
    private let tashkent = TimeZone(identifier: "Asia/Tashkent")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Account data: start = end - msPlayed.
        try Data("""
        [{"endTime": "2024-01-01 10:05", "artistName": "A", "trackName": "One", "msPlayed": 300000},
         {"endTime": "2024-01-02 10:05", "artistName": "A", "trackName": "One", "msPlayed": 300000},
         {"endTime": "2024-01-02 11:01", "artistName": "B", "trackName": "Two", "msPlayed": 20000},
         {"endTime": "2024-01-03 09:02", "artistName": "C", "trackName": "One", "msPlayed": 120000},
         {"endTime": "2024-01-05 09:02", "artistName": "B", "trackName": "Two", "msPlayed": 60000},
         {"endTime": "2023-12-31 23:50", "artistName": "A", "trackName": "One", "msPlayed": 60000}]
        """.utf8).write(to: dir.appendingPathComponent("StreamingHistory_music_0.json"))
        try Data("""
        [{"endTime": "2024-01-01 12:00", "podcastName": "Show", "episodeName": "Ep", "msPlayed": 3600000}]
        """.utf8).write(to: dir.appendingPathComponent("StreamingHistory_podcast_0.json"))
        store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
        _ = try store.sync { try $0.importNow(urls: [dir]) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func stats(_ p: Period, _ tz: TimeZone) throws -> Stats {
        try store.sync { try $0.statsNow(for: p, timeZone: tz) }
    }

    func testPlayCountIsAllTimePlays() throws {
        // The import screen says how many plays it added with this; the page says Plays.
        let plays = try store.sync { try $0.playCountNow() }
        XCTAssertEqual(plays, 5, "music of 30 s or more: not the 20 s play, not the podcast")
        XCTAssertEqual(plays, try stats(.allTime, utc).music.listens)
        XCTAssertEqual(try store.sync { try $0.countNow() }, 7)
    }

    func testYearInUTC() throws {
        let s = try stats(.year(2024), utc)
        XCTAssertEqual(s.period, "year:2024")
        XCTAssertEqual(s.start, LocalDay(year: 2024, month: 1, day: 1))
        XCTAssertEqual(s.end, LocalDay(year: 2025, month: 1, day: 1))
        XCTAssertEqual(s.music.ms, 800_000, "short plays count toward minutes")
        XCTAssertEqual(s.music.listens, 4, "but not as listens")
        XCTAssertEqual(s.music.uniqueTracks, 3, "One by A and One by C are two tracks")
        XCTAssertEqual(s.music.uniqueArtists, 3)
        XCTAssertEqual(s.music.uniqueAlbums, 0)
        XCTAssertEqual(s.music.topArtists.map(\.name), ["A", "C", "B"])
        XCTAssertEqual(s.music.topArtists.map(\.ms), [600_000, 120_000, 80_000])
        XCTAssertEqual(s.music.topArtists.map(\.listens), [2, 1, 1])
        XCTAssertNil(s.music.topArtists[0].artist)
        XCTAssertEqual(s.music.topTracks.map { "\($0.name)/\($0.artist ?? "")" }, ["One/A", "One/C", "Two/B"])
        XCTAssertEqual(s.music.newArtists.count, 2, "A was first heard in 2023")
        XCTAssertEqual(s.music.newArtists.top.map(\.name), ["C", "B"])
        XCTAssertEqual(s.music.longestStreak, Stats.Streak(days: 3, start: LocalDay(year: 2024, month: 1, day: 1),
                                                           end: LocalDay(year: 2024, month: 1, day: 3)))
        XCTAssertEqual(s.music.busiestDay?.day, LocalDay(year: 2024, month: 1, day: 2))
        XCTAssertEqual(s.music.busiestDay?.ms, 320_000)
        XCTAssertEqual(s.music.daily.count, 366)
        XCTAssertEqual(s.music.daily[1].ms, 320_000)
        // 2024-01-01 was a Monday.
        XCTAssertEqual(s.music.heatmap[0][10], 300_000)
        XCTAssertEqual(s.music.heatmap[1][10], 300_000)
        XCTAssertEqual(s.music.heatmap[1][11], 20_000)
        XCTAssertEqual(s.music.heatmap.flatMap { $0 }.reduce(0, +), s.music.ms)
        XCTAssertEqual(s.podcasts.ms, 3_600_000, "podcasts are counted apart")
        XCTAssertEqual(s.podcasts.listens, 1)
        XCTAssertEqual(s.podcasts.topShows.map(\.name), ["Show"])
    }

    func testTimeZoneMovesTheNewYearListen() throws {
        // 23:49 UTC on Dec 31 is 04:49 on Jan 1 in Tashkent.
        let s = try stats(.year(2024), tashkent)
        XCTAssertEqual(s.music.ms, 860_000)
        XCTAssertEqual(s.music.listens, 5)
        XCTAssertEqual(s.music.newArtists.count, 3)
        XCTAssertEqual(s.music.heatmap[0][4], 60_000)
        XCTAssertEqual(try stats(.year(2023), tashkent).music.ms, 0)
        let utc2023 = try stats(.year(2023), utc)
        XCTAssertEqual(utc2023.music.ms, 60_000)
        XCTAssertEqual(utc2023.music.newArtists.top.map(\.name), ["A"])
    }

    func testWeekMonthAndAllTime() throws {
        let week = try stats(.week(LocalDay(year: 2024, month: 1, day: 3)), utc)
        XCTAssertEqual(week.period, "week:2024-01-01")
        XCTAssertEqual(week.music.daily.count, 7)
        XCTAssertEqual(week.music.ms, 800_000)
        XCTAssertEqual(try stats(.month(year: 2024, month: 1), utc).music.ms, 800_000)
        XCTAssertEqual(try stats(.month(year: 2024, month: 2), utc).music.ms, 0)
        let all = try stats(.allTime, utc)
        XCTAssertNil(all.start)
        XCTAssertEqual(all.music.ms, 860_000)
        XCTAssertEqual(all.music.daily.first?.day, LocalDay(year: 2023, month: 12, day: 31))
        XCTAssertEqual(all.music.daily.count, 6)
        XCTAssertEqual(all.music.newArtists.count, 3)
    }

    func testEmptyPeriod() throws {
        let s = try stats(.year(1999), utc)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.music.longestStreak)
        XCTAssertNil(s.music.busiestDay)
        XCTAssertEqual(s.music.daily.count, 365)
    }

    func testJSONShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(try stats(.year(2024), utc))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["start"] as? String, "2024-01-01")
        let music = object?["music"] as? [String: Any]
        let daily = music?["daily"] as? [[String: Any]]
        XCTAssertEqual(daily?.first?["day"] as? String, "2024-01-01")
        XCTAssertEqual(try JSONDecoder().decode(Stats.self, from: data), try stats(.year(2024), utc))
    }

    func testPeriods() {
        XCTAssertEqual(Period("year:2024"), .year(2024))
        XCTAssertEqual(Period("month:2024-03"), .month(year: 2024, month: 3))
        XCTAssertEqual(Period("week:2024-03-10")?.description, "week:2024-03-04")
        XCTAssertEqual(Period("all"), .allTime)
        XCTAssertNil(Period("month:2024-13"))
        XCTAssertNil(Period("decade:2020"))
        XCTAssertEqual(Period.month(year: 2024, month: 12).days?.upperBound, LocalDay(year: 2025, month: 1, day: 1))
        XCTAssertEqual(Period.month(year: 2024, month: 1).previous, .month(year: 2023, month: 12))
        XCTAssertEqual(Period.week(LocalDay(year: 2024, month: 1, day: 1)).previous?.description, "week:2023-12-25")
        // Two days of one week are the same period.
        XCTAssertEqual(Period.week(LocalDay(year: 2024, month: 3, day: 5)), .week(LocalDay(year: 2024, month: 3, day: 9)))
        let now = Date(timeIntervalSince1970: 1_704_049_200) // 2023-12-31 19:00 UTC, 2024-01-01 00:00 in Tashkent
        XCTAssertEqual(Period.current(.year, now: now, timeZone: utc), .year(2023))
        XCTAssertEqual(Period.current(.year, now: now, timeZone: tashkent), .year(2024))
    }

    func testLocalDayArithmetic() {
        XCTAssertEqual(LocalDay(year: 1970, month: 1, day: 1).number, 0)
        XCTAssertEqual(LocalDay(year: 1970, month: 1, day: 1).weekday, 3, "a Thursday")
        XCTAssertEqual(LocalDay(year: 2024, month: 2, day: 29).description, "2024-02-29")
        XCTAssertEqual(LocalDay(year: 1969, month: 12, day: 31).number, -1)
        for n in stride(from: -800_000, through: 800_000, by: 997) {
            let d = LocalDay(number: n)
            XCTAssertEqual(LocalDay(year: d.year, month: d.month, day: d.day).number, n)
        }
    }

    /// The fast offset cache must agree with Calendar across clock changes.
    func testLocalClockMatchesCalendar() {
        for id in ["America/New_York", "Europe/Berlin", "Australia/Lord_Howe", "Asia/Tashkent", "America/Santiago",
                   "Asia/Kolkata", "Pacific/Chatham"] {
            let tz = TimeZone(identifier: id)!
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tz
            var clock = LocalClock(timeZone: tz)
            var ms: Int64 = 1_672_531_200_000 // 2023-01-01
            var mismatches = 0
            while ms < 1_735_689_600_000 { // 2025-01-01
                let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                let c = calendar.dateComponents([.year, .month, .day, .hour], from: date)
                let local = clock.localSeconds(utcMillis: ms)
                let day = LocalDay(number: Civil.floorDiv(local, 86_400))
                let hour = (local - day.number * 86_400) / 3600
                if day != LocalDay(year: c.year!, month: c.month!, day: c.day!) || hour != c.hour! { mismatches += 1 }
                ms += 2_222_111 // about 37 minutes, so it lands on many minutes and seconds
            }
            XCTAssertEqual(mismatches, 0, id)
        }
    }
}
