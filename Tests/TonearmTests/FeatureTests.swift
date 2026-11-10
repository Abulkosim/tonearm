import AppKit
import XCTest
@testable import Tonearm

final class SpotifyLinkTests: XCTestCase {
    func testTrackAndEpisode() {
        XCTAssertEqual(SpotifyLink.webURL(for: "spotify:track:4uLU6hMCjMI75M1A2tKUQC"),
                       URL(string: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"))
        XCTAssertEqual(SpotifyLink.webURL(for: "spotify:episode:512ojhOuo1ktJprKbVcKyQ"),
                       URL(string: "https://open.spotify.com/episode/512ojhOuo1ktJprKbVcKyQ"))
    }

    func testAlreadyAWebLink() {
        let link = "https://open.spotify.com/track/abc"
        XCTAssertEqual(SpotifyLink.webURL(for: link), URL(string: link))
    }

    func testNoLinkForLocalFilesAdsAndJunk() {
        XCTAssertNil(SpotifyLink.webURL(for: "spotify:local:Artist:Album:Title:215"))
        XCTAssertNil(SpotifyLink.webURL(for: "spotify:ad:000000012c8d9e2a"))
        XCTAssertNil(SpotifyLink.webURL(for: ""))
        XCTAssertNil(SpotifyLink.webURL(for: "sample"))
        XCTAssertNil(SpotifyLink.webURL(for: "spotify:track:"))
        XCTAssertNil(SpotifyLink.webURL(for: "spotify:track:a/b"))
        XCTAssertNil(SpotifyLink.webURL(for: "spotify:track:абв"))
        XCTAssertNil(SpotifyLink.webURL(for: "spotify:track:abc:extra"))
    }

    func testArtworkURL() {
        XCTAssertEqual(SpotifyLink.artworkURL("https://i.scdn.co/image/a"), URL(string: "https://i.scdn.co/image/a"))
        XCTAssertEqual(SpotifyLink.artworkURL("http://i.scdn.co/image/a"), URL(string: "https://i.scdn.co/image/a"))
        XCTAssertNil(SpotifyLink.artworkURL(""))
        XCTAssertNil(SpotifyLink.artworkURL("spotify:localfileimage:%2FUsers%2Fa.mp3"))
        XCTAssertNil(SpotifyLink.artworkURL("file:///tmp/a.jpg"))
    }
}

final class PlayerMathTests: XCTestCase {
    func testClampPosition() {
        XCTAssertEqual(PlayerMath.clampPosition(-5, duration: 100), 0)
        XCTAssertEqual(PlayerMath.clampPosition(50, duration: 100), 50)
        XCTAssertEqual(PlayerMath.clampPosition(150, duration: 100), 100)
        // Unknown duration (ads, some streams): no upper bound.
        XCTAssertEqual(PlayerMath.clampPosition(150, duration: 0), 150)
        XCTAssertEqual(PlayerMath.clampPosition(.nan, duration: 100), 0)
        XCTAssertEqual(PlayerMath.clampPosition(.infinity, duration: 100), 0)
    }

    func testVolumeReadBackOneLowerIsIgnored() {
        XCTAssertEqual(PlayerMath.volumeToShow(reported: 49, local: 50, lastSent: 50), 50)
        XCTAssertEqual(PlayerMath.volumeToShow(reported: 51, local: 50, lastSent: 50), 50)
        // A real change made in Spotify wins.
        XCTAssertEqual(PlayerMath.volumeToShow(reported: 30, local: 50, lastSent: 50), 30)
        XCTAssertEqual(PlayerMath.volumeToShow(reported: 49, local: 50, lastSent: nil), 49)
        XCTAssertEqual(PlayerMath.volumeToShow(reported: 140, local: 50, lastSent: nil), 100)
    }
}

final class TrackNotifierTests: XCTestCase {
    private func track(_ id: String, title: String = "Song") -> Track {
        Track(id: id, title: title, artist: "Artist", album: "Album", artworkURL: nil, duration: 200)
    }

    func testDecision() {
        let t = track("spotify:track:b")
        XCTAssertTrue(TrackNotifier.shouldNotify(previousID: "spotify:track:a", track: t, enabled: true,
                                                 popoverVisible: false))
        // First song after launch.
        XCTAssertFalse(TrackNotifier.shouldNotify(previousID: nil, track: t, enabled: true, popoverVisible: false))
        XCTAssertFalse(TrackNotifier.shouldNotify(previousID: "spotify:track:a", track: t, enabled: false,
                                                  popoverVisible: false))
        XCTAssertFalse(TrackNotifier.shouldNotify(previousID: "spotify:track:a", track: t, enabled: true,
                                                  popoverVisible: true))
        XCTAssertFalse(TrackNotifier.shouldNotify(previousID: "spotify:track:b", track: t, enabled: true,
                                                  popoverVisible: false))
        XCTAssertFalse(TrackNotifier.shouldNotify(previousID: "spotify:track:a", track: track("spotify:ad:1"),
                                                  enabled: true, popoverVisible: false))
        XCTAssertFalse(TrackNotifier.shouldNotify(previousID: "spotify:track:a", track: nil, enabled: true,
                                                  popoverVisible: false))
    }

    func testBody() {
        XCTAssertEqual(TrackNotifier.body(for: track("x")), "Artist — Album")
        var podcast = track("spotify:episode:e")
        podcast.artist = ""
        podcast.album = "Show"
        XCTAssertEqual(TrackNotifier.body(for: podcast), "Show")
    }

    func testNotAvailableOutsideAnAppBundle() {
        // `swift test` runs inside xctest, not Tonearm.app.
        XCTAssertFalse(TrackNotifier.isAvailable)
    }

    func testBlockedOnlyWhenWantedAndDenied() {
        XCTAssertTrue(TrackNotifier.isBlocked(settingOn: true, authorization: .denied))
        XCTAssertFalse(TrackNotifier.isBlocked(settingOn: false, authorization: .denied))
        XCTAssertFalse(TrackNotifier.isBlocked(settingOn: true, authorization: .allowed))
        XCTAssertFalse(TrackNotifier.isBlocked(settingOn: true, authorization: .notDetermined))
        XCTAssertFalse(TrackNotifier.isBlocked(settingOn: true, authorization: .unavailable))
    }

    @MainActor
    func testAuthorizationOutsideAnAppBundle() {
        var answer: TrackNotifier.Authorization?
        TrackNotifier.authorization { answer = $0 }
        // Outside an app bundle it answers at once, without touching UNUserNotificationCenter.
        XCTAssertEqual(answer, .unavailable)
    }
}

final class SettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "tonearm.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaults() {
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.layout, .large)
        XCTAssertFalse(s.globalShortcuts)
        XCTAssertFalse(s.notifyOnTrackChange)
    }

    func testPersists() {
        let s = AppSettings(defaults: defaults)
        s.layout = .compact
        s.globalShortcuts = true
        s.notifyOnTrackChange = true
        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.layout, .compact)
        XCTAssertTrue(again.globalShortcuts)
        XCTAssertTrue(again.notifyOnTrackChange)
    }

    func testShorterDefaultTitleLength() {
        XCTAssertEqual(AppSettings.defaultTitleLength, 24)
        XCTAssertEqual(AppSettings(defaults: defaults).maxTitleLength, 24)
        XCTAssertTrue(AppSettings.titleLengthRange.contains(AppSettings.defaultTitleLength))
    }

    func testStoredTitleLengthIsKept() {
        defaults.set(30, forKey: "maxTitleLength")
        XCTAssertEqual(AppSettings(defaults: defaults).maxTitleLength, 30)
    }

    func testUnknownLayoutFallsBack() {
        defaults.set("huge", forKey: "layout")
        XCTAssertEqual(AppSettings(defaults: defaults).layout, .large)
    }
}

