import XCTest
@testable import Tonearm

final class TextDirectionTests: XCTestCase {
    func testFirstLetterPicksTheDirection() {
        XCTAssertTrue(FadingLine.startsRightToLeft("أغنية عن البحر"))
        XCTAssertTrue(FadingLine.startsRightToLeft("(1) שיר"))
        XCTAssertFalse(FadingLine.startsRightToLeft("Habibi (حبيبي)"))
        XCTAssertFalse(FadingLine.startsRightToLeft("夜に駆ける"))
        XCTAssertFalse(FadingLine.startsRightToLeft("🔥 123"))
        XCTAssertFalse(FadingLine.startsRightToLeft(""))
    }

    @MainActor
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
