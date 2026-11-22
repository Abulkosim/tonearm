import Foundation

/// One listen read from a Spotify data export, before it is stored.
///
/// Spotify sends two kinds of export (Account > Privacy > Download your data):
/// - Account data, the past year: `StreamingHistory_music_N.json`, `StreamingHistory_podcast_N.json`
///   (older: `StreamingHistoryN.json`). Rows have `endTime` ("yyyy-MM-dd HH:mm", UTC, to the
///   minute), `artistName` + `trackName` or `podcastName` + `episodeName`, and `msPlayed`.
/// - Extended streaming history, the account's lifetime: `Streaming_History_Audio_*.json`,
///   `Streaming_History_Video_*.json` (older: `endsong_N.json`). Rows have `ts` (ISO 8601,
///   UTC, when the stream ended), `ms_played`, `master_metadata_*`, `spotify_track_uri`,
///   `episode_*`, `spotify_episode_uri`, `reason_start`, `reason_end`, `shuffle`, `skipped`,
///   `offline`, `incognito_mode`, and also `ip_addr`, `conn_country` and `platform`, which
///   Tonearm never reads.
struct ImportRecord: Equatable {
    var kind: ListenKind
    var title: String
    /// Artist (the album artist in extended history), or the show for podcasts.
    var artist: String
    var album: String
    var uri: String
    /// When the stream ended, UTC milliseconds.
    var endedAt: Int64
    var msPlayed: Int64
    /// 0: end time known to the minute (account data). 1: to the second or better.
    var precision: Int
    var skipped: Bool?
    var shuffle: Bool?
    var offline: Bool?
    var incognito: Bool?
    var reasonStart: String?
    var reasonEnd: String?

    var startedAt: Int64 { endedAt - msPlayed }

    /// The same listen in any export has the same key: kind, names (the URI too when the
    /// title is missing), the minute it ended, and the milliseconds played. Account data
    /// gives the end time to the minute, extended history to the second, so the minute is
    /// what both share. Two real plays of one song that end in the same minute with the
    /// same milliseconds collide; in practice that only happens to 0 ms skips.
    var dedupKey: Int64 {
        var s = "\(kind.rawValue)\u{1F}\(artist)\u{1F}\(title)"
        if title.isEmpty { s += "\u{1F}\(uri)" }
        s += "\u{1F}\(Civil.floorDiv(Int(endedAt), 60_000))\u{1F}\(msPlayed)"
        return FNV.hash(s)
    }
}

/// 64-bit FNV-1a. Stable across launches and versions, unlike `Hasher`.
enum FNV {
    static func hash(_ s: String) -> Int64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: h)
    }
}

enum ExportParser {
    struct Parsed {
        var records: [ImportRecord] = []
        var rows = 0
        var skipped = 0
    }

    /// File names that hold streaming history, in a folder or a zip.
    static func isHistoryFile(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n.hasSuffix(".json"), !n.hasPrefix("._") else { return false }
        return n.hasPrefix("streaminghistory") || n.hasPrefix("streaming_history_") || n.hasPrefix("endsong")
    }

    /// Parses one file: a JSON array of rows in either format. Throws if it is not one.
    static func parse(_ data: Data) throws -> Parsed {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var out = Parsed()
        out.rows = rows.count
        out.records.reserveCapacity(rows.count)
        for row in rows {
            if let dict = row as? [String: Any], let record = record(dict) {
                out.records.append(record)
            } else {
                out.skipped += 1
            }
        }
        return out
    }

    /// Nil for rows Tonearm does not keep: no song or episode, audiobooks, ads, bad times.
    static func record(_ row: [String: Any]) -> ImportRecord? {
        if let ts = row["ts"] as? String {
            return extended(row, ts: ts)
        }
        if let endTime = row["endTime"] as? String {
            return account(row, endTime: endTime)
        }
        return nil
    }

