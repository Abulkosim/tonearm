import AppKit
import XCTest
@testable import Tonearm

/// When song notifications go out. Short delays stand in for the real ones.
@MainActor
final class TrackNotifierTimingTests: XCTestCase {
    private final class Posts {
        var titles: [String] = []
        var images: [Bool] = []
    }

    private func track(_ id: String) -> Track {
        Track(id: "spotify:track:\(id)", title: id, artist: "Artist", album: "Album", artworkURL: nil, duration: 200)
    }

    private func notifier(_ posts: Posts, visible: Bool = false) -> TrackNotifier {
        TrackNotifier(isEnabled: { true }, isPopoverVisible: { visible }, settle: 0.2, artworkWait: 0.6) { track, image in
            posts.titles.append(track.title)
            posts.images.append(image != nil)
        }
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Skipping through songs whose covers are already loaded posted one notification per
    /// skip. Now only the song that stays gets one.
    func testRapidSkipsPostOnce() async {
        let posts = Posts()
        let n = notifier(posts)
        n.trackChanged(track("first"))
        for id in ["b", "c", "d"] {
            n.trackChanged(track(id))
            n.artworkReady(NSImage(size: NSSize(width: 1, height: 1)), trackID: "spotify:track:\(id)")
        }
        XCTAssertEqual(posts.titles, [], "posted before the song settled")
        await wait(0.4)
        XCTAssertEqual(posts.titles, ["d"])
        XCTAssertEqual(posts.images, [true])
        await wait(0.5)
        XCTAssertEqual(posts.titles, ["d"], "posted twice")
    }

    /// A cover that arrives after the song settled goes out with it at once.
    func testLateCoverPostsWhenItArrives() async {
        let posts = Posts()
        let n = notifier(posts)
        n.trackChanged(track("first"))
        n.trackChanged(track("b"))
        await wait(0.3)
        XCTAssertEqual(posts.titles, [], "posted without waiting for the cover")
        n.artworkReady(NSImage(size: NSSize(width: 1, height: 1)), trackID: "spotify:track:b")
        XCTAssertEqual(posts.titles, ["b"])
        XCTAssertEqual(posts.images, [true])
    }

    /// No cover in time: the notification goes out without one.
    func testNoCoverPostsAfterTheWait() async {
        let posts = Posts()
        let n = notifier(posts)
        n.trackChanged(track("first"))
        n.trackChanged(track("b"))
        await wait(0.9)
        XCTAssertEqual(posts.titles, ["b"])
        XCTAssertEqual(posts.images, [false])
    }

    /// The first song after launch, and songs while the player is open, get none.
    func testFirstSongAndOpenPlayerPostNothing() async {
        let posts = Posts()
        let n = notifier(posts)
        n.trackChanged(track("first"))
        n.artworkReady(nil, trackID: "spotify:track:first")
        let open = notifier(posts, visible: true)
        open.trackChanged(track("a"))
        open.trackChanged(track("b"))
        open.artworkReady(nil, trackID: "spotify:track:b")
        await wait(0.9)
        XCTAssertEqual(posts.titles, [])
    }
}
