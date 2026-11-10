import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        if let title = currentTitle {
            HStack(spacing: 4) {
                Image(systemName: model.isPlaying ? "music.note" : "pause.fill")
                Text(title)
            }
        } else {
            Image(systemName: Self.appGlyph)
        }
    }

    private var currentTitle: String? {
        guard settings.menuBarStyle == .songTitle,
              model.status == .ready,
              model.playback.state != .stopped,
              let track = model.track
        else { return nil }
        let title = Self.title(track.title, artist: track.artist,
                               showArtist: settings.showArtist, maxLength: settings.maxTitleLength)
        return title.isEmpty ? nil : title
    }

    /// The app's own menu bar glyph: a disc, for a record player's arm.
    /// Falls back to a note if the symbol is missing on this macOS.
    static let appGlyph: String =
        NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: nil) != nil ? "opticaldisc" : "music.note"

    /// Menu bar text for a track. Pure, for tests.
    static func title(_ title: String, artist: String, showArtist: Bool, maxLength: Int) -> String {
        var parts = [title.trimmingCharacters(in: .whitespacesAndNewlines)]
        if showArtist { parts.append(artist.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return shorten(parts.filter { !$0.isEmpty }.joined(separator: " · "), to: maxLength)
    }

    /// Cuts `s` to at most `max` characters, ending in "…" when cut.
    /// Whitespace and separators left at the cut are dropped before the ellipsis. Pure, for tests.
    static func shorten(_ s: String, to max: Int) -> String {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > max else { return s }
        guard max > 1 else { return max == 1 ? "…" : "" }
        var head = Substring(s.prefix(max - 1))
        while let last = head.last, last.isWhitespace || "·-–—,:;".contains(last) {
            head.removeLast()
        }
        return String(head) + "…"
    }
}
