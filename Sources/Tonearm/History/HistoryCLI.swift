import Foundation

/// `Tonearm --stats <export> [--stats <export> ...] [--period P[,P...]] [--tz TZ[,TZ...]] [--json]
///  [--db <file>] [--export <file.csv|file.json>]`
///
/// Imports Spotify exports (folders, .zip or .json) into a fresh database (a temporary one
/// unless --db is given) and prints stats. Never touches the user's own history. With one
/// period and one time zone, --json prints that `Stats`; with more, an object with the
/// import result and `stats["<tz> <period>"]`. Timings go to stderr. Periods: week:2024-03-11,
/// month:2024-03, year:2024, all. Default: all, in the Mac's time zone.
enum HistoryCLI {
    static func run(_ args: [String]) -> Int32 {
        var inputs: [URL] = []
        var periods: [Period] = []
        /// As given: TimeZone(identifier: "UTC") calls itself "GMT".
        var zones: [(name: String, zone: TimeZone)] = []
        var json = false
        var dbPath: String?
        var exportPath: String?
        var i = 0
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--stats":
                guard let v = value() else { return fail("--stats needs a path") }
                inputs.append(URL(fileURLWithPath: v))
            case "--period":
                guard let v = value() else { return fail("--period needs a value") }
                for part in v.split(separator: ",") {
                    guard let p = Period(String(part)) else { return fail("bad period \(part)") }
                    periods.append(p)
                }
            case "--tz":
                guard let v = value() else { return fail("--tz needs a value") }
                for part in v.split(separator: ",") {
                    guard let z = TimeZone(identifier: String(part)) else { return fail("unknown time zone \(part)") }
                    zones.append((String(part), z))
                }
            case "--json":
                json = true
            case "--db":
                dbPath = value()
            case "--export":
                exportPath = value()
            default:
                break
            }
            i += 1
        }
        guard !inputs.isEmpty else { return fail("--stats needs a path") }
        if periods.isEmpty { periods = [.allTime] }
        if zones.isEmpty { zones = [(TimeZone.current.identifier, .current)] }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = dbPath.map { URL(fileURLWithPath: $0) } ?? tempDir.appendingPathComponent("history.sqlite")
        let store = HistoryStore(url: dbURL)

        do {
            var started = DispatchTime.now()
            var result = ImportResult()
            for input in inputs {
                let r = try store.sync { try $0.importNow(urls: [input]) }
                result.files += r.files
                result.rows += r.rows
                result.added += r.added
                result.duplicates += r.duplicates
                result.skipped += r.skipped
                result.replacedLive += r.replacedLive
                result.unreadable += r.unreadable
                if let f = r.first, result.first.map({ f < $0 }) ?? true { result.first = f }
                if let l = r.last, result.last.map({ l > $0 }) ?? true { result.last = l }
            }
            let count = try store.sync { try $0.countNow() }
            log("import: \(result.rows) rows from \(result.files) files, \(result.added) added, "
                + "\(result.duplicates) duplicates, \(result.skipped) skipped, \(count) stored, \(ms(since: started)) ms")

            var all: [String: Stats] = [:]
            var keys: [String] = []
            for (name, zone) in zones {
                for period in periods {
                    started = DispatchTime.now()
                    let stats = try store.sync { try $0.statsNow(for: period, timeZone: zone) }
                    log("stats \(name) \(period): \(ms(since: started)) ms")
                    let key = "\(name) \(period)"
                    all[key] = stats
                    keys.append(key)
                }
            }

            if let exportPath {
                let url = URL(fileURLWithPath: exportPath)
                let format: ExportFormat = url.pathExtension.lowercased() == "json" ? .json : .csv
                let n = try store.sync { try $0.exportNow(to: url, format: format) }
                log("export: \(n) listens to \(url.lastPathComponent)")
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            if json {
                let data: Data
                if keys.count == 1, let only = all[keys[0]] {
                    data = try encoder.encode(only)
                } else {
                    data = try encoder.encode(Combined(imported: result, stats: all))
                }
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                for key in keys { if let s = all[key] { print(summary(key, s)) } }
            }
            return 0
        } catch {
            return fail("\(error)")
        }
    }

    private struct Combined: Encodable {
        var imported: ImportResult
        var stats: [String: Stats]

        enum CodingKeys: String, CodingKey {
            case imported = "import"
            case stats
        }
    }

    private static func summary(_ key: String, _ s: Stats) -> String {
        var lines = ["\(key): \(Int(s.music.minutes)) min of music, \(s.music.listens) listens, "
                     + "\(s.music.uniqueArtists) artists, \(Int(s.podcasts.minutes)) min of podcasts"]
        for (n, a) in s.music.topArtists.prefix(5).enumerated() {
            lines.append("  \(n + 1). \(a.name), \(Int(a.minutes)) min")
        }
        return lines.joined(separator: "\n")
    }

    private static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    private static func fail(_ s: String) -> Int32 {
        log("tonearm --stats: \(s)")
        return 1
    }
}
