import AppKit
import XCTest
@testable import Tonearm

/// Stands in for Spotify. Reads wait until the test answers them, so a test can put a
/// notification or a quit between a read's start and its answer.
final class FakeBridge: SpotifyBridge {
    var running = true
    var installed = true
    private(set) var reads: [(Result<Playback, BridgeError>, Date) -> Void] = []
    private(set) var sent: [Command] = []
    private(set) var launches = 0

    override var isRunning: Bool { running }
    override var isInstalled: Bool { installed }

    override func fetch(_ done: @escaping (Result<Playback, BridgeError>, Date) -> Void) {
        reads.append(done)
    }

    override func send(_ command: Command, then done: (() -> Void)? = nil) {
        sent.append(command)
        done?()
    }

    override func launch(activate: Bool = false, _ done: @escaping (Bool) -> Void) {
        launches += 1
    }

    /// Answers read number `i` (0 is the first since the model started).
    func answer(_ i: Int, _ result: Result<Playback, BridgeError>) {
        reads[i](result, Date())
    }
}

@MainActor
final class PlayerModelTests: XCTestCase {
    private let song = Track(id: "spotify:track:a", title: "A", artist: "Artist", album: "Album",
                             artworkURL: nil, duration: 200)

    private func settings() -> AppSettings {
        let suite = "tonearm.tests.player-model"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    private func playback(_ state: PlayState, position: Double = 10) -> Playback {
        Playback(state: state, track: song, position: position, volume: 50)
    }

    private func readyModel(_ bridge: FakeBridge, state: PlayState = .paused) -> PlayerModel {
        let model = PlayerModel(bridge: bridge, settings: settings(), mode: .test)
        XCTAssertEqual(bridge.reads.count, 1, "the model reads once at start")
        bridge.answer(0, .success(playback(state)))
        XCTAssertEqual(model.status, .ready)
        return model
    }

    /// A read samples Spotify, then a notification reports a newer state, then the read's
    /// answer arrives. The answer is older than the notification and must not undo it
    /// (it did: the player and the menu bar showed paused while Spotify played).
    func testReadStartedBeforeANotificationDoesNotUndoIt() {
        let bridge = FakeBridge()
        let model = readyModel(bridge)
        model.refresh()
        XCTAssertEqual(bridge.reads.count, 2)

        model.notificationArrived(NowPlayingUpdate(state: .playing, track: song, position: 10))
        XCTAssertEqual(model.playback.state, .playing)

        bridge.answer(1, .success(playback(.paused)))
        XCTAssertEqual(model.playback.state, .playing, "a read older than the notification was applied")
        XCTAssertEqual(bridge.reads.count, 3, "the dropped read is read again")
        bridge.answer(2, .success(playback(.playing, position: 11)))
        XCTAssertEqual(model.playback.state, .playing)
    }

    /// Spotify quits and starts again while a read is under way. The answer, from the old
    /// Spotify, is dropped and the new one is read.
    func testReadFromASpotifyThatQuitIsDropped() {
        let bridge = FakeBridge()
        let model = readyModel(bridge, state: .playing)
        model.refresh()
        bridge.running = false
        model.spotifyTerminated()
        XCTAssertEqual(model.status, .notRunning)
        bridge.running = true
        model.spotifyLaunched()

        bridge.answer(1, .success(playback(.playing)))
        XCTAssertEqual(model.status, .notRunning, "a read from the Spotify that quit counted as the new one")
        XCTAssertNil(model.track)
        XCTAssertEqual(bridge.reads.count, 3, "the new Spotify is read")
        bridge.answer(2, .success(playback(.paused)))
        XCTAssertEqual(model.status, .ready)
    }

    /// "Starting Spotify…" stays only while Spotify may still come up. It stayed for 20 s
    /// after Spotify quit during its start.
    func testLaunchEndsWhenSpotifyQuitsWhileStarting() {
        let bridge = FakeBridge()
        bridge.running = false
        let model = PlayerModel(bridge: bridge, settings: settings(), mode: .test)
        model.openSpotify()
        XCTAssertEqual(bridge.launches, 1)
        XCTAssertTrue(model.isLaunching)

        bridge.running = true
        model.spotifyLaunched()
        XCTAssertTrue(model.isLaunching, "still starting")
        bridge.running = false
        model.spotifyTerminated()
        XCTAssertFalse(model.isLaunching, "shows Starting Spotify after Spotify quit")
        XCTAssertEqual(model.status, .notRunning)
    }

    /// A local command makes an older read stale too.
    func testReadStartedBeforeACommandIsDroppedAndReadAgain() {
        let bridge = FakeBridge()
        let model = readyModel(bridge)
        model.refresh()
        model.playPause()
        XCTAssertEqual(bridge.sent, [.playPause])
        XCTAssertEqual(model.playback.state, .playing)
        bridge.answer(1, .success(playback(.paused)))
        XCTAssertEqual(model.playback.state, .playing)
    }

    /// Polling follows the state: none while paused with the player closed, the slow rate
    /// while playing, the fast one while the player is open.
    func testPollingFollowsState() {
        let bridge = FakeBridge()
        let model = readyModel(bridge)
        XCTAssertNil(model.pollTimerForTesting, "a paused player with the window closed is never read")
        model.notificationArrived(NowPlayingUpdate(state: .playing, track: song, position: 10))
        XCTAssertEqual(model.pollTimerForTesting?.timeInterval, PollPolicy.closedPlaying)
        model.popoverVisible = true
        XCTAssertEqual(model.pollTimerForTesting?.timeInterval, PollPolicy.openPlaying)
        model.popoverVisible = false
        XCTAssertEqual(model.pollTimerForTesting?.timeInterval, PollPolicy.closedPlaying)
        bridge.running = false
        model.spotifyTerminated()
        XCTAssertNil(model.pollTimerForTesting, "no reads while Spotify is not running")
    }

    /// The poll timer holds only its block. It kept firing, every 30 s, after its model was gone.
    func testPollTimerEndsWithItsModel() {
        let bridge = FakeBridge()
        var model: PlayerModel? = readyModel(bridge, state: .playing)
        guard let timer = model?.pollTimerForTesting else { return XCTFail("no poll timer while playing") }
        model = nil
        timer.fire()
        XCTAssertFalse(timer.isValid, "the timer outlived its model")
    }

    /// Previews (snapshots, the state walk, most tests) never reach Spotify. They did: running
    /// the tests on a Mac with Spotify open sought and changed its volume.
    func testPreviewSendsNothing() {
        let bridge = FakeBridge()
        let model = PlayerModel(bridge: bridge, settings: settings(), live: false)
        model.setPreview(playback(.paused), artwork: nil)
        model.playPause()
        model.next()
        model.previous()
        model.seek(to: 50)
        model.setVolume(20)
        model.toggleShuffle()
        model.toggleRepeat()
        model.refresh()
        XCTAssertEqual(bridge.sent, [])
        XCTAssertEqual(bridge.reads.count, 0)
        XCTAssertEqual(bridge.launches, 0)
        XCTAssertEqual(model.playback.volume, 20, "the preview still shows the change")
    }

    /// Spotify quitting leaves nothing behind from the last song.
    func testQuitClearsTheSong() {
        let bridge = FakeBridge()
        let model = readyModel(bridge, state: .playing)
        XCTAssertNotNil(model.track)
        bridge.running = false
        model.spotifyTerminated()
        XCTAssertNil(model.track)
        XCTAssertEqual(model.playback.state, .stopped)
        XCTAssertFalse(model.spotifyRunning)
        model.playPause()
        XCTAssertEqual(bridge.sent, [], "a command reached a Spotify that is not running")
    }
}
