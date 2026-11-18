import AppKit
import XCTest
@testable import Tonearm

final class NotchTests: XCTestCase {
    // A 14-inch MacBook Pro: menu bar areas left and right of the camera housing.
    private let left = NSRect(x: 0, y: 1079, width: 662, height: 38)
    private let right = NSRect(x: 850, y: 1079, width: 662, height: 38)

    func testItemUnderTheNotchIsHidden() {
        XCTAssertTrue(Notch.hides(NSRect(x: 740, y: 1079, width: 30, height: 38), left: left, right: right))
    }

    func testItemBesideTheNotchIsVisible() {
        XCTAssertFalse(Notch.hides(NSRect(x: 900, y: 1079, width: 30, height: 38), left: left, right: right))
        XCTAssertFalse(Notch.hides(NSRect(x: 600, y: 1079, width: 30, height: 38), left: left, right: right))
    }

    func testScreenWithoutNotch() {
        XCTAssertFalse(Notch.hides(NSRect(x: 740, y: 1079, width: 30, height: 38), left: nil, right: nil))
    }
}

final class KeyCommandTests: XCTestCase {
    func testEscapeGoesBack() {
        XCTAssertEqual(KeyCommand.from(keyCode: 53, characters: "\u{1b}", modifiers: []), .back)
        XCTAssertNil(KeyCommand.from(keyCode: 53, characters: "\u{1b}", modifiers: [.command]))
    }

    func testLettersMatchOnCyrillicLayout() {
        // "ы" sits on the S key in the Russian layout.
        XCTAssertEqual(KeyCommand.from(keyCode: 1, characters: "ы", modifiers: []), .shuffle)
        XCTAssertEqual(KeyCommand.from(keyCode: 12, characters: "й", modifiers: [.command]), .quit)
    }

    func testQuitIsListedOnce() {
        // The Quit row in settings shows ⌘Q, so the shortcut list leaves it out.
        XCTAssertFalse(KeyCommand.help.contains { $0.keys == "⌘Q" })
    }
}

final class LengthStepperTests: XCTestCase {
    func testStepsSnapToMultiplesOfFour() {
        XCTAssertEqual(LengthStepper.stepped(24, up: true), 28)
        XCTAssertEqual(LengthStepper.stepped(24, up: false), 20)
        // A length stored by an older version lands on the grid.
        XCTAssertEqual(LengthStepper.stepped(30, up: true), 32)
        XCTAssertEqual(LengthStepper.stepped(30, up: false), 28)
    }

    func testStaysInRange() {
        XCTAssertEqual(LengthStepper.lowest, 16)
        XCTAssertEqual(LengthStepper.stepped(16, up: false), 16)
        XCTAssertEqual(LengthStepper.stepped(15, up: false), 16)
        XCTAssertEqual(LengthStepper.stepped(60, up: true), 60)
        XCTAssertEqual(LengthStepper.stepped(58, up: true), 60)
    }
}

/// The note that Tonearm keeps a record of what you play: once, and only for people who
/// updated. A new install reads it in the welcome window.
@MainActor
final class HistoryNoticeTests: XCTestCase {
    /// Runs `body` with empty defaults of its own, removed after.
    private func withDefaults(_ body: (UserDefaults) -> Void) throws {
        let suite = "tonearm.tests.notice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    func testShowsOnceAfterAnUpdate() throws {
        try withDefaults { defaults in
            let notice = HistoryNotice(defaults: defaults)
            notice.launched(firstLaunch: false)
            XCTAssertFalse(notice.isShowing)
            notice.playerOpened(recording: true)
            XCTAssertTrue(notice.isShowing)
            // The window may report the same opening twice.
            notice.playerOpened(recording: true)
            XCTAssertTrue(notice.isShowing)
            notice.playerClosed()
            XCTAssertFalse(notice.isShowing)
            notice.playerOpened(recording: true)
            XCTAssertFalse(notice.isShowing, "the second opening is quiet")
            // Nor after a relaunch.
            let relaunched = HistoryNotice(defaults: defaults)
            relaunched.launched(firstLaunch: false)
            relaunched.playerOpened(recording: true)
            XCTAssertFalse(relaunched.isShowing)
        }
    }

    func testDismissedStaysDismissed() throws {
        try withDefaults { defaults in
            let notice = HistoryNotice(defaults: defaults)
            notice.playerOpened(recording: true)
            notice.dismiss()
            XCTAssertFalse(notice.isShowing)
            notice.playerClosed()
            notice.playerOpened(recording: true)
            XCTAssertFalse(notice.isShowing)
        }
    }

    func testNewInstallHearsItInTheWelcomeWindow() throws {
        try withDefaults { defaults in
            let notice = HistoryNotice(defaults: defaults)
            notice.launched(firstLaunch: true)
            notice.playerOpened(recording: true)
            XCTAssertFalse(notice.isShowing)
        }
    }

    func testNothingToSayWhileRecordingIsOff() throws {
        try withDefaults { defaults in
            let notice = HistoryNotice(defaults: defaults)
            notice.playerOpened(recording: false)
            XCTAssertFalse(notice.isShowing)
            XCTAssertFalse(notice.seen, "still owed if recording comes back on")
        }
    }
}

