import AppKit
import CoreText
import XCTest
@testable import Tonearm

final class LinerNotesWindowTests: XCTestCase {
    func testShortcutOpensLinerNotes() {
        XCTAssertEqual(KeyCommand.from(keyCode: 37, characters: "l", modifiers: [.command]), .linerNotes)
        // "д" sits on the L key in the Russian layout.
        XCTAssertEqual(KeyCommand.from(keyCode: 37, characters: "д", modifiers: [.command]), .linerNotes)
        XCTAssertNil(KeyCommand.from(keyCode: 37, characters: "l", modifiers: []))
        XCTAssertTrue(KeyCommand.help.contains { $0.keys == "⌘L" })
    }

    func testPlayerTrackingSkipsTheLinerNotesWindow() {
        // SwiftUI's windows all come from com.apple.SwiftUI; the Liner Notes one is named
        // after its scene.
        XCTAssertFalse(PlayerModel.isPopoverWindow(className: "SwiftUI.AppKitWindow", classBundleID: "com.apple.SwiftUI",
                                                   identifier: "liner-notes-AppWindow-1"))
        XCTAssertTrue(PlayerModel.isPopoverWindow(className: "SomePanel", classBundleID: "com.apple.SwiftUI",
                                                  identifier: nil))
        XCTAssertTrue(LinerNotesWindow.isLinerNotes(identifier: "liner-notes"))
        XCTAssertFalse(LinerNotesWindow.isLinerNotes(identifier: "tonearm.welcome"))
    }
}

final class WordClampTests: XCTestCase {
    func testCandidatesEndAtWholeWords() {
        XCTAssertEqual(WordClampedText.candidates("Hello big world"), ["Hello big world", "Hello big…", "Hello…"])
    }

    func testTrailingPunctuationIsDropped() {
        XCTAssertEqual(WordClampedText.candidates("Piano Concerto No. 2, Op. 18")[1], "Piano Concerto No. 2, Op…")
        XCTAssertEqual(WordClampedText.candidates("Florence + The Machine").last, "Florence…")
        XCTAssertEqual(WordClampedText.candidates("Песня о звезде (Remastered 2024)")[1], "Песня о звезде (Remastered…")
    }

    func testOneWordHasNoShorterOption() {
        XCTAssertEqual(WordClampedText.candidates("Supercalifragilistic"), ["Supercalifragilistic"])
        XCTAssertEqual(WordClampedText.candidates(""), [""])
    }

    func testLongestWord() {
        XCTAssertEqual(WordClampedText.longestWord("Florence + The Machine"), "Florence")
        XCTAssertEqual(WordClampedText.longestWord("Supercalifragilistic and more"), "Supercalifragilistic")
        XCTAssertEqual(WordClampedText.longestWord("!!!"), "")
    }

    func testJapaneseBreaksBetweenWords() {
        let options = WordClampedText.candidates("夜に駆ける、そしてまた夜明けまで歩き続ける")
        XCTAssertGreaterThan(options.count, 2)
        for option in options.dropFirst() {
            XCTAssertTrue(option.hasSuffix("…"))
            XCTAssertFalse(option.hasSuffix("、…"))
        }
    }

    func testJoinersOnlyGoInsideCJKWords() {
        XCTAssertEqual(WordClampedText.joinWords("Florence + The Machine"), "Florence + The Machine")
        XCTAssertEqual(WordClampedText.joinWords("Оркестр Северного ветра"), "Оркестр Северного ветра")
        XCTAssertEqual(WordClampedText.joinWords("سامي يوسف"), "سامي يوسف")
        let name = "宇多田ヒカルと東京フィルハーモニー交響楽団"
        let joined = WordClampedText.joinWords(name)
        XCTAssertNotEqual(joined, name)
        XCTAssertEqual(joined.replacingOccurrences(of: WordClampedText.wordJoiner, with: ""), name)
    }

