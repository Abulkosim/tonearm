import AppKit
import XCTest
@testable import Tonearm

/// When song notifications go out. The notifier runs on a clock the test moves by hand, so
/// a slow runner can't fire a timer early or late.
@MainActor
final class TrackNotifierTimingTests: XCTestCase {
    private final class Posts {
        var titles: [String] = []
        var images: [Bool] = []
    }

    /// Work scheduled by the notifier, run when the test moves time past its deadline.
    private final class Clock {
        private(set) var now: TimeInterval = 0
        private var queue: [(deadline: TimeInterval, order: Int, work: DispatchWorkItem)] = []
        private var count = 0

        func schedule(_ delay: TimeInterval, _ work: DispatchWorkItem) {
            count += 1
            queue.append((now + delay, count, work))
        }

        /// Moves time forward by `seconds`, running due work in deadline order, as the main
        /// queue would.
        func advance(_ seconds: TimeInterval) {
            let end = now + seconds
            while let next = queue.filter({ $0.deadline <= end }).min(by: { ($0.deadline, $0.order) < ($1.deadline, $1.order) }) {
                queue.removeAll { $0.order == next.order }
                now = next.deadline
                if !next.work.isCancelled { next.work.perform() }
            }
            now = end
        }
    }

    private let clock = Clock()
    private let cover = NSImage(size: NSSize(width: 1, height: 1))

    private func track(_ id: String) -> Track {
        Track(id: "spotify:track:\(id)", title: id, artist: "Artist", album: "Album", artworkURL: nil, duration: 200)
    }

    private func notifier(_ posts: Posts, visible: Bool = false) -> TrackNotifier {
        let clock = clock
        return TrackNotifier(isEnabled: { true }, isPopoverVisible: { visible },
                             post: { track, image in
                                 posts.titles.append(track.title)
                                 posts.images.append(image != nil)
                             },
                             schedule: { clock.schedule($0, $1) })
    }

    /// Skipping through songs whose covers are already loaded posted one notification per
    /// skip. Now only the song that stays gets one, once it has played `settleTime`.
    func testRapidSkipsPostOnce() {
        let posts = Posts()
        let n = notifier(posts)
        n.trackChanged(track("first"))
        for id in ["b", "c", "d"] {
            n.trackChanged(track(id))
            n.artworkReady(cover, trackID: "spotify:track:\(id)")
            clock.advance(TrackNotifier.settleTime * 0.5)
        }
        XCTAssertEqual(posts.titles, [], "posted a song that was skipped before it settled")
        clock.advance(TrackNotifier.settleTime * 0.5)
        XCTAssertEqual(posts.titles, ["d"])
        XCTAssertEqual(posts.images, [true])
        clock.advance(TrackNotifier.artworkWait * 2)
        XCTAssertEqual(posts.titles, ["d"], "posted twice")
    }

    /// A cover that arrives after the song settled goes out with it at once.
    func testLateCoverPostsWhenItArrives() {
        let posts = Posts()
        let n = notifier(posts)
        n.trackChanged(track("first"))
        n.trackChanged(track("b"))
        clock.advance((TrackNotifier.settleTime + TrackNotifier.artworkWait) / 2)
        XCTAssertEqual(posts.titles, [], "posted without waiting for the cover")
        n.artworkReady(cover, trackID: "spotify:track:b")
        XCTAssertEqual(posts.titles, ["b"])
        XCTAssertEqual(posts.images, [true])
    }

    /// No cover in time: the notification goes out without one, at `artworkWait`.
    func testNoCoverPostsAfterTheWait() {
        let posts = Posts()
        let n = notifier(posts)
        n.trackChanged(track("first"))
        n.trackChanged(track("b"))
        clock.advance(TrackNotifier.artworkWait - 0.01)
        XCTAssertEqual(posts.titles, [])
        clock.advance(0.01)
        XCTAssertEqual(posts.titles, ["b"])
        XCTAssertEqual(posts.images, [false])
        n.artworkReady(cover, trackID: "spotify:track:b")
        XCTAssertEqual(posts.titles, ["b"], "a cover after the post posted again")
    }

    /// The first song after launch, and songs while the player is open, get none.
    func testFirstSongAndOpenPlayerPostNothing() {
        let posts = Posts()
        let n = notifier(posts)
        n.trackChanged(track("first"))
        n.artworkReady(nil, trackID: "spotify:track:first")
        let open = notifier(posts, visible: true)
        open.trackChanged(track("a"))
        open.trackChanged(track("b"))
        open.artworkReady(nil, trackID: "spotify:track:b")
        clock.advance(TrackNotifier.artworkWait * 2)
        XCTAssertEqual(posts.titles, [])
    }
}
