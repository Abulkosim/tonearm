import Foundation
import XCTest
@testable import Tonearm

/// Whether Spotify runs when AppKit's list of running apps loses track of it.
final class SeenProcessesTests: XCTestCase {
    private let spotify = SeenProcesses.Process(pid: 4242, path: "/Applications/Spotify.app/Contents/MacOS/Spotify")

    /// AppKit's list once came back empty while Spotify ran. A Spotify seen before, whose pid
    /// still runs its executable, still counts.
    func testSpotifyMissingFromTheListStillRuns() {
        let seen = SeenProcesses()
        XCTAssertTrue(seen.running(listed: [spotify], isLive: { _ in true }))
        XCTAssertTrue(seen.running(listed: [], isLive: { $0 == self.spotify }),
                      "a gap in AppKit's list counted as a quit")
    }

    /// A Spotify that quit is forgotten, even if AppKit lists it again later under a new pid.
    func testQuitSpotifyIsForgotten() {
        let seen = SeenProcesses()
        XCTAssertTrue(seen.running(listed: [spotify], isLive: { _ in true }))
        XCTAssertFalse(seen.running(listed: [], isLive: { _ in false }))
        XCTAssertFalse(seen.running(listed: [], isLive: { _ in true }), "a quit Spotify came back")
        let relaunched = SeenProcesses.Process(pid: 5000, path: spotify.path)
        XCTAssertTrue(seen.running(listed: [relaunched], isLive: { _ in false }), "AppKit's word counts")
    }

    /// Never seen, never running.
    func testNothingSeenIsNotRunning() {
        XCTAssertFalse(SeenProcesses().running(listed: [], isLive: { _ in true }))
    }

    /// `isLive` reads the process table: a running pid counts under its own executable only,
    /// and not once it has exited.
    func testIsLiveChecksThePidAndTheExecutable() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        XCTAssertTrue(SeenProcesses.isLive(.init(pid: pid, path: "/bin/sleep")))
        XCTAssertFalse(SeenProcesses.isLive(.init(pid: pid, path: "/Applications/Spotify.app/Contents/MacOS/Spotify")),
                       "a pid reused by another program counted as Spotify")
        sleeper.terminate()
        sleeper.waitUntilExit()
        XCTAssertFalse(SeenProcesses.isLive(.init(pid: pid, path: "/bin/sleep")), "a process that exited")
    }
}