    /// The wrap itself, not just where the ellipsis goes: Core Text lays the names out at
    /// every width their longest word fits in, and no line may start inside a word.
    func testJapaneseWrapsOnlyBetweenWords() {
        let font = NSFont.systemFont(ofSize: 13)
        func attributed(_ s: String) -> NSAttributedString { NSAttributedString(string: s, attributes: [.font: font]) }
        func lineStarts(_ s: String, width: CGFloat) -> [Int] {
            let setter = CTFramesetterCreateWithAttributedString(attributed(s))
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
            return lines.map { CTLineGetStringRange($0).location }
        }
        // UTF-16 offsets strictly inside a word, from the word breaker on the text as written.
        func insideWords(_ s: String) -> Set<Int> {
            var inside = Set<Int>()
            s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: [.byWords, .substringNotRequired]) {
                _, range, _, _ in
                let r = NSRange(range, in: s)
                if r.length > 1 { inside.formUnion((r.location + 1)..<(r.location + r.length)) }
            }
            return inside
        }
        let names = ["宇多田ヒカルと坂本龍一と東京フィルハーモニー交響楽団", "夜に駆ける、そしてまた夜明けまで歩き続ける長い道"]
        var plainSplits = 0, widthsTried = 0
        for name in names {
            let joined = WordClampedText.joinWords(name)
            let longest = CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(attributed(WordClampedText.longestWord(name))), nil, nil, nil)
            let inside = insideWords(name)
            // A line start in the joined text, as an offset in `name`: less the joiners before it.
            let joinerOffsets = joined.utf16.enumerated().filter { $0.element == 0x2060 }.map(\.offset)
            XCTAssertFalse(joinerOffsets.isEmpty)
            func original(_ start: Int) -> Int { start - joinerOffsets.filter { $0 < start }.count }
            for width in stride(from: CGFloat(ceil(longest)) + 1, through: 400, by: 5) {
                widthsTried += 1
                for start in lineStarts(joined, width: width).dropFirst() {
                    XCTAssertFalse(inside.contains(original(start)), "\(name) at \(width) pt: a line starts inside a word")
                }
                plainSplits += lineStarts(name, width: width).dropFirst().filter(inside.contains).count
            }
        }
        XCTAssertGreaterThan(widthsTried, 20)
        // Without the joiners Core Text does split words, so the check above can fail.
        XCTAssertGreaterThan(plainSplits, 0)
    }
}

final class CoverStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-covers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testKeepsReadsAndDeletesWithTheHistory() async throws {
        let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
        let url = "https://i.scdn.co/image/ab67616d0000b273aaaa"
        XCTAssertEqual(store.covers.directory, dir.appendingPathComponent("Covers", isDirectory: true))
        let nothing = await store.covers.data(for: url)
        XCTAssertNil(nothing)
        store.covers.saveNow(Data([1, 2, 3]), for: url)
        // The first copy stays.
        store.covers.saveNow(Data([9]), for: url)
        let kept = await store.covers.data(for: url)
        XCTAssertEqual(kept, Data([1, 2, 3]))
        XCTAssertEqual(CoverStore.fileName(for: url).count, 64)
        try await store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.covers.directory.path))
        let gone = await store.covers.data(for: url)
        XCTAssertNil(gone)
    }

    /// Liner Notes reads covers from disk and nothing else. A plain check of its source.
    func testLinerNotesMakesNoNetworkRequests() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Tonearm/LinerNotes").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 5)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for word in ["URLSession", "URLRequest", "NSURLConnection", "dataTask", "Data(contentsOf: URL(string"] {
                XCTAssertFalse(source.contains(word), "\(file.lastPathComponent) uses \(word)")
            }
        }
    }
}

final class LinerArtTests: XCTestCase {
    func testTilesAreTheSameForTheSameName() {
        let a = NameTile.colors(for: "Кино"), b = NameTile.colors(for: "Кино")
        XCTAssertEqual(a.face, b.face)
        XCTAssertNotEqual(NameTile.colors(for: "Кино").face, NameTile.colors(for: "Сплин").face)
    }

