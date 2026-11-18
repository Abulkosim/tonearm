import XCTest
@testable import Tonearm

/// The words Settings > History shows. They count plays the way Liner Notes does.
@MainActor
final class HistorySettingsTests: XCTestCase {
    func testImportResultInWords() {
        let utc = TimeZone(identifier: "UTC")!
        let start = HistorySettingsModel.date(2019, 3, 4)
        let end = HistorySettingsModel.date(2024, 10, 30)
        let r = ImportResult(files: 7, rows: 50_100, added: 48_872, duplicates: 1_203, skipped: 25,
                             unreadable: ["a.json", "b.json"], first: start, last: end)
        let note = HistoryWords.importNote(r, plays: 40_609, timeZone: utc)
        XCTAssertTrue(note.hasPrefix("Added \(LinerFormat.number(40_609)) plays. From "), note)
        XCTAssertTrue(note.contains("\(LinerFormat.number(8_263)) more entries are kept but don’t count as plays"), note)
        XCTAssertTrue(note.contains("\(LinerFormat.number(1_203)) entries were in more than one file"), note)
        XCTAssertTrue(note.hasSuffix("Couldn’t read 2 files: a.json, b.json."), note)
        XCTAssertFalse(note.contains("listens"), note)
        // The window's headline is the same sentence.
        XCTAssertEqual(HistoryWords.importHeadline(r, plays: 40_609), "Added \(LinerFormat.number(40_609)) plays")
        XCTAssertEqual(HistoryWords.importNote(ImportResult(files: 1, rows: 3, duplicates: 3), plays: 0, timeZone: utc),
                       "Nothing new to add. 3 entries were in more than one file or already here, and count once.")
        XCTAssertEqual(HistoryWords.importHeadline(ImportResult(files: 1, rows: 2, added: 2), plays: 0),
                       "Added only short plays and podcasts")
    }

    func testSummaryLineCountsPlays() {
        let jan2020 = HistorySettingsModel.date(2020, 1, 5)
        let model = HistorySettingsModel.preview(summary: HistorySummary(count: 3, first: jan2020, plays: 1))
        XCTAssertEqual(model.summaryLine(recording: true), "1 play since \(HistorySettingsModel.monthYear(jan2020))")
        XCTAssertEqual(model.deletedWords, "1 play and 2 other entries")
        let sample = HistorySettingsModel.sample
        XCTAssertEqual(sample.summaryLine(recording: true),
                       "\(LinerFormat.number(40_609)) plays since \(HistorySettingsModel.monthYear(HistorySettingsModel.date(2019, 3, 4)))")
        let onlyShort = HistorySettingsModel.preview(summary: HistorySummary(count: 4, first: jan2020, plays: 0))
        XCTAssertEqual(onlyShort.summaryLine(recording: true), "No plays yet: 4 entries, all short plays or podcasts.")
        XCTAssertEqual(onlyShort.deletedWords, "4 entries")
        XCTAssertTrue(HistorySettingsModel.preview(summary: HistorySummary()).summaryLine(recording: true).hasPrefix("Nothing yet"))
    }

    func testPlaysAndEntries() {
        XCTAssertEqual(HistoryWords.playsAndEntries(plays: 2, total: 2), "2 plays")
        XCTAssertEqual(HistoryWords.playsAndEntries(plays: 2, total: 3), "2 plays and 1 other entry")
        XCTAssertEqual(HistoryWords.playsAndEntries(plays: 0, total: 1), "1 entry")
    }
}