@MainActor
final class MenuBarTitleTests: XCTestCase {
    func testCyrillicAndWhitespace() {
        XCTAssertEqual(MenuBarLabel.title("Группа\nкрови ", artist: "Кино", showArtist: true, maxLength: 60),
                       "Группа крови · Кино")
        XCTAssertEqual(MenuBarLabel.shorten("Звезда по имени Солнце", to: 10), "Звезда по…")
    }

    func testHotKeysAreDistinct() {
        let codes = HotKeys.Action.allCases.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(Set(HotKeys.Action.allCases.map(\.keys)).count, codes.count)
    }

    func testHotKeysAvoidInputSourceSwitching() {
        // ⌃⌥Space switches input sources on Macs with more than one keyboard layout.
        XCTAssertFalse(HotKeys.Action.allCases.map(\.keyCode).contains(49))
        XCTAssertEqual(HotKeys.Action.playPause.keys, "⌃⌥P")
        XCTAssertEqual(HotKeys.Action.next.keys, "⌃⌥N")
        XCTAssertEqual(HotKeys.Action.previous.keys, "⌃⌥B")
        XCTAssertEqual(HotKeys.Action.playPause.keyCode, 0x23)
        XCTAssertEqual(HotKeys.Action.next.keyCode, 0x2D)
        XCTAssertEqual(HotKeys.Action.previous.keyCode, 0x0B)
    }
}

final class PollPolicyTests: XCTestCase {
    private func interval(running: Bool = true, open: Bool, playing: Bool, ready: Bool = true) -> TimeInterval? {
        PollPolicy.interval(spotifyRunning: running, windowOpen: open, playing: playing, ready: ready)
    }

    func testWindowOpen() {
        XCTAssertEqual(interval(open: true, playing: true), 2)
        XCTAssertEqual(interval(open: true, playing: false), 5)
        // Not answering yet (starting, no permission): check now and then.
        XCTAssertEqual(interval(open: true, playing: true, ready: false), 5)
    }

