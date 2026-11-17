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
}
