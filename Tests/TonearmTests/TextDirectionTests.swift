import XCTest
@testable import Tonearm

@MainActor
final class TextDirectionTests: XCTestCase {
    func testFirstLetterPicksTheDirection() {
        XCTAssertTrue(FadingLine.startsRightToLeft("أغنية عن البحر"))
        XCTAssertTrue(FadingLine.startsRightToLeft("(1) שיר"))
        XCTAssertFalse(FadingLine.startsRightToLeft("Habibi (حبيبي)"))
        XCTAssertFalse(FadingLine.startsRightToLeft("夜に駆ける"))
        XCTAssertFalse(FadingLine.startsRightToLeft("🔥 123"))
        XCTAssertFalse(FadingLine.startsRightToLeft(""))
    }

    func testMenuBarTitleRunsLeftToRight() {
        let lrm = "\u{200E}", fsi = "\u{2068}", pdi = "\u{2069}"
        let title = "أغنية عن البحر"
        let text = MenuBarLabel.title(title, artist: "Sample Artist", showArtist: true, maxLength: 24)
        XCTAssertEqual(MenuBarLabel.leftToRight(text, firstPart: title),
                       lrm + fsi + title + pdi + " · " + fsi + "Sample…" + pdi)
        // Cut inside the title: one part.
        XCTAssertEqual(MenuBarLabel.leftToRight("Long ti…", firstPart: "Long title"), lrm + fsi + "Long ti…" + pdi)
        XCTAssertEqual(MenuBarLabel.leftToRight("Artist", firstPart: ""), lrm + fsi + "Artist" + pdi)
    }
}

@MainActor
final class MenuBarCutTests: XCTestCase {
    func testCutsAtAWordEnd() {
        XCTAssertEqual(MenuBarLabel.shorten("🔥 Fire on the Dancefloor 💃🕺", to: 24), "🔥 Fire on the…")
        XCTAssertEqual(MenuBarLabel.shorten("The Unbearable Lightness of Being", to: 24), "The Unbearable…")
        // The cut already falls between words.
        XCTAssertEqual(MenuBarLabel.shorten("Звезда по имени Солнце", to: 10), "Звезда по…")
        // No word ends in the second half: cut the word.
        XCTAssertEqual(MenuBarLabel.shorten("A Supercalifragilistic song", to: 15), "A Supercalifra…")
        // No spaces, as in Japanese.
        XCTAssertEqual(MenuBarLabel.shorten("千と千尋の神隠しサウンドトラック", to: 8), "千と千尋の神隠…")
    }

    /// A cut in the artist never goes back into the title, so "Title…" always means the
    /// title was cut.
    func testCutInTheArtistKeepsTheArtist() {
        func bar(_ title: String, _ artist: String, _ max: Int) -> String {
            MenuBarLabel.title(title, artist: artist, showArtist: true, maxLength: max)
        }
        XCTAssertEqual(bar("Bohemian Rhapsody", "Queen", 24), "Bohemian Rhapsody · Que…")
        XCTAssertEqual(bar("Sample Song Title", "Sample Artist", 24), "Sample Song Title · Sam…")
        XCTAssertEqual(bar("Blinding Lights", "The Weeknd", 24), "Blinding Lights · The…")
        // No letter of the artist fits: the title alone, not cut.
        XCTAssertEqual(bar("Sample Song Title", "Sample Artist", 20), "Sample Song Title")
        XCTAssertEqual(bar("Sample Song Title", "Sample Artist", 17), "Sample Song Title")
        // Cut in the title: the title ends at a word.
        XCTAssertEqual(bar("The Unbearable Lightness of Being", "Sample Artist", 24), "The Unbearable…")
        XCTAssertEqual(bar("Sample Song Title", "Sample Artist", 16), "Sample Song…")
    }
}