    private static func extended(_ row: [String: Any], ts: String) -> ImportRecord? {
        guard let end = Timestamp.parse(ts) else { return nil }
        let ms = millis(row["ms_played"])
        let trackURI = string(row["spotify_track_uri"])
        let trackName = string(row["master_metadata_track_name"])
        let episodeURI = string(row["spotify_episode_uri"])
        let episodeName = string(row["episode_name"])
        var r: ImportRecord
        if !trackURI.isEmpty || !trackName.isEmpty {
            r = ImportRecord(kind: .music, title: trackName, artist: string(row["master_metadata_album_artist_name"]),
                             album: string(row["master_metadata_album_album_name"]), uri: trackURI,
                             endedAt: end, msPlayed: ms, precision: 1)
        } else if !episodeURI.isEmpty || !episodeName.isEmpty {
            r = ImportRecord(kind: .podcast, title: episodeName, artist: string(row["episode_show_name"]),
                             album: "", uri: episodeURI, endedAt: end, msPlayed: ms, precision: 1)
        } else {
            return nil
        }
        if r.uri.hasPrefix("spotify:ad:") { return nil }
        r.skipped = bool(row["skipped"])
        r.shuffle = bool(row["shuffle"])
        r.offline = bool(row["offline"])
        r.incognito = bool(row["incognito_mode"])
        r.reasonStart = optionalString(row["reason_start"])
        r.reasonEnd = optionalString(row["reason_end"])
        return r
    }

    private static func account(_ row: [String: Any], endTime: String) -> ImportRecord? {
        guard let end = Timestamp.parse(endTime) else { return nil }
        let ms = millis(row["msPlayed"])
        let r: ImportRecord
        if row["podcastName"] != nil || row["episodeName"] != nil {
            r = ImportRecord(kind: .podcast, title: string(row["episodeName"]), artist: string(row["podcastName"]),
                             album: "", uri: "", endedAt: end, msPlayed: ms, precision: 0)
        } else {
            r = ImportRecord(kind: .music, title: string(row["trackName"]), artist: string(row["artistName"]),
                             album: "", uri: "", endedAt: end, msPlayed: ms, precision: 0)
        }
        if r.title.isEmpty && r.artist.isEmpty { return nil }
        return r
    }

    private static func string(_ value: Any?) -> String { value as? String ?? "" }

    private static func optionalString(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber else { return nil }
        return n.boolValue
    }

    private static func millis(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber {
            let d = n.doubleValue
            return d.isFinite && d > 0 ? Int64(d) : 0
        }
        if let s = value as? String, let d = Double(s), d.isFinite, d > 0 { return Int64(d) }
        return 0
    }
}

/// UTC timestamps in Spotify's exports, parsed by hand: a formatter per row is too slow
/// for 100k rows. Accepts "yyyy-MM-dd HH:mm", "yyyy-MM-ddTHH:mm:ss", an optional fraction,
/// and "Z" or "+hh:mm" / "-hh:mm". Returns UTC milliseconds.
enum Timestamp {
    static func parse(_ s: String) -> Int64? {
        let b = Array(s.utf8)
        func num(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= b.count else { return nil }
            var v = 0
            for i in from..<(from + count) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard b.count >= 16, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 32, b[13] == 58,
              let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60
        else { return nil }
        var i = 16
        var sec = 0
        var millis = 0
        if i < b.count, b[i] == 58 {
            guard let s = num(i + 1, 2), s < 61 else { return nil }
            sec = s
            i += 3
            if i < b.count, b[i] == 46 {
                i += 1
                var digits = 0
                while i < b.count, b[i] >= 48, b[i] <= 57 {
                    if digits < 3 { millis = millis * 10 + Int(b[i] - 48) }
                    digits += 1
                    i += 1
                }
                guard digits > 0 else { return nil }
                for _ in min(digits, 3)..<3 { millis *= 10 }
            }
        }
        var offset = 0
        if i < b.count {
            if b[i] == 90 || b[i] == 122 {
                i += 1
            } else if b[i] == 43 || b[i] == 45 {
                guard let oh = num(i + 1, 2) else { return nil }
                var j = i + 3
                if j < b.count, b[j] == 58 { j += 1 }
                let om = num(j, 2) ?? 0
                if num(j, 2) != nil { j += 2 }
                offset = (oh * 3600 + om * 60) * (b[i] == 45 ? -1 : 1)
                i = j
            }
            guard i == b.count else { return nil }
        }
        let days = Civil.days(year: y, month: mo, day: d)
        let seconds = days * 86_400 + h * 3600 + mi * 60 + sec - offset
        return Int64(seconds) * 1000 + Int64(millis)
    }
}

/// Finds streaming history files in what the user picked: folders (searched inside),
/// .zip files (unpacked with /usr/bin/ditto into a temporary folder), or .json files.
struct HistoryFiles {
    var files: [URL] = []
    private var temporary: [URL] = []

