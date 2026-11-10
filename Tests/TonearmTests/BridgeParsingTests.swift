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
    private func b(_ v: Bool) -> NSAppleEventDescriptor { NSAppleEventDescriptor(boolean: v) }
    private func n(_ v: Double) -> NSAppleEventDescriptor { NSAppleEventDescriptor(double: v) }
    private func i(_ v: Int32) -> NSAppleEventDescriptor { NSAppleEventDescriptor(int32: v) }

    /// A reply in the layout of `SpotifyBridge.readSource`.
    private func reply(state: String = "playing", position: NSAppleEventDescriptor? = nil, volume: Int32 = 70,
                       shuffling: Bool = false, repeating: Bool = false,
                       track: [NSAppleEventDescriptor]? = nil) -> NSAppleEventDescriptor {
        list([s(state), position ?? n(83.25), i(volume), b(shuffling), b(repeating)] + (track ?? []))
    }

    func testFullReply() throws {
        let r = reply(shuffling: true, repeating: false, track: [
            s("spotify:track:abc"), s("Song"), s("Artist"), s("Album"),
            s("https://i.scdn.co/image/xyz"), i(214_000),
        ])
        let p = try SpotifyBridge.parse(r).get()
        XCTAssertEqual(p.state, .playing)
        XCTAssertEqual(p.position, 83.25, accuracy: 0.001)
        XCTAssertEqual(p.volume, 70)
        XCTAssertTrue(p.shuffling)
        XCTAssertFalse(p.repeating)
        XCTAssertEqual(p.track, Track(id: "spotify:track:abc", title: "Song", artist: "Artist", album: "Album",
                                      artworkURL: URL(string: "https://i.scdn.co/image/xyz"), duration: 214))
    }

    func testStoppedReplyHasNoTrack() throws {
        let p = try SpotifyBridge.parse(reply(state: "stopped", position: i(0), volume: 42, repeating: true)).get()
        XCTAssertEqual(p.state, .stopped)
        XCTAssertNil(p.track)
        XCTAssertEqual(p.volume, 42)
        XCTAssertTrue(p.repeating)
    }

    func testTextNumbersWithCommaDecimal() throws {
        let p = try SpotifyBridge.parse(list([s("paused"), s("12,5"), s("33"), b(false), b(false)])).get()
        XCTAssertEqual(p.state, .paused)
        XCTAssertEqual(p.position, 12.5, accuracy: 0.001)
        XCTAssertEqual(p.volume, 33)
    }

    func testLocalFileWithMissingValues() throws {
        // Local files have no artwork; Spotify may answer `missing value` (typeNull here).
        let r = reply(state: "paused", position: n(1), track: [
            s("spotify:local:Artist:Album:Title:200"), s("Title"), s(""), s(""),
            NSAppleEventDescriptor.null(), i(1000),
        ])
        let p = try SpotifyBridge.parse(r).get()
        XCTAssertEqual(p.track?.title, "Title")
        XCTAssertNil(p.track?.artworkURL)
        XCTAssertEqual(p.track?.duration ?? 0, 1, accuracy: 0.001)
    }

    func testAdWithZeroDuration() throws {
        let r = reply(track: [s("spotify:ad:000000012c8d9e2a"), s("Advertisement"), s(""), s(""), s(""), i(0)])
        let p = try SpotifyBridge.parse(r).get()
        XCTAssertEqual(p.track?.duration, 0)
        XCTAssertNil(p.track?.artworkURL)
    }

    func testEmptyTrackIsNoTrack() throws {
        let r = reply(state: "paused", track: [s(""), s(""), s(""), s(""), s(""), i(0)])
        XCTAssertNil(try SpotifyBridge.parse(r).get().track)
    }

    func testNonEnglishText() throws {
        let r = reply(track: [
            s("spotify:track:abc"), s("Кино — Группа крови"), s("Кино"), s("Группа крови"),
            s("http://i.scdn.co/image/xyz"), i(285_000),
        ])
        let t = try XCTUnwrap(SpotifyBridge.parse(r).get().track)
        XCTAssertEqual(t.title, "Кино — Группа крови")
        XCTAssertEqual(t.artist, "Кино")
        // Plain http artwork is upgraded, since App Transport Security blocks it.
        XCTAssertEqual(t.artworkURL, URL(string: "https://i.scdn.co/image/xyz"))
    }

    func testOddValuesAreClamped() throws {
        let p = try SpotifyBridge.parse(list([s("Playing"), n(-3), i(140), b(false), b(false)])).get()
        XCTAssertEqual(p.state, .playing)
        XCTAssertEqual(p.position, 0)
        XCTAssertEqual(p.volume, 100)
    }

    func testNotRunningSentinel() {
        XCTAssertEqual(SpotifyBridge.parse(s(SpotifyBridge.notRunningReply)), .failure(.notRunning))
    }

    func testShortReplyIsError() {
        guard case .failure(.script) = SpotifyBridge.parse(list([s("playing"), n(1), i(50)])) else {
            return XCTFail("expected script error")
        }
    }

    func testReadScriptShape() {
        let src = SpotifyBridge.readSource
        XCTAssertTrue(src.hasPrefix("if application id \"com.spotify.client\" is not running"))
        XCTAssertTrue(src.contains("set sh to shuffling"))
        XCTAssertTrue(src.contains("set rp to repeating"))
        XCTAssertTrue(src.contains("set tu to artwork url of t"))
        XCTAssertTrue(src.contains("if n is in {-1712, -1743, -1744, -600, -609, -903} then error number n"))
        XCTAssertTrue(src.contains("return {s, p, v, sh, rp, tid, tn, ta, tal, tu, td}"))
        XCTAssertFalse(src.contains("\\("))
    }

    func testErrorCodes() {
        XCTAssertEqual(BridgeError.from(code: -1743, message: ""), .notAuthorized)
        XCTAssertEqual(BridgeError.from(code: -600, message: ""), .notRunning)
        XCTAssertEqual(BridgeError.from(code: -609, message: ""), .notRunning)
        XCTAssertEqual(BridgeError.from(code: -1728, message: "x"), .script(-1728, "x"))
        XCTAssertEqual(SpotifyBridge.Permission.from(0), .granted)
        XCTAssertEqual(SpotifyBridge.Permission.from(-1743), .denied)
        XCTAssertEqual(SpotifyBridge.Permission.from(-600), .notRunning)
        XCTAssertEqual(SpotifyBridge.Permission.from(-1744), .needsConsent)
    }

    func testCommandScriptsClampValues() {
        XCTAssertEqual(SpotifyBridge.Command.volume(140).appleScript, "set sound volume to 100")
        XCTAssertEqual(SpotifyBridge.Command.volume(-3).appleScript, "set sound volume to 0")
        XCTAssertEqual(SpotifyBridge.Command.seek(-1).appleScript, "set player position to 0.00")
        XCTAssertEqual(SpotifyBridge.Command.seek(83.256).appleScript, "set player position to 83.26")
        XCTAssertEqual(SpotifyBridge.Command.seek(0.000001).appleScript, "set player position to 0.00")
        XCTAssertEqual(SpotifyBridge.Command.seek(.nan).appleScript, "set player position to 0.00")
        XCTAssertEqual(SpotifyBridge.Command.shuffle(true).appleScript, "set shuffling to true")
        XCTAssertEqual(SpotifyBridge.Command.repeating(false).appleScript, "set repeating to false")
        XCTAssertTrue(SpotifyBridge.source(for: .next).contains("is running"))
    }

    func testSeekUsesDotInCommaLocales() {
        // String(format:) without a locale must not follow the user's decimal comma.
        let old = setlocale(LC_NUMERIC, nil).map { String(cString: $0) }
        setlocale(LC_NUMERIC, "de_DE")
        defer { setlocale(LC_NUMERIC, old ?? "C") }
        XCTAssertEqual(SpotifyBridge.Command.seek(12.5).appleScript, "set player position to 12.50")
    }

    func testParseNumber() {
        XCTAssertEqual(parseNumber("12.5"), 12.5)
        XCTAssertEqual(parseNumber("12,5"), 12.5)
        XCTAssertEqual(parseNumber(" 7 "), 7)
        XCTAssertNil(parseNumber("abc"))
        XCTAssertNil(parseNumber("inf"))
        XCTAssertNil(parseNumber("nan"))
        XCTAssertNil(parseNumber(""))
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

    func testNoTrackLoaded() {
        let u = NowPlayingUpdate.parse(["Player State": "Paused", "Track ID": "", "Name": ""])
        XCTAssertEqual(u?.state, .paused)
        XCTAssertNil(u?.track)
    }

    func testTextPositionWithComma() {
        let u = NowPlayingUpdate.parse(["Player State": "Playing", "Track ID": "spotify:episode:e1",
                                        "Name": "Выпуск 12", "Playback Position": "42,5", "Duration": "-5"])
        XCTAssertEqual(u?.position, 42.5)
        XCTAssertEqual(u?.track?.title, "Выпуск 12")
        XCTAssertEqual(u?.track?.duration, 0)
    }

    func testGarbage() {
        XCTAssertNil(NowPlayingUpdate.parse([:]))
        XCTAssertNil(NowPlayingUpdate.parse(["Player State": "Rewinding"]))
    }
}
