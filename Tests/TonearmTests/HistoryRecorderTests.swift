import XCTest
@testable import Tonearm

/// Simulated playback timelines. `t(s)` is a time s seconds in.
final class HistoryRecorderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private func song(_ id: String = "spotify:track:a", duration: Double = 200) -> Track {
        Track(id: id, title: "Song \(id.suffix(1))", artist: "Artist", album: "Album", artworkURL: nil,
              duration: duration)
    }

    private func seconds(_ l: LiveListen?) -> Double { Double(l?.msPlayed ?? 0) / 1000 }

    func testPlaysThroughWithSlowPollsThenNextTrack() {
        var r = ListenTracker()
        let a = song(), b = song("spotify:track:b")
        XCTAssertTrue(r.observe(track: a, playing: true, position: 0, at: t(0)).isEmpty)
        for s in stride(from: 30.0, through: 180, by: 30) {
            XCTAssertTrue(r.observe(track: a, playing: true, position: s, at: t(s)).isEmpty)
        }
        // Spotify announces the next track 3 s after it started (200 s track).
        let closed = r.observe(track: b, playing: true, position: 3, at: t(203))
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(seconds(closed.first), 200, accuracy: 0.01)
        XCTAssertEqual(closed.first?.startedAt, t(0))
        XCTAssertEqual(closed.first?.endedAt, t(200))
        XCTAssertEqual(seconds(r.current), 3, accuracy: 0.01)
        XCTAssertEqual(r.current?.startedAt, t(200))
    }

    func testPauseDoesNotCount() {
        var r = ListenTracker()
        let a = song()
        _ = r.observe(track: a, playing: true, position: 0, at: t(0))
        _ = r.observe(track: a, playing: false, position: 50, at: t(50))
        // Ten minutes paused, polled now and then.
        _ = r.observe(track: a, playing: false, position: 50, at: t(300))
        _ = r.observe(track: a, playing: true, position: 50, at: t(650))
        _ = r.observe(track: a, playing: true, position: 80, at: t(680))
        XCTAssertEqual(seconds(r.current), 80, accuracy: 0.01)
    }

    func testSeekForwardCountsOnlyWallClock() {
        var r = ListenTracker()
        let a = song(duration: 400)
        _ = r.observe(track: a, playing: true, position: 10, at: t(0))
        // Jumped from 12 to 200 two seconds in.
        _ = r.observe(track: a, playing: true, position: 200, at: t(2))
        _ = r.observe(track: a, playing: true, position: 210, at: t(12))
        XCTAssertEqual(seconds(r.current), 12, accuracy: 0.01)
    }

    func testSeekBackAddsNothingForThatStretch() {
        var r = ListenTracker()
        let a = song(duration: 400)
        _ = r.observe(track: a, playing: true, position: 100, at: t(0))
        _ = r.observe(track: a, playing: true, position: 102, at: t(2))
        _ = r.observe(track: a, playing: true, position: 40, at: t(4))  // seek back, not to the top
        _ = r.observe(track: a, playing: true, position: 50, at: t(14))
        XCTAssertEqual(seconds(r.current), 12, accuracy: 0.01)
        XCTAssertEqual(r.current?.startedAt, t(0))
    }

    func testPollingGapIsBoundedByPlayhead() {
        var r = ListenTracker()
        let a = song(duration: 3600)
        _ = r.observe(track: a, playing: true, position: 0, at: t(0))
        // Five minutes unseen, and the playhead moved one minute: paused in between.
        _ = r.observe(track: a, playing: true, position: 60, at: t(300))
        XCTAssertEqual(seconds(r.current), 60, accuracy: 0.01)
        // Five minutes unseen, playhead moved five minutes.
        _ = r.observe(track: a, playing: true, position: 360, at: t(600))
        XCTAssertEqual(seconds(r.current), 360, accuracy: 0.01)
    }

    func testSleepAndWake() {
        var r = ListenTracker()
        let a = song()
        _ = r.observe(track: a, playing: true, position: 50, at: t(0))
        // The Mac slept for two hours; Spotify stopped 5 s after the last look.
        _ = r.observe(track: a, playing: false, position: 55, at: t(7200))
        XCTAssertEqual(seconds(r.current), 5, accuracy: 0.01)
        // Woke and Spotify kept playing from 55: still bounded by the playhead.
        _ = r.observe(track: a, playing: true, position: 55, at: t(7201))
        _ = r.observe(track: a, playing: true, position: 65, at: t(7211))
        XCTAssertEqual(seconds(r.current), 15, accuracy: 0.01)
    }

    func testNextTrackAfterLongGapIsBoundedByRemainingAndCap() {
        var r = ListenTracker()
        let a = song(duration: 200), b = song("spotify:track:b")
        _ = r.observe(track: a, playing: true, position: 100, at: t(0))
        // Next seen an hour later: no more than the cap is credited for the unseen stretch.
        let closed = r.observe(track: b, playing: true, position: 10, at: t(3600))
        XCTAssertEqual(seconds(closed.first), ListenTracker.maxUnseen, accuracy: 0.01)
        // The new track is not credited for time nobody saw it play either.
        XCTAssertLessThanOrEqual(seconds(r.current), 10)
    }

    func testSkipMidTrack() {
        var r = ListenTracker()
        let a = song(), b = song("spotify:track:b")
        _ = r.observe(track: a, playing: true, position: 0, at: t(0))
        _ = r.observe(track: a, playing: true, position: 30, at: t(30))
        // Pressed next at 41 s; the notification arrives right away.
        let closed = r.observe(track: b, playing: true, position: 0.2, at: t(41.2))
        XCTAssertEqual(seconds(closed.first), 41, accuracy: 0.01)
    }

    func testTrackChangeWhilePausedAddsNoTail() {
        var r = ListenTracker()
        let a = song(), b = song("spotify:track:b")
        _ = r.observe(track: a, playing: true, position: 0, at: t(0))
        _ = r.observe(track: a, playing: false, position: 20, at: t(20))
        let closed = r.observe(track: b, playing: false, position: 0, at: t(500))
        XCTAssertEqual(seconds(closed.first), 20, accuracy: 0.01)
        XCTAssertEqual(seconds(r.current), 0, "nothing heard of b yet")
    }

    func testRepeatOne() {
        var r = ListenTracker()
        let a = song(duration: 60)
        _ = r.observe(track: a, playing: true, position: 0, at: t(0))
        _ = r.observe(track: a, playing: true, position: 30, at: t(30))
        // Back at the top: 60 s track, seen 10 s into the second play.
        let first = r.observe(track: a, playing: true, position: 10, at: t(70))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(seconds(first.first), 60, accuracy: 0.01)
        XCTAssertEqual(seconds(r.current), 10, accuracy: 0.01)
        XCTAssertEqual(r.current?.startedAt, t(60))
        XCTAssertNotEqual(first.first?.dedupKey, r.current?.dedupKey)
        // And again, with the popover open (2 s polls).
        _ = r.observe(track: a, playing: true, position: 58, at: t(118))
        let second = r.observe(track: a, playing: true, position: 1, at: t(121))
        XCTAssertEqual(seconds(second.first), 60, accuracy: 0.01)
    }

    func testSpotifyQuitsMidTrack() {
        var r = ListenTracker()
        let a = song()
        _ = r.observe(track: a, playing: true, position: 0, at: t(0))
        _ = r.observe(track: a, playing: true, position: 30, at: t(30))
        // Spotify was killed 10 s after the last look: the model reports no track.
        let closed = r.observe(track: nil, playing: false, position: 0, at: t(40))
        XCTAssertEqual(seconds(closed.first), 40, accuracy: 0.01)
        XCTAssertNil(r.current)
    }

    func testAppQuitsMidTrack() {
        var r = ListenTracker()
        let a = song()
        _ = r.observe(track: a, playing: true, position: 0, at: t(0))
        _ = r.observe(track: a, playing: true, position: 30, at: t(30))
        let closed = r.close(at: t(35))
        XCTAssertEqual(seconds(closed), 35, accuracy: 0.01)
        XCTAssertNil(r.current)
        // A later look starts fresh, with no credit for the time Tonearm was gone.
        _ = r.observe(track: a, playing: true, position: 150, at: t(150))
        XCTAssertEqual(seconds(r.current), 0)
    }

    func testAdsAreNeverRecorded() {
        var r = ListenTracker()
        let a = song(), ad = Track(id: "spotify:ad:0001", title: "Advertisement", artist: "", album: "",
                                   artworkURL: nil, duration: 30)
        _ = r.observe(track: a, playing: true, position: 190, at: t(0))
        let closed = r.observe(track: ad, playing: true, position: 2, at: t(12))
        XCTAssertEqual(seconds(closed.first), 10, accuracy: 0.01)
        XCTAssertNil(r.current)
        _ = r.observe(track: ad, playing: true, position: 28, at: t(38))
        let afterAd = r.observe(track: song("spotify:track:b"), playing: true, position: 1, at: t(41))
        XCTAssertTrue(afterAd.isEmpty, "the ad is not a listen")
        XCTAssertEqual(seconds(r.current), 1, accuracy: 0.01)
    }

    func testShortPlaysAreDropped() {
        var r = ListenTracker()
        _ = r.observe(track: song(), playing: true, position: 0, at: t(0))
        let closed = r.observe(track: song("spotify:track:b"), playing: true, position: 0, at: t(0.5))
        XCTAssertTrue(closed.isEmpty)
    }

    @MainActor
    func testRecorderWithSlowPollsSavesEveryLook() {
        let sink = Sink()
        let rec = PlayRecorder(sink: sink, isEnabled: { true })
        let a = song(duration: 600)
        for s in stride(from: 0.0, through: 300, by: 30) {
            rec.observe(track: a, playing: true, position: s, at: t(s))
        }
        XCTAssertEqual(sink.saved.count, 10)
        XCTAssertEqual(Double(sink.saved.last!.msPlayed) / 1000, 300, accuracy: 0.01, "nothing heard is unsaved")
    }

    func testPodcastKind() {
        var r = ListenTracker()
        _ = r.observe(track: song("spotify:episode:e"), playing: true, position: 0, at: t(0))
        XCTAssertEqual(r.current?.kind, .podcast)
    }

    @MainActor
    func testRecorderSavesEveryHalfMinuteAndStopsWhenTurnedOff() {
        let sink = Sink()
        var enabled = true
        let rec = PlayRecorder(sink: sink, isEnabled: { enabled })
        let a = song(duration: 600)
        for s in stride(from: 0.0, through: 120, by: 2) {
            rec.observe(track: a, playing: true, position: s, at: t(s))
        }
        // Saved about every 10 s: a crash would lose less than that.
        XCTAssertGreaterThanOrEqual(sink.saved.count, 11)
        XCTAssertLessThanOrEqual(sink.saved.count, 13)
        XCTAssertGreaterThanOrEqual(Double(sink.saved.last!.msPlayed) / 1000, 120 - PlayRecorder.saveInterval - 2)
        XCTAssertEqual(Set(sink.saved.map(\.dedupKey)).count, 1, "one row, updated in place")

        // Turned off at 125 s: the listen ends there, not at the next look.
        enabled = false
        rec.turnedOff(at: t(125))
        XCTAssertEqual(Double(sink.saved.last!.msPlayed) / 1000, 125, accuracy: 0.01)
        let count = sink.saved.count
        rec.observe(track: a, playing: true, position: 130, at: t(130))
        rec.observe(track: a, playing: true, position: 140, at: t(140))
        XCTAssertEqual(sink.saved.count, count, "nothing while off")
        XCTAssertEqual(sink.flushes, 0, "turning off never waits on the store")
        // Back on: a new listen, with no credit for the time it was off.
        enabled = true
        rec.observe(track: a, playing: true, position: 150, at: t(150))
        rec.observe(track: a, playing: true, position: 160, at: t(160))
        rec.quit(at: t(160))
        XCTAssertEqual(Double(sink.saved.last!.msPlayed) / 1000, 10, accuracy: 0.01)
        XCTAssertEqual(sink.flushes, 1)
    }

    /// When the setting goes off without `turnedOff` (not seen by the app's observer), the
    /// next look stops recording, credited up to that look.
    @MainActor
    func testRecorderStopsAtTheNextLookWhenOffUnseen() {
        let sink = Sink()
        var enabled = true
        let rec = PlayRecorder(sink: sink, isEnabled: { enabled })
        let a = song(duration: 600)
        for s in stride(from: 0.0, through: 60, by: 10) {
            rec.observe(track: a, playing: true, position: s, at: t(s))
        }
        enabled = false
        rec.observe(track: a, playing: true, position: 70, at: t(70))
        XCTAssertEqual(Double(sink.saved.last!.msPlayed) / 1000, 70, accuracy: 0.01)
        let count = sink.saved.count
        rec.observe(track: a, playing: true, position: 80, at: t(80))
        XCTAssertEqual(sink.saved.count, count)
    }

    /// The app's recorder stops the moment the setting goes off.
    @MainActor
    func testLiveRecorderStopsWhenTheSettingChanges() {
        let defaults = UserDefaults(suiteName: "tonearm-recorder-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.recordHistory = true
        let sink = Sink()
        let rec = PlayRecorder.live(settings: settings, sink: sink)
        let a = song(duration: 600)
        let now = Date()
        rec.observe(track: a, playing: true, position: 0, at: now.addingTimeInterval(-20))
        rec.observe(track: a, playing: true, position: 20, at: now)
        let before = sink.saved.count
        settings.recordHistory = false
        let closed = expectation(description: "listen closed")
        DispatchQueue.main.async { closed.fulfill() }
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(sink.saved.count, before + 1, "the open listen was closed and saved")
        XCTAssertGreaterThanOrEqual(sink.saved.last!.msPlayed, 20_000)
        // The recorder owns the subscription; keep it alive to here.
        withExtendedLifetime(rec) {}
    }

    private final class Sink: ListenSink {
        var saved: [LiveListen] = []
        var flushes = 0
        func save(_ listen: LiveListen) { saved.append(listen) }
        func flush(timeout: TimeInterval) { flushes += 1 }
    }
}