    func testWindowClosed() {
        // Spotify's notification keeps the label current; paused Spotify is never polled.
        XCTAssertNil(interval(open: false, playing: false))
        XCTAssertNil(interval(open: false, playing: true, ready: false))
        XCTAssertEqual(interval(open: false, playing: true), 30)
    }

    func testNoPollingWithoutSpotify() {
        XCTAssertNil(interval(running: false, open: true, playing: true))
        XCTAssertNil(interval(running: false, open: false, playing: true))
    }

    func testQuietPeriod() {
        let now = Date(timeIntervalSinceReferenceDate: 500)
        let earlier = now.addingTimeInterval(1)
        XCTAssertEqual(PollPolicy.quietUntil(after: .paused, now: now, current: .distantPast),
                       now.addingTimeInterval(PollPolicy.quietPeriod))
        XCTAssertEqual(PollPolicy.quietUntil(after: .stopped, now: now, current: .distantPast),
                       now.addingTimeInterval(PollPolicy.quietPeriod))
        XCTAssertEqual(PollPolicy.quietUntil(after: .playing, now: now, current: earlier), .distantPast)
        XCTAssertEqual(PollPolicy.quietUntil(after: nil, now: now, current: earlier), earlier)
        XCTAssertGreaterThanOrEqual(PollPolicy.quietPeriod, 1.5)
    }
}

final class PopoverWindowTests: XCTestCase {
    private func isPopover(_ name: String, _ bundle: String?) -> Bool {
        PlayerModel.isPopoverWindow(className: name, classBundleID: bundle)
    }

    func testOnlySwiftUIsOwnWindow() {
        XCTAssertTrue(isPopover("SwiftUI.MenuBarExtraWindow", "com.apple.SwiftUI"))
        XCTAssertTrue(isPopover("MenuBarExtraWindow", nil))
        XCTAssertTrue(isPopover("SomePanel", "com.apple.SwiftUI"))
        // The status item, the welcome window, alerts and update windows.
        XCTAssertFalse(isPopover("NSStatusBarWindow", "com.apple.AppKit"))
        XCTAssertFalse(isPopover("Tonearm.WelcomeWindow", "io.github.abulkosim.tonearm"))
        XCTAssertFalse(isPopover("NSPanel", "com.apple.AppKit"))
        XCTAssertFalse(isPopover("SUUpdateAlertWindow", "org.sparkle-project.Sparkle"))
    }
}

/// Model commands on a preview model. Spotify is not running in tests, so nothing is sent.
@MainActor
final class PlayerModelCommandTests: XCTestCase {
    private func model(id: String = "spotify:track:abc", position: Double = 83, volume: Int = 70) -> PlayerModel {
        let m = PlayerModel(live: false)
        let t = Track(id: id, title: "Song", artist: "Artist", album: "Album", artworkURL: nil, duration: 214)
        m.setPreview(Playback(state: .paused, track: t, position: position, volume: volume), artwork: nil)
        return m
    }

    func testSeekByIsClamped() {
        let m = model()
        m.seek(by: 10)
        XCTAssertEqual(m.position(at: Date()), 93, accuracy: 0.01)
        m.seek(by: 1000)
        XCTAssertEqual(m.position(at: Date()), 214, accuracy: 0.01)
        m.seek(by: -1000)
        XCTAssertEqual(m.position(at: Date()), 0, accuracy: 0.01)
    }

    func testChangeVolumeIsClamped() {
        let m = model()
        m.changeVolume(by: 10)
        XCTAssertEqual(m.playback.volume, 80)
        m.changeVolume(by: 50)
        XCTAssertEqual(m.playback.volume, 100)
        m.changeVolume(by: -500)
        XCTAssertEqual(m.playback.volume, 0)
    }

    func testToggles() {
        let m = model()
        XCTAssertFalse(m.shuffling)
        m.toggleShuffle()
        XCTAssertTrue(m.shuffling)
        m.toggleRepeat()
        XCTAssertTrue(m.repeating)
        m.toggleRepeat()
        XCTAssertFalse(m.repeating)
    }

    func testAskingPermissionPreview() {
        let m = PlayerModel(live: false)
        XCTAssertFalse(m.isAskingPermission)
        m.setPreviewAskingPermission()
        XCTAssertTrue(m.isAskingPermission)
        XCTAssertEqual(m.status, .notAuthorized)
    }

    func testIdleStateForTheView() {
        let m = PlayerModel(live: false)
        XCTAssertFalse(m.spotifyRunning)
        XCTAssertFalse(m.notificationsDenied)
        XCTAssertNil(m.popoverWindow)
        // Not live: never launches anything.
        m.openSpotify()
        XCTAssertFalse(m.isLaunching)
    }

    func testTrackURL() {
        XCTAssertEqual(model().trackURL, URL(string: "https://open.spotify.com/track/abc"))
        XCTAssertNil(model(id: "spotify:local:a:b:c:1").trackURL)
        XCTAssertFalse(model(id: "spotify:local:a:b:c:1").copyTrackLink())
    }
}