    /// Folders a .zip is unpacked into start with this, in `temporaryDirectory`.
    static let unpackPrefix = "tonearm-import-"

    /// If it throws, every folder it unpacked is already gone: they can hold the rest of
    /// the user's Spotify data.
    static func collect(_ urls: [URL], temporaryDirectory: URL = FileManager.default.temporaryDirectory)
        throws -> HistoryFiles {
        var out = HistoryFiles()
        var done = false
        defer { if !done { out.cleanUp() } }
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                out.files += folder(url)
            } else if url.pathExtension.lowercased() == "zip" {
                let dir = temporaryDirectory.appendingPathComponent(unpackPrefix + UUID().uuidString, isDirectory: true)
                out.temporary.append(dir)
                try unzip(url, to: dir)
                out.files += folder(dir)
            } else if url.pathExtension.lowercased() == "json" {
                out.files.append(url)
            }
        }
        done = true
        return out
    }

    /// Streaming history files under `dir`, sorted by path so imports run in the same order.
    static func folder(_ dir: URL) -> [URL] {
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(atPath: base) else { return [] }
        var found: [String] = []
        while let rel = walker.nextObject() as? String {
            let parts = rel.split(separator: "/")
            if parts.contains(where: { $0 == "__MACOSX" }) { continue }
            if let name = parts.last, ExportParser.isHistoryFile(String(name)) { found.append(rel) }
        }
        found.sort { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        return found.map { URL(fileURLWithPath: base).appendingPathComponent($0) }
    }

    /// Unpacks with ditto, ignoring resource forks and extended attributes, and with unzip
    /// if ditto fails. Plain ditto failed in CI with "File exists" on a zip that has both a
    /// file and a __MACOSX/._ entry for it, which zips made in Finder can have. Returns the
    /// tool that worked. If none did, `dir` is removed.
    @discardableResult
    static func unzip(_ zip: URL, to dir: URL) throws -> String {
        let tools = [("/usr/bin/ditto", ["-x", "-k", "--norsrc", "--noextattr", "--noacl", zip.path, dir.path]),
                     ("/usr/bin/unzip", ["-qq", "-o", zip.path, "-d", dir.path])]
        for (tool, arguments) in tools {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return tool }
        }
        try? FileManager.default.removeItem(at: dir)
        throw ImportError.unzipFailed(zip.lastPathComponent)
    }

    func cleanUp() {
        for dir in temporary { try? FileManager.default.removeItem(at: dir) }
    }

    /// Removes unpacked exports an import left behind when Tonearm was killed or crashed
    /// in the middle of it: they hold the user's whole Spotify download, and macOS keeps
    /// temporary files for days. Only folders untouched for `olderThan` seconds, so an
    /// import running in another Tonearm process (`--stats`) keeps its own. Returns how many.
    @discardableResult
    static func removeLeftovers(in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                                olderThan age: TimeInterval, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: temporaryDirectory.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(unpackPrefix) {
            let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            guard now.timeIntervalSince(modified) >= age else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
