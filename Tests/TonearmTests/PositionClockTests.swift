import XCTest
@testable import Tonearm

final class PositionClockTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testAdvancesWhilePlaying() {
        let c = PositionClock(position: 10, date: t0, isPlaying: true, duration: 100)
        XCTAssertEqual(c.position(at: t0.addingTimeInterval(2.5)), 12.5, accuracy: 0.0001)
        // Never goes backwards for a time before the anchor.
        XCTAssertEqual(c.position(at: t0.addingTimeInterval(-5)), 10, accuracy: 0.0001)
    }

    func testClampsToDuration() {
        let c = PositionClock(position: 98, date: t0, isPlaying: true, duration: 100)
        XCTAssertEqual(c.position(at: t0.addingTimeInterval(10)), 100)
        let unknown = PositionClock(position: 98, date: t0, isPlaying: true, duration: 0)
        XCTAssertEqual(unknown.position(at: t0.addingTimeInterval(10)), 108, accuracy: 0.0001)
    }

    func testPausedStaysPut() {
        let c = PositionClock(position: 10, date: t0, isPlaying: false, duration: 100)
        XCTAssertEqual(c.position(at: t0.addingTimeInterval(30)), 10)
    }

    func testSmallBackwardCorrectionIgnored() {
        let c = PositionClock(position: 10, date: t0, isPlaying: true, duration: 100)
        let t = t0.addingTimeInterval(2) // local says 12.0
        let r = c.reconciled(reported: 11.6, at: t, isPlaying: true, tolerance: 0.75)
        XCTAssertEqual(r, c)
    }

    func testLargeCorrectionApplied() {
        let c = PositionClock(position: 10, date: t0, isPlaying: true, duration: 100)
        let t = t0.addingTimeInterval(2)
        let r = c.reconciled(reported: 40, at: t, isPlaying: true, tolerance: 0.75)
        XCTAssertEqual(r.position(at: t), 40, accuracy: 0.0001)
        XCTAssertEqual(r.position(at: t.addingTimeInterval(1)), 41, accuracy: 0.0001)
    }

    func testPauseReanchors() {
        let c = PositionClock(position: 10, date: t0, isPlaying: true, duration: 100)
        let t = t0.addingTimeInterval(5)
        let r = c.reconciled(reported: 15.2, at: t, isPlaying: false, tolerance: 0.75)
        XCTAssertFalse(r.isPlaying)
        XCTAssertEqual(r.position(at: t.addingTimeInterval(10)), 15, accuracy: 0.0001)
    }

    func testHoldKeepsLocalPlayhead() {
        let c = PositionClock(position: 60, date: t0, isPlaying: true, duration: 100)
        let t = t0.addingTimeInterval(0.5)
        let r = c.reconciled(reported: 10, at: t, isPlaying: true, tolerance: .infinity)
        XCTAssertEqual(r, c)
    }
}
