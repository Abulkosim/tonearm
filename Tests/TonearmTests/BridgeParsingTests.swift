import AppKit
import XCTest
@testable import Tonearm

final class ReplyParsingTests: XCTestCase {
    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let d = NSAppleEventDescriptor.list()
        for (i, item) in items.enumerated() { d.insert(item, at: i + 1) }
        return d
    }

    private func s(_ v: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: v) }

    func testFullReply() throws {
        let reply = list([
            s("playing"), NSAppleEventDescriptor(double: 83.25), NSAppleEventDescriptor(int32: 70),
            s("spotify:track:abc"), s("Song"), s("Artist"), s("Album"),
            s("https://i.scdn.co/image/xyz"), NSAppleEventDescriptor(int32: 214_000),
        ])
        let p = try SpotifyBridge.parse(reply).get()
        XCTAssertEqual(p.state, .playing)
        XCTAssertEqual(p.position, 83.25, accuracy: 0.001)
        XCTAssertEqual(p.volume, 70)
        XCTAssertEqual(p.track, Track(id: "spotify:track:abc", title: "Song", artist: "Artist", album: "Album",
                                      artworkURL: URL(string: "https://i.scdn.co/image/xyz"), duration: 214))
    }

    func testStoppedReplyHasNoTrack() throws {
        let reply = list([s("stopped"), NSAppleEventDescriptor(int32: 0), NSAppleEventDescriptor(int32: 42)])
        let p = try SpotifyBridge.parse(reply).get()
        XCTAssertEqual(p.state, .stopped)
        XCTAssertNil(p.track)
        XCTAssertEqual(p.volume, 42)
    }

    func testTextNumbersWithCommaDecimal() throws {
        let reply = list([s("paused"), s("12,5"), s("33")])
        let p = try SpotifyBridge.parse(reply).get()
        XCTAssertEqual(p.state, .paused)
        XCTAssertEqual(p.position, 12.5, accuracy: 0.001)
        XCTAssertEqual(p.volume, 33)
    }

    func testMissingArtworkURL() throws {
        let reply = list([
            s("paused"), NSAppleEventDescriptor(double: 1), NSAppleEventDescriptor(int32: 50),
            s("spotify:local:x"), s("Local"), s(""), s(""), s(""), NSAppleEventDescriptor(int32: 1000),
        ])
        let p = try SpotifyBridge.parse(reply).get()
        XCTAssertNil(p.track?.artworkURL)
        XCTAssertEqual(p.track?.duration ?? 0, 1, accuracy: 0.001)
    }

    func testNotRunningSentinel() {
        XCTAssertEqual(SpotifyBridge.parse(s(SpotifyBridge.notRunningReply)), .failure(.notRunning))
    }

    func testShortReplyIsError() {
        guard case .failure(.script) = SpotifyBridge.parse(list([s("playing")])) else {
            return XCTFail("expected script error")
        }
    }

    func testErrorCodes() {
        XCTAssertEqual(BridgeError.from(code: -1743, message: ""), .notAuthorized)
        XCTAssertEqual(BridgeError.from(code: -600, message: ""), .notRunning)
        XCTAssertEqual(BridgeError.from(code: -609, message: ""), .notRunning)
        XCTAssertEqual(BridgeError.from(code: -1728, message: "x"), .script(-1728, "x"))
        XCTAssertEqual(SpotifyBridge.Permission.from(0), .granted)
        XCTAssertEqual(SpotifyBridge.Permission.from(-1743), .denied)
        XCTAssertEqual(SpotifyBridge.Permission.from(-600), .notRunning)
    }

    func testCommandScriptsClampValues() {
        XCTAssertEqual(SpotifyBridge.Command.volume(140).appleScript, "set sound volume to 100")
        XCTAssertEqual(SpotifyBridge.Command.volume(-3).appleScript, "set sound volume to 0")
        XCTAssertEqual(SpotifyBridge.Command.seek(-1).appleScript, "set player position to 0.0")
        XCTAssertTrue(SpotifyBridge.source(for: .next).contains("is running"))
    }
}

final class NotificationParsingTests: XCTestCase {
    func testPlaying() {
        let info: [AnyHashable: Any] = [
            "Player State": "Playing", "Name": "Song", "Artist": "Artist", "Album": "Album",
            "Track ID": "spotify:track:abc", "Duration": NSNumber(value: 214_000),
            "Playback Position": NSNumber(value: 12.5),
        ]
        let u = NowPlayingUpdate.parse(info)
        XCTAssertEqual(u?.state, .playing)
        XCTAssertEqual(u?.position, 12.5)
        XCTAssertEqual(u?.track, Track(id: "spotify:track:abc", title: "Song", artist: "Artist",
                                       album: "Album", artworkURL: nil, duration: 214))
    }

    func testPausedWithIntPosition() {
        let info: [AnyHashable: Any] = [
            "Player State": "Paused", "Track ID": "spotify:track:abc", "Duration": 1000, "Playback Position": 3,
        ]
        let u = NowPlayingUpdate.parse(info)
        XCTAssertEqual(u?.state, .paused)
        XCTAssertEqual(u?.position, 3)
        XCTAssertEqual(u?.track?.duration, 1)
        XCTAssertEqual(u?.track?.title, "")
    }

    func testStoppedDropsTrack() {
        let u = NowPlayingUpdate.parse(["Player State": "Stopped", "Track ID": "spotify:track:abc"])
        XCTAssertEqual(u, NowPlayingUpdate(state: .stopped, track: nil, position: nil))
    }

    func testGarbage() {
        XCTAssertNil(NowPlayingUpdate.parse([:]))
        XCTAssertNil(NowPlayingUpdate.parse(["Player State": "Rewinding"]))
    }
}
