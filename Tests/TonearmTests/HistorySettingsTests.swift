import XCTest
@testable import Tonearm

/// The words Settings > History shows.
@MainActor
final class HistorySettingsTests: XCTestCase {
    func testImportResultInWords() {
        let start = HistorySettingsModel.date(2019, 3, 4)
        let end = HistorySettingsModel.date(2024, 10, 30)
        let r = ImportResult(files: 7, rows: 50_100, added: 48_872, duplicates: 1_203, skipped: 25,
                             unreadable: ["a.json", "b.json"], first: start, last: end)
        XCTAssertEqual(HistorySettingsModel.describe(r),
                       "Added \(HistorySettingsModel.count(48_872)) listens from \(HistorySettingsModel.monthYear(start)) "
                       + "to \(HistorySettingsModel.monthYear(end)). \(HistorySettingsModel.count(1_203)) were already "
                       + "here. 2 files could not be read.")
        XCTAssertEqual(HistorySettingsModel.describe(ImportResult(files: 1, rows: 3, duplicates: 3)),
                       "Nothing new: all 3 were already here.")
    }

    func testSummaryLine() {
        let model = HistorySettingsModel.preview(summary: HistorySummary(count: 1, first: HistorySettingsModel.date(2020, 1, 5)))
        XCTAssertEqual(model.summaryLine(recording: true), "1 listen since \(HistorySettingsModel.monthYear(HistorySettingsModel.date(2020, 1, 5)))")
        XCTAssertTrue(HistorySettingsModel.preview(summary: HistorySummary()).summaryLine(recording: true).hasPrefix("Nothing yet"))
    }
}
