import Foundation

/// How the history is put into words, the same in Settings > History and in Liner Notes.
///
/// A play is music played for 30 seconds or more (`StatsEngine.listenThresholdMs`): the
/// number Liner Notes shows. Every stored row is an entry, so short plays and podcast
/// episodes are entries but not plays.
enum HistoryWords {
    static func entries(_ n: Int) -> String { n == 1 ? "1 entry" : "\(LinerFormat.number(n)) entries" }

    /// "40,609 plays and 8,263 other entries", or just one half when the other is none.
    static func playsAndEntries(plays: Int, total: Int) -> String {
        let other = max(0, total - plays)
        if plays == 0 { return entries(other) }
        if other == 0 { return LinerFormat.plays(plays) }
        return "\(LinerFormat.plays(plays)) and \(LinerFormat.number(other)) other \(other == 1 ? "entry" : "entries")"
    }

    // MARK: Import

    static func importHeadline(_ r: ImportResult, plays: Int) -> String {
        if plays > 0 { return "Added \(LinerFormat.plays(plays))" }
        return r.added - r.replacedLive > 0 ? "Added only short plays and podcasts" : "Nothing new to add"
    }

    /// What the import found, in plain sentences.
    static func importLines(_ r: ImportResult, plays: Int, timeZone tz: TimeZone) -> [String] {
        var out: [String] = []
        if let first = r.first, let last = r.last {
            let f = DateFormatter()
            f.timeZone = tz
            f.setLocalizedDateFormatFromTemplate("MMMMy")
            let a = f.string(from: first), b = f.string(from: last)
            out.append(a == b ? "All from \(a)." : "From \(a) to \(b).")
        }
        // Rows the import brought that are not plays. A replaced listen is not new.
        let other = r.added - r.replacedLive - plays
        if other > 0 {
            out.append("\(LinerFormat.number(other)) more \(other == 1 ? "entry is kept but doesn’t" : "entries are kept but don’t") count as plays: songs stopped before 30 seconds, and podcasts.")
        }
        if r.duplicates > 0 {
            out.append("\(LinerFormat.number(r.duplicates)) \(r.duplicates == 1 ? "entry was" : "entries were") in more than one file or already here, and count once.")
        }
        if r.replacedLive > 0 {
            out.append("\(LinerFormat.number(r.replacedLive)) \(r.replacedLive == 1 ? "listen" : "listens") Tonearm heard itself now use Spotify’s more exact times.")
        }
        if !r.unreadable.isEmpty {
            out.append("Couldn’t read \(r.unreadable.count == 1 ? "1 file" : "\(r.unreadable.count) files"): \(r.unreadable.prefix(3).joined(separator: ", ")).")
        }
        return out
    }

    /// The headline and the lines as one paragraph, for Settings.
    static func importNote(_ r: ImportResult, plays: Int, timeZone: TimeZone = .current) -> String {
        ([importHeadline(r, plays: plays) + "."] + importLines(r, plays: plays, timeZone: timeZone))
            .joined(separator: " ")
    }
}
