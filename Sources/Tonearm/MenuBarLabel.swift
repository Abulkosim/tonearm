import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        if let title = currentTitle {
            HStack(spacing: 4) {
                Image(systemName: model.isPlaying ? "music.note" : "pause.fill")
                Text(Self.leftToRight(title, firstPart: model.track.map { Self.singleLine($0.title) } ?? ""))
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
        var parts = [singleLine(title)]
        if showArtist { parts.append(singleLine(artist)) }
        return shorten(parts.filter { !$0.isEmpty }.joined(separator: " · "), to: maxLength)
    }

    /// Lays out `text`, which is `title(...)`, left to right with the song title first, and keeps
    /// each part's own direction inside it. Without this an Arabic title made the whole line
    /// right to left: the artist came first and the ellipsis landed on the wrong end.
    /// `firstPart` is the single-line song title. Pure, for tests.
    static func leftToRight(_ text: String, firstPart: String) -> String {
        let lrm = "\u{200E}"
        func isolate(_ s: String) -> String { "\u{2068}" + s + "\u{2069}" }
        let separator = " · "
        guard !firstPart.isEmpty, text.hasPrefix(firstPart + separator) else { return lrm + isolate(text) }
        let rest = String(text.dropFirst(firstPart.count + separator.count))
        return lrm + isolate(firstPart) + separator + isolate(rest)
    }

    /// Collapses line breaks, tabs and repeated spaces, which would break the menu bar layout.
    static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Cuts `s` to at most `max` characters, ending in "…" when cut, after a whole word when
    /// one ends in the second half.
    /// Whitespace and separators left at the cut are dropped before the ellipsis. Pure, for tests.
    static func shorten(_ s: String, to max: Int) -> String {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > max else { return s }
        guard max > 1 else { return max == 1 ? "…" : "" }
        var head = Substring(s.prefix(max - 1))
        // End at a word's end when one is in the second half, not mid-word ("Dancefloo…").
        let cutMidWord = !Array(s)[max - 1].isWhitespace
        if cutMidWord, let space = head.lastIndex(where: \.isWhitespace),
           head.distance(from: head.startIndex, to: space) >= max / 2 {
            head = head[..<space]
        }
        while let last = head.last, last.isWhitespace || "·-–—,:;".contains(last) {
            head.removeLast()
        }
        return String(head) + "…"
    }
}