    func testInitials() {
        XCTAssertEqual(NameTile.initials("Sigur Rós"), "SR")
        XCTAssertEqual(NameTile.initials("The 1975"), "T1")
        XCTAssertEqual(NameTile.initials("坂本龍一"), "坂")
        XCTAssertEqual(NameTile.initials("!!!"), "!")
        XCTAssertEqual(NameTile.initials("🌊 Wave Machine"), "WM")
        XCTAssertEqual(NameTile.initials("ólafur arnalds"), "ÓA")
    }

    func testWhiteInitialsReadOnEveryTile() {
        let white = PaletteColor(r: 1, g: 1, b: 1)
        for i in 0..<2000 {
            let face = NameTile.colors(for: "artist \(i)").face
            XCTAssertGreaterThanOrEqual(SleeveColors.contrast(white, face), 3, "artist \(i)")
        }
    }

    /// Every sleeve, from any cover color, keeps both text roles at 4.5:1 or more.
    func testSleeveTextAlwaysReads() {
        var lowest = Double.infinity
        for h in stride(from: 0.0, to: 1.0, by: 1.0 / 72) {
            for s in stride(from: 0.0, through: 1.0, by: 0.1) {
                for v in stride(from: 0.0, through: 1.0, by: 0.1) {
                    let base = PaletteColor(hue: h, saturation: s, brightness: v)
                    let sleeve = SleeveColors(palette: ArtworkPalette.tones(for: base))
                    lowest = min(lowest, sleeve.minimumTextContrast)
                }
            }
        }
        for i in 0..<500 { lowest = min(lowest, SleeveColors(name: "album \(i)").minimumTextContrast) }
        XCTAssertGreaterThanOrEqual(lowest, 4.5)
    }

    func testSleeveFromPaleAndBlackCovers() {
        for cover in [Snapshot.SampleCover.pale, .black, .warm, .teal] {
            let sleeve = SleeveColors(image: Snapshot.sampleArtwork(cover))
            XCTAssertNotNil(sleeve)
            XCTAssertGreaterThanOrEqual(sleeve?.minimumTextContrast ?? 0, 4.5)
        }
    }
}

final class LinerFormatTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testPeriodSteps() {
        XCTAssertEqual(Period.month(year: 2024, month: 12).next, .month(year: 2025, month: 1))
        XCTAssertEqual(Period.year(2024).next, .year(2025))
        XCTAssertEqual(Period.week(LocalDay(year: 2024, month: 12, day: 31)).next,
                       .week(LocalDay(year: 2025, month: 1, day: 6)))
        XCTAssertNil(Period.allTime.next)
        XCTAssertEqual(Period.of(.month, containing: LocalDay(year: 2023, month: 7, day: 9)), .month(year: 2023, month: 7))
        XCTAssertEqual(Period.month(year: 2023, month: 7).kind, .month)
    }

    func testMinutes() {
        XCTAssertEqual(LinerFormat.minutes(29_999), 0)
        XCTAssertEqual(LinerFormat.minutes(30_000), 1)
        XCTAssertEqual(LinerFormat.minutes(60_000 * 41_203), 41_203)
        XCTAssertEqual(LinerFormat.plays(1), "1 play")
        XCTAssertEqual(LinerFormat.hours(3_600_000 * 2 + 1), "2 hours")
        XCTAssertEqual(LinerFormat.hours(60_000 * 41), "41 minutes")
    }

    func testAverageCountsOnlyDaysSoFar() {
        let start = LocalDay(year: 2025, month: 11, day: 17)
        let week = (0..<7).map { Stats.DayTotal(day: start.adding(days: $0), ms: 60_000) }
        XCTAssertEqual(ListeningChart.daysSoFar(week, today: LocalDay(year: 2025, month: 11, day: 19)), 3)
        XCTAssertEqual(ListeningChart.daysSoFar(week, today: LocalDay(year: 2026, month: 1, day: 1)), 7)
    }

    func testTitles() {
        XCTAssertEqual(LinerFormat.title(.year(2024), timeZone: utc), "2024")
        XCTAssertEqual(LinerFormat.title(.allTime, timeZone: utc), "All time")
        XCTAssertTrue(LinerFormat.title(.month(year: 2025, month: 11), timeZone: utc).contains("2025"))
        XCTAssertTrue(LinerFormat.title(.week(LocalDay(year: 2025, month: 11, day: 19)), timeZone: utc).contains("17"))
    }
}

