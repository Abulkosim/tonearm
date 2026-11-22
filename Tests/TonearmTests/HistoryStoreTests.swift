import XCTest
@testable import Tonearm

/// Import, dedup, live recording, export and delete, on a temporary database.
final class HistoryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> HistoryStore { HistoryStore(url: dir.appendingPathComponent("db/history.sqlite")) }

    @discardableResult
    private func write(_ name: String, _ json: String) throws -> URL {
        let url = dir.appendingPathComponent("export").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return url
    }

    private func ms(_ iso: String) -> Int64 { Timestamp.parse(iso)! }

    /// Two extended rows (one song, one episode), one exact duplicate, one row with
    /// nothing to show, and private fields that must not be kept.
    private let extended = """
    [
     {"ts": "2024-03-01T10:03:20Z", "platform": "OS X 14", "ms_played": 200000, "conn_country": "UZ",
      "ip_addr": "192.0.2.7", "master_metadata_track_name": "Звезда", "master_metadata_album_artist_name": "Кино",
      "master_metadata_album_album_name": "Группа крови", "spotify_track_uri": "spotify:track:aaa",
      "episode_name": null, "episode_show_name": null, "spotify_episode_uri": null, "reason_start": "clickrow",
      "reason_end": "trackdone", "shuffle": false, "skipped": false, "offline": false, "offline_timestamp": null,
      "incognito_mode": false},
     {"ts": "2024-03-01T10:03:20Z", "platform": "OS X 14", "ms_played": 200000, "conn_country": "UZ",
      "ip_addr": "192.0.2.7", "master_metadata_track_name": "Звезда", "master_metadata_album_artist_name": "Кино",
      "master_metadata_album_album_name": "Группа крови", "spotify_track_uri": "spotify:track:aaa",
      "episode_name": null, "episode_show_name": null, "spotify_episode_uri": null, "reason_start": "clickrow",
      "reason_end": "trackdone", "shuffle": false, "skipped": false, "offline": false, "offline_timestamp": null,
      "incognito_mode": false},
     {"ts": "2024-03-02T08:00:00Z", "ms_played": 1500000, "ip_addr": "192.0.2.8",
      "master_metadata_track_name": null, "master_metadata_album_artist_name": null,
      "master_metadata_album_album_name": null, "spotify_track_uri": null, "episode_name": "Ep 1",
      "episode_show_name": "Show", "spotify_episode_uri": "spotify:episode:eee", "skipped": null},
     {"ts": "2024-03-02T09:00:00Z", "ms_played": 5000, "master_metadata_track_name": null,
      "spotify_track_uri": null, "episode_name": null, "spotify_episode_uri": null,
      "audiobook_title": "A Book"}
    ]
    """

    func testImportsExtendedHistoryOnceAndKeepsNoPrivateFields() throws {
        try write("Spotify Extended Streaming History/Streaming_History_Audio_2024_0.json", extended)
        let s = store()
        let first = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        XCTAssertEqual(first.files, 1)
        XCTAssertEqual(first.rows, 4)
        XCTAssertEqual(first.added, 2)
        XCTAssertEqual(first.duplicates, 1)
        XCTAssertEqual(first.skipped, 1)
        XCTAssertEqual(first.first, Date(timeIntervalSince1970: TimeInterval(ms("2024-03-01T10:00:00Z")) / 1000))

        let again = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.duplicates, 3)
        XCTAssertEqual(try s.sync { try $0.countNow() }, 2)

        let csv = dir.appendingPathComponent("out.csv"), json = dir.appendingPathComponent("out.json")
        XCTAssertEqual(try s.sync { try $0.exportNow(to: csv, format: .csv) }, 2)
        XCTAssertEqual(try s.sync { try $0.exportNow(to: json, format: .json) }, 2)
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(csvText.hasPrefix(HistoryStore.exportColumns.joined(separator: ",") + "\n"))
        XCTAssertTrue(csvText.contains("Группа крови"))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]]
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?.first?["title"] as? String, "Звезда")
        XCTAssertEqual(rows?.first?["kind"] as? String, "music")
        XCTAssertEqual(rows?.first?["reason_start"] as? String, "clickrow")
        XCTAssertEqual(rows?.last?["kind"] as? String, "podcast")
        // The store is still open, so the WAL still holds what the import wrote.
        let wal = URL(fileURLWithPath: s.url.path + "-wal")
        let walBlob = try Data(contentsOf: wal)
        XCTAssertNotNil(walBlob.range(of: Data("Группа крови".utf8)), "else the WAL check proves nothing")
        for blob in try [csv, json, s.url].map({ try Data(contentsOf: $0) }) + [walBlob] {
            XCTAssertNil(blob.range(of: Data("192.0.2.".utf8)))
            XCTAssertNil(blob.range(of: Data("OS X 14".utf8)))
        }
    }

    /// An import says how many plays it added, by the rule Liner Notes uses: the episode is
    /// stored but is not a play. The summary counts the same way.
    func testImportCountsPlaysLikeLinerNotes() async throws {
        try write("Spotify Extended Streaming History/Streaming_History_Audio_2024_0.json", extended)
        let s = store()
        let (result, plays) = try await s.importCountingPlays(urls: [dir.appendingPathComponent("export")])
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(plays, 1)
        let allTime = try await s.stats(for: .allTime)
        XCTAssertEqual(allTime.music.listens, plays)
        let summary = try await s.summary()
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.plays, 1)
        let (_, again) = try await s.importCountingPlays(urls: [dir.appendingPathComponent("export")])
        XCTAssertEqual(again, 0)
    }

    func testSchema() throws {
        let s = store()
        XCTAssertEqual(try s.sync { try $0.countNow() }, 0)
        let db = try SQLiteDB(path: s.url.path)
        XCTAssertEqual(try db.int("PRAGMA user_version"), HistoryStore.schemaVersion)
        let mode = try db.prepare("PRAGMA journal_mode")
        mode.bind([])
        XCTAssertTrue(try mode.step())
        XCTAssertEqual(mode.text(0), "wal")
        let columns = try db.prepare("SELECT name FROM pragma_table_info('listens') UNION ALL SELECT name FROM pragma_table_info('tracks')")
        columns.bind([])
        var names: [String] = []
        while try columns.step() { names.append(columns.text(0)) }
        XCTAssertTrue(names.contains("started_at"))
        for banned in ["ip_addr", "conn_country", "platform", "username", "user_agent_decrypted"] {
            XCTAssertFalse(names.contains(banned), banned)
        }
    }

    /// A database from a newer Tonearm is left alone, and the words say to update, not to try again.
    func testNewerSchemaAsksForAnUpdate() throws {
        let url = dir.appendingPathComponent("newer/history.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SQLiteDB(path: url.path).exec("PRAGMA user_version = \(HistoryStore.schemaVersion + 1)")
        let s = HistoryStore(url: url)
        XCTAssertThrowsError(try s.sync { try $0.countNow() }) { error in
            XCTAssertEqual(error as? HistoryError, .newerSchema(HistoryStore.schemaVersion + 1))
            let problem = HistoryWords.problem(error)
            XCTAssertTrue(problem.needsUpdate)
            XCTAssertTrue(problem.detail.contains("Update Tonearm"), problem.detail)
            XCTAssertTrue(problem.detail.hasSuffix("."), problem.detail)
        }
        let other = HistoryWords.problem(SQLiteError.step("disk I/O error"))
        XCTAssertFalse(other.needsUpdate)
        XCTAssertEqual(other.detail, "History database error: disk I/O error.")
    }

    func testAccountDataAndExtendedHistoryOfTheSamePlaysCountOnce() throws {
        // Account data has the end time to the minute and no album; extended history wins.
        let account = """
        [{"endTime": "2024-03-01 10:03", "artistName": "Кино", "trackName": "Звезда", "msPlayed": 200000},
         {"endTime": "2024-03-01 11:00", "artistName": "Кино", "trackName": "Звезда", "msPlayed": 200000}]
        """
        try write("Spotify Account Data/StreamingHistory_music_0.json", account)
        try write("Spotify Account Data/StreamingHistory_podcast_0.json", """
        [{"endTime": "2024-03-02 08:00", "podcastName": "Show", "episodeName": "Ep 1", "msPlayed": 1500000}]
        """)
        let s = store()
        let a = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        XCTAssertEqual(a.added, 3)
        try write("Spotify Extended Streaming History/Streaming_History_Audio_2024_0.json", extended)
        let both = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        XCTAssertEqual(both.added, 0, "the extended rows replace the account rows in place")
        XCTAssertEqual(try s.sync { try $0.countNow() }, 3)
        let stats = try s.sync { try $0.statsNow(for: .allTime, timeZone: TimeZone(identifier: "UTC")!) }
        XCTAssertEqual(stats.music.ms, 400_000)
        XCTAssertEqual(stats.music.topAlbums.map(\.name), ["Группа крови"])
        XCTAssertEqual(stats.podcasts.ms, 1_500_000)

        // The other order gives the same result.
        let other = HistoryStore(url: dir.appendingPathComponent("db2/history.sqlite"))
        let ext = dir.appendingPathComponent("export/Spotify Extended Streaming History")
        _ = try other.sync { try $0.importNow(urls: [ext]) }
        _ = try other.sync { try $0.importNow(urls: [dir.appendingPathComponent("export/Spotify Account Data")]) }
        let otherStats = try other.sync { try $0.statsNow(for: .allTime, timeZone: TimeZone(identifier: "UTC")!) }
        XCTAssertEqual(otherStats, stats)
    }

    func testZipImport() throws {
        try write("Spotify Extended Streaming History/Streaming_History_Audio_2024_0.json", extended)
        try write("Spotify Account Data/Userdata.json", #"{"username": "someone"}"#)
        let zip = dir.appendingPathComponent("my_spotify_data.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", dir.appendingPathComponent("export").path, zip.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let s = store()
        let r = try s.sync { try $0.importNow(urls: [zip]) }
        XCTAssertEqual(r.files, 1, "Userdata.json is not streaming history")
        XCTAssertEqual(r.added, 2)
        // A single json file works too, and is a duplicate now.
        let single = try s.sync {
            try $0.importNow(urls: [self.dir.appendingPathComponent(
                "export/Spotify Extended Streaming History/Streaming_History_Audio_2024_0.json")])
        }
        XCTAssertEqual(single.added, 0)
        XCTAssertThrowsError(try s.sync { try $0.importNow(urls: [self.dir.appendingPathComponent("nothing")]) })
    }

    /// Zips made on a Mac carry __MACOSX/._ files; a broken one must not stop the import.
    /// The zip is laid out like the CI fixture's (scripts/make-history-fixture.py): the
    /// history file in a folder, then a junk ._ entry for it under __MACOSX, no folder
    /// entries and no extra fields. Plain ditto fails on that one with "File exists".
    func testZipWithJunkMacMetadata() throws {
        let src = dir.appendingPathComponent("zipsrc")
        let file = "Spotify Account Data/Streaming_History_Audio_2024_0.json"
        let junk = "__MACOSX/Spotify Account Data/._Streaming_History_Audio_2024_0.json"
        for name in [file, junk] {
            try FileManager.default.createDirectory(at: src.appendingPathComponent(name).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        try Data(extended.utf8).write(to: src.appendingPathComponent(file))
        try Data([0, 5, 22, 7] + Array("junk".utf8)).write(to: src.appendingPathComponent(junk))
        let zip = dir.appendingPathComponent("junk.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = src
        p.arguments = ["-q", "-D", "-X", zip.path, file, junk]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        // The zip must break plain ditto, or this test proves nothing about the fallback.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, dir.appendingPathComponent("plain-ditto").path]
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertNotEqual(ditto.terminationStatus, 0, "plain ditto unpacked the junk zip")
        let tool = try HistoryFiles.unzip(zip, to: dir.appendingPathComponent("unpacked"))
        print("history: a zip that plain ditto rejects was unpacked by \(tool)")
        let r = try store().sync { try $0.importNow(urls: [zip]) }
        XCTAssertEqual(r.files, 1)
        XCTAssertEqual(r.added, 2)
    }

    /// A zip that will not unpack leaves no unpacked folder behind, not even those of the
    /// zips before it in the same pick.
    func testFailedUnzipLeavesNothingBehind() throws {
        try write("Streaming_History_Audio_2024_0.json", extended)
        let good = dir.appendingPathComponent("good.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", dir.appendingPathComponent("export").path, good.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let bad = dir.appendingPathComponent("bad.zip")
        try Data("not a zip".utf8).write(to: bad)
        func unpacked() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("tonearm-import-") })
        }
        let before = try unpacked()
        XCTAssertThrowsError(try store().sync { try $0.importNow(urls: [good, bad]) })
        XCTAssertTrue(try unpacked().isSubset(of: before))
    }

    func testImportReplacesOverlappingLiveListens() throws {
        let s = store()
        let start = Date(timeIntervalSince1970: TimeInterval(ms("2024-03-01T10:00:00Z")) / 1000 + 2)
        // Tonearm heard it live, a little later and a little shorter than Spotify counted.
        s.save(LiveListen(trackID: "spotify:track:aaa", kind: .music, title: "Звезда", artist: "Кино",
                          album: "Группа крови", artworkURL: "https://i.scdn.co/image/x", durationMs: 200_000,
                          startedAt: start, endedAt: start.addingTimeInterval(196), msPlayed: 196_000))
        // And another song nobody exported.
        let later = start.addingTimeInterval(86_400 * 30)
        s.save(LiveListen(trackID: "spotify:track:bbb", kind: .music, title: "Other", artist: "Someone",
                          album: "", artworkURL: nil, durationMs: nil, startedAt: later,
                          endedAt: later.addingTimeInterval(60), msPlayed: 60_000))
        s.flush()
        XCTAssertEqual(try s.sync { try $0.countNow() }, 2)
        try write("Streaming_History_Audio_2024_0.json", extended)
        let r = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        XCTAssertEqual(r.replacedLive, 1)
        XCTAssertEqual(r.added, 2)
        XCTAssertEqual(try s.sync { try $0.countNow() }, 3)
        let stats = try s.sync { try $0.statsNow(for: .allTime, timeZone: TimeZone(identifier: "UTC")!) }
        XCTAssertEqual(stats.music.ms, 260_000, "Spotify's 200 s, not Tonearm's 196 s, plus the other song")
    }

    /// Tonearm quit and started again 70 s into a 240 s song, so it kept two rows for one
    /// play. Spotify's one row replaces both. The next play of the song, which the export
    /// does not have, stays.
    func testImportReplacesEveryPieceOfASplitLiveListen() throws {
        let s = store()
        let start = Date(timeIntervalSince1970: TimeInterval(ms("2024-03-01T10:00:00Z")) / 1000)
        func live(_ from: TimeInterval, _ to: TimeInterval, _ seconds: Int64) -> LiveListen {
            LiveListen(trackID: "spotify:track:aaa", kind: .music, title: "Звезда", artist: "Кино",
                       album: "Группа крови", artworkURL: nil, durationMs: 240_000,
                       startedAt: start.addingTimeInterval(from), endedAt: start.addingTimeInterval(to),
                       msPlayed: seconds * 1000)
        }
        s.save(live(0, 70, 70))
        s.save(live(100, 240, 140))
        s.save(live(240, 480, 240))
        s.flush()
        try write("Streaming_History_Audio_2024_0.json", """
        [{"ts": "2024-03-01T10:04:00Z", "ms_played": 240000, "master_metadata_track_name": "Звезда",
          "master_metadata_album_artist_name": "Кино", "master_metadata_album_album_name": "Группа крови",
          "spotify_track_uri": "spotify:track:aaa"}]
        """)
        let r = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        XCTAssertEqual(r.replacedLive, 2)
        XCTAssertEqual(try s.sync { try $0.countNow() }, 2)
        let stats = try s.sync { try $0.statsNow(for: .allTime, timeZone: TimeZone(identifier: "UTC")!) }
        XCTAssertEqual(stats.music.ms, 480_000, "Spotify's 240 s for the first play, Tonearm's 240 s for the next")
        XCTAssertEqual(stats.music.listens, 2)
    }

    /// Repeat one on a short song: an export with only the first play must not take the
    /// second live play with it.
    func testImportKeepsTheNextPlayOfTheSameSong() throws {
        let s = store()
        let start = Date(timeIntervalSince1970: TimeInterval(ms("2024-03-01T10:00:00Z")) / 1000)
        for i in 0..<2 {
            s.save(LiveListen(trackID: "", kind: .music, title: "Short", artist: "A", album: "", artworkURL: nil,
                              durationMs: 60_000, startedAt: start.addingTimeInterval(Double(i) * 60),
                              endedAt: start.addingTimeInterval(Double(i + 1) * 60), msPlayed: 60_000))
        }
        s.flush()
        // Account data is to the minute, so this row overlaps both live plays.
        try write("StreamingHistory_music_0.json", """
        [{"endTime": "2024-03-01 10:01", "artistName": "A", "trackName": "Short", "msPlayed": 60000}]
        """)
        let r = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        XCTAssertEqual(r.replacedLive, 1)
        XCTAssertEqual(try s.sync { try $0.countNow() }, 2)
    }

    func testLiveListenUpdatesInPlace() throws {
        let s = store()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var l = LiveListen(trackID: "spotify:track:aaa", kind: .music, title: "T", artist: "A", album: "B",
                           artworkURL: nil, durationMs: 100_000, startedAt: start, endedAt: start, msPlayed: 25_000)
        s.save(l)
        l.msPlayed = 50_000
        l.artworkURL = "https://i.scdn.co/image/y"
        s.save(l)
        s.flush()
        XCTAssertEqual(try s.sync { try $0.countNow() }, 1)
        let stats = try s.sync { try $0.statsNow(for: .allTime, timeZone: TimeZone(identifier: "UTC")!) }
        XCTAssertEqual(stats.music.ms, 50_000)
    }

    func testDeleteAllAndYears() async throws {
        try write("a/StreamingHistory_music_0.json", """
        [{"endTime": "2019-05-01 10:00", "artistName": "A", "trackName": "T", "msPlayed": 60000},
         {"endTime": "2023-12-31 19:30", "artistName": "A", "trackName": "T", "msPlayed": 60000}]
        """)
        let s = store()
        var progress: [ImportProgress] = []
        let r = try await s.import(urls: [dir.appendingPathComponent("export")]) { progress.append($0) }
        XCTAssertEqual(r.added, 2)
        XCTAssertEqual(progress.last?.filesDone, 1)
        let utcYears = try await s.years(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(utcYears, [2019, 2023])
        // 19:29 UTC on Dec 31 is already 2024 in Tashkent (UTC+5).
        let tashkentYears = try await s.years(timeZone: TimeZone(identifier: "Asia/Tashkent")!)
        XCTAssertEqual(tashkentYears, [2019, 2024])
        let count = try await s.count()
        XCTAssertEqual(count, 2)

        let started = Date().addingTimeInterval(-10)
        try await s.deleteAll()
        let afterDelete = try await s.count()
        XCTAssertEqual(afterDelete, 0)
        // The listen that was open while deleting does not come back.
        s.save(LiveListen(trackID: "spotify:track:x", kind: .music, title: "T", artist: "A", album: "",
                          artworkURL: nil, durationMs: nil, startedAt: started, endedAt: Date(), msPlayed: 10_000))
        s.flush()
        let afterSave = try await s.count()
        XCTAssertEqual(afterSave, 0)
        let empty = try await s.stats(for: .allTime)
        XCTAssertTrue(empty.isEmpty)
    }

    /// A database that can't be opened is an error, not empty stats, and the store tries
    /// again on the next call instead of giving up until relaunch.
    func testOpenFailureIsReportedAndRetried() async throws {
        let blocker = dir.appendingPathComponent("db")
        try Data("a file where the folder should be".utf8).write(to: blocker)
        let s = store()
        do {
            _ = try await s.stats(for: .allTime)
            XCTFail("stats on a database that can't be opened")
        } catch {}
        do {
            _ = try await s.count()
            XCTFail("count on a database that can't be opened")
        } catch {}
        try FileManager.default.removeItem(at: blocker)
        let count = try await s.count()
        XCTAssertEqual(count, 0)
    }

    /// After "delete all", no title is left in the database file or its WAL, with the
    /// store still open as it is in the app.
    func testDeleteAllLeavesNothingOnDisk() throws {
        try write("Streaming_History_Audio_2024_0.json", extended)
        let s = store()
        _ = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        let wal = URL(fileURLWithPath: s.url.path + "-wal")
        let title = Data("Группа крови".utf8)
        let before = try Data(contentsOf: s.url) + Data(contentsOf: wal)
        XCTAssertNotNil(before.range(of: title), "else the checks below prove nothing")
        try s.sync { try $0.deleteAllNow() }
        XCTAssertEqual(try s.sync { try $0.countNow() }, 0)
        let walAfter = try Data(contentsOf: wal)
        XCTAssertEqual(walAfter.count, 0)
        XCTAssertNil(try Data(contentsOf: s.url).range(of: title))
        XCTAssertNil(walAfter.range(of: title))
    }

    /// An import that changed something rewrites the file in order and empties the WAL, so
    /// the first read after a launch is sequential. One that changed nothing leaves it.
    func testImportCompactsOnlyWhenSomethingChanged() throws {
        try write("Streaming_History_Audio_2024_0.json", extended)
        let s = store()
        var phases: [String] = []
        s.phaseLog = { phases.append($0) }
        _ = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        XCTAssertEqual(phases.filter { $0.hasPrefix("import compact") }.count, 1, "\(phases)")
        let wal = URL(fileURLWithPath: s.url.path + "-wal")
        XCTAssertEqual(try Data(contentsOf: wal).count, 0)
        XCTAssertEqual(try s.sync { try SQLiteDB(path: $0.url.path).int("PRAGMA freelist_count") }, 0)

        phases = []
        let again = try s.sync { try $0.importNow(urls: [dir.appendingPathComponent("export")]) }
        XCTAssertEqual(again.added, 0)
        XCTAssertFalse(phases.contains { $0.hasPrefix("import compact") }, "\(phases)")
        XCTAssertEqual(try s.sync { try $0.countNow() }, 2)
    }

    func testTimestamps() {
        XCTAssertEqual(Timestamp.parse("1970-01-01T00:00:00Z"), 0)
        XCTAssertEqual(Timestamp.parse("2024-03-01T10:03:20Z"), 1_709_287_400_000)
        XCTAssertEqual(Timestamp.parse("2024-03-01 10:03"), 1_709_287_380_000)
        XCTAssertEqual(Timestamp.parse("2024-03-01T10:03:20.5Z"), 1_709_287_400_500)
        XCTAssertEqual(Timestamp.parse("2024-03-01T15:03:20+05:00"), 1_709_287_400_000)
        XCTAssertEqual(Timestamp.parse("2024-02-29T00:00:00Z"), 1_709_164_800_000)
        XCTAssertNil(Timestamp.parse("2024-13-01T00:00:00Z"))
        XCTAssertNil(Timestamp.parse("yesterday"))
        XCTAssertNil(Timestamp.parse("2024-03-01T10:03:20Zjunk"))
    }

    func testDedupKey() {
        let a = ImportRecord(kind: .music, title: "T", artist: "A", album: "X", uri: "spotify:track:1",
                             endedAt: ms("2024-03-01T10:03:59Z"), msPlayed: 1000, precision: 1)
        var b = a
        b.endedAt = ms("2024-03-01T10:03:00Z")
        b.album = ""
        b.uri = ""
        b.precision = 0
        XCTAssertEqual(a.dedupKey, b.dedupKey, "same play from the two export kinds")
        b.endedAt = ms("2024-03-01T10:04:00Z")
        XCTAssertNotEqual(a.dedupKey, b.dedupKey)
        var c = a
        c.artist = "Another"
        XCTAssertNotEqual(a.dedupKey, c.dedupKey, "same title by another artist")
        var d = a
        d.msPlayed = 1001
        XCTAssertNotEqual(a.dedupKey, d.dedupKey)
    }
}

/// The reads Settings > History and ListenBrainz use.
final class HistoryStoreReadTests: XCTestCase {
    /// Saving a play of a known track keeps the cached catalog; a new track drops it. Either
    /// way the next stats are right.
    func testStatsStayRightAsPlaysAreSaved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-cat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func save(_ title: String, at i: Int) throws {
            try store.sync {
                try $0.saveNow(LiveListen(trackID: "spotify:track:\(title)", kind: .music, title: title, artist: "A",
                                          album: "B", artworkURL: nil, durationMs: 100_000,
                                          startedAt: t0.addingTimeInterval(Double(i) * 200),
                                          endedAt: t0.addingTimeInterval(Double(i) * 200 + 60), msPlayed: 60_000))
            }
        }
        try save("One", at: 0)
        XCTAssertEqual(try store.sync { try $0.statsNow(for: .allTime, timeZone: .current) }.music.listens, 1)
        try save("One", at: 1)
        XCTAssertEqual(try store.sync { try $0.statsNow(for: .allTime, timeZone: .current) }.music.topTracks.map(\.listens), [2])
        try save("Two", at: 2)
        let s = try store.sync { try $0.statsNow(for: .allTime, timeZone: .current) }
        XCTAssertEqual(s.music.topTracks.map(\.name), ["One", "Two"])
        XCTAssertEqual(s.music.listens, 3)
    }

    func testStoreSummaryAndMusicPages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-sum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
        XCTAssertEqual(try store.sync { try $0.summaryNow() }, HistorySummary())
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            let id = i == 4 ? "spotify:episode:e" : "spotify:track:t\(i % 2)"
            try store.sync {
                try $0.saveNow(LiveListen(trackID: id, kind: ListenKind.of(spotifyID: id), title: "T\(i % 2)",
                                          artist: "A", album: "B", artworkURL: nil, durationMs: 100_000,
                                          startedAt: t0.addingTimeInterval(Double(i) * 200),
                                          endedAt: t0.addingTimeInterval(Double(i) * 200 + 60),
                                          msPlayed: Int64(60_000 + i * 1_000)))
            }
        }
        let sum = try store.sync { try $0.summaryNow() }
        XCTAssertEqual(sum.count, 5)
        XCTAssertEqual(sum.plays, 4, "the episode is not a play")
        XCTAssertEqual(sum.first, t0)
        XCTAssertEqual(sum.last, t0.addingTimeInterval(800))
        let all = try store.sync { try $0.musicPageNow(after: nil, before: .max, limit: 10) }
        XCTAssertEqual(all.count, 4, "music only")
        let page1 = try store.sync { try $0.musicPageNow(after: nil, before: .max, limit: 3) }
        let page2 = try store.sync { try $0.musicPageNow(after: page1.last?.cursor, before: .max, limit: 3) }
        XCTAssertEqual((page1 + page2).map(\.id), all.map(\.id))
        let longest = try store.sync { try $0.longestPlaysNow() }
        XCTAssertEqual(Set(longest.values.map(\.longest)), [62_000, 63_000])
        XCTAssertEqual(longest.values.compactMap(\.finished), [], "live plays don't say how they ended")
        // The launch warm-up reads the period the window opens on: this year, or the last one with plays.
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(try store.sync { try $0.warmNow(timeZone: utc, now: t0) }, .year(2023))
        XCTAssertEqual(try store.sync { try $0.warmNow(timeZone: utc, now: Date(timeIntervalSince1970: 1_800_000_000)) },
                       .year(2023))
    }
}

final class HistoryExportTests: XCTestCase {
    func testCSVTextNeverRunsAsAFormula() {
        XCTAssertEqual(HistoryStore.csvField("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(HistoryStore.csvField("+44"), "'+44")
        XCTAssertEqual(HistoryStore.csvField("-ism"), "'-ism")
        XCTAssertEqual(HistoryStore.csvField("@home"), "'@home")
        XCTAssertEqual(HistoryStore.csvField("Song, Part 2"), "\"Song, Part 2\"")
        XCTAssertEqual(HistoryStore.csvField("Mötley Crüe"), "Mötley Crüe")
        XCTAssertEqual(HistoryStore.csvField(Int64(-5)), "-5", "numbers are left alone")
        XCTAssertEqual(HistoryStore.csvField(true), "true")
        XCTAssertEqual(HistoryStore.csvField(nil), "")
    }
}