@MainActor
final class LinerNotesModelTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func model(_ period: Period) -> LinerNotesModel {
        LinerNotesModel(snapshot: .ready, period: period, stats: nil, years: Array(2019...2025), total: 10,
                        now: LocalDay(year: 2025, month: 11, day: 20).date(in: utc), timeZone: utc)
    }

    func testArrowsStopAtTodayAndTheFirstYear() {
        XCTAssertFalse(model(.year(2025)).canGoForward)
        XCTAssertTrue(model(.year(2024)).canGoForward)
        XCTAssertFalse(model(.year(2019)).canGoBack)
        XCTAssertTrue(model(.year(2020)).canGoBack)
        XCTAssertFalse(model(.month(year: 2025, month: 11)).canGoForward)
        XCTAssertFalse(model(.week(LocalDay(year: 2025, month: 11, day: 20))).canGoForward)
        XCTAssertFalse(model(.allTime).canGoBack)
        XCTAssertFalse(model(.allTime).canGoForward)
    }

    func testSwitchingKindKeepsThePlace() {
        let m = model(.year(2023))
        m.select(kind: .month)
        XCTAssertEqual(m.period, .month(year: 2023, month: 12))
        m.select(kind: .week)
        XCTAssertEqual(m.period, .week(LocalDay(year: 2023, month: 12, day: 31)))
        m.select(kind: .allTime)
        m.select(kind: .year)
        XCTAssertEqual(m.period, .year(2025))
    }

    func testYearMenuKeepsTheKind() {
        let m = model(.month(year: 2024, month: 3))
        m.select(year: 2021)
        XCTAssertEqual(m.period, .month(year: 2021, month: 3))
        let all = model(.allTime)
        all.select(year: 2020)
        XCTAssertEqual(all.period, .year(2020))
        // A month that has not happened yet this year becomes this month.
        let late = model(.month(year: 2024, month: 12))
        late.select(year: 2025)
        XCTAssertEqual(late.period, .month(year: 2025, month: 11))
    }

    /// A period with no plays says what it had instead of "Nothing played".
    func testPeriodWithoutPlaysSaysWhatWasThere() {
        let when = "in October 2025"
        var podcasts = Stats(period: "month:2025-10")
        podcasts.podcasts.ms = 52 * 60_000
        podcasts.podcasts.topShows = [Stats.Item(name: "The Long Talk", artist: nil, ms: 40 * 60_000, listens: 2)]
        XCTAssertEqual(LinerNotesView.emptyPeriodTitle(podcasts, when), "Only podcasts in October 2025")
        XCTAssertEqual(LinerNotesView.emptyPeriodContents(podcasts),
                       "52 min of podcasts, mostly The Long Talk. Liner Notes counts music.")
        var short = Stats(period: "month:2025-10")
        short.music.ms = 20_000
        XCTAssertEqual(LinerNotesView.emptyPeriodTitle(short, when), "Only short plays in October 2025")
        XCTAssertEqual(LinerNotesView.emptyPeriodContents(short),
                       "Under a minute of songs stopped before 30 seconds. A song counts as a play from 30 seconds.")
        var both = short
        both.podcasts = podcasts.podcasts
        XCTAssertEqual(LinerNotesView.emptyPeriodTitle(both, when), "Only short plays and podcasts in October 2025")
        let nothing = Stats(period: "month:2025-10")
        XCTAssertEqual(LinerNotesView.emptyPeriodTitle(nothing, when), "Nothing played in October 2025")
        XCTAssertNil(LinerNotesView.emptyPeriodContents(nothing))
    }
}
