import AppKit

/// Turns what the player sees (track, playing or not, position, at a time) into listens.
/// Pure, for tests: `PlayRecorder` feeds it and stores what it returns.
///
/// Only real listening counts. Between two looks at the same track, the credit is the
/// smaller of how far the playhead moved and how much wall-clock time passed, and only if
/// it was playing at the first look. So pauses, seeks forward, polling gaps and sleep never
/// add time; a seek back adds nothing for that stretch.
///
/// A listen closes when the track changes, Spotify stops or quits, Tonearm quits, or the
/// same track starts again from the top (repeat one, or previous). The stretch between the
/// last look and the change is credited only up to the track's remaining time, the time
/// the next track has not yet played, and `maxUnseen`.
struct ListenTracker {
    /// The longest stretch credited without seeing the playhead move. Tonearm reads Spotify
    /// at least every 30 s while it plays, and Spotify announces track changes.
    static let maxUnseen: TimeInterval = 40
    /// Shorter listens are not kept.
    static let minimumMs: Int64 = 1000

    private(set) var current: LiveListen?
    private var played: TimeInterval = 0
    private var last: (date: Date, position: Double, playing: Bool, trackID: String?)?

    /// Feeds one look at the player. Returns listens that closed.
    mutating func observe(track: Track?, playing: Bool, position: Double, at now: Date) -> [LiveListen] {
        let p = position.isFinite ? max(0, position) : 0
        let wall = last.map { max(0, now.timeIntervalSince($0.date)) } ?? 0
        let wasPlaying = last?.playing ?? false
        var closed: [LiveListen] = []

        if let last, let track, track.id == last.trackID {
            let delta = p - last.position
            if wasPlaying && delta < 0 && p <= wall + 1 {
                // Back at the top: the same track started again.
                let tail = tailCredit(after: last, wall: wall, nextPosition: p)
                credit(tail, endingAt: now.addingTimeInterval(-p))
                if let done = finish() { closed.append(done) }
                open(track, at: now, initial: min(p, max(0, wall - tail)))
            } else if wasPlaying && delta >= 0 {
                credit(min(delta, wall), endingAt: now)
            }
        } else {
            var used: TimeInterval = 0
            if let last, current != nil {
                if wasPlaying {
                    used = tailCredit(after: last, wall: wall, nextPosition: track == nil ? 0 : p)
                    credit(used, endingAt: last.date.addingTimeInterval(used))
                }
            }
            if let done = finish() { closed.append(done) }
            if let track {
                // Seen start since the last look while something played: count that part.
                let initial = wasPlaying ? min(p, max(0, wall - used), Self.maxUnseen) : 0
                open(track, at: now, initial: initial)
            }
        }
        if let track, current?.trackID == track.id, let url = track.artworkURL?.absoluteString {
            current?.artworkURL = url
        }
        last = (now, p, playing, track?.id)
        return closed
    }

    /// Spotify quit or Tonearm is quitting: closes the open listen.
    mutating func close(at now: Date) -> LiveListen? {
        let closed = observe(track: nil, playing: false, position: 0, at: now)
        last = nil
        return closed.first
    }

    /// Ads and empty tracks are never recorded.
    static func isRecordable(_ track: Track) -> Bool {
        !track.id.hasPrefix("spotify:ad:") && !(track.id.isEmpty && track.title.isEmpty)
    }

    private func tailCredit(after last: (date: Date, position: Double, playing: Bool, trackID: String?),
                            wall: TimeInterval, nextPosition: Double) -> TimeInterval {
        let remaining = (current?.durationMs).map { max(0, Double($0) / 1000 - last.position) } ?? Self.maxUnseen
        return max(0, min(remaining, wall - nextPosition, Self.maxUnseen))
    }

    private mutating func credit(_ seconds: TimeInterval, endingAt end: Date) {
        guard current != nil, seconds > 0 else { return }
        played += seconds
        current?.msPlayed = Int64((played * 1000).rounded())
        if let c = current, end > c.endedAt { current?.endedAt = end }
    }

    private mutating func open(_ track: Track, at now: Date, initial: TimeInterval) {
        guard Self.isRecordable(track) else {
            current = nil
            return
        }
        let initial = max(0, initial)
        let start = now.addingTimeInterval(-initial)
        played = initial
        current = LiveListen(
            trackID: track.id, kind: ListenKind.of(spotifyID: track.id), title: track.title, artist: track.artist,
            album: track.album, artworkURL: track.artworkURL?.absoluteString,
            durationMs: track.duration > 0 ? Int64((track.duration * 1000).rounded()) : nil,
            startedAt: start, endedAt: now, msPlayed: Int64((initial * 1000).rounded()))
    }

    /// Closes the open listen; nil if there was none or it was too short to keep.
    private mutating func finish() -> LiveListen? {
        defer {
            current = nil
            played = 0
        }
        guard let c = current, c.msPlayed >= Self.minimumMs else { return nil }
        return c
    }
}

/// Where recorded listens go. `HistoryStore` in the app, a list in tests.
protocol ListenSink: AnyObject {
    func save(_ listen: LiveListen)
    func flush()
}

extension HistoryStore: ListenSink {}

/// Records what plays in Spotify into the history, while `AppSettings.recordHistory` is on.
/// `PlayerModel` calls `observe` whenever it learns something new about playback. The open
/// listen is saved every `saveInterval`, so a crash loses at most about that much.
@MainActor
final class PlayRecorder {
    static let saveInterval: TimeInterval = 25

    private var tracker = ListenTracker()
    private let sink: ListenSink
    private let isEnabled: () -> Bool
    private var lastSave = Date.distantPast
    private var lastSavedMs: Int64 = 0
    private var enabled = true
    private var terminateObserver: NSObjectProtocol?

    init(sink: ListenSink, isEnabled: @escaping () -> Bool) {
        self.sink = sink
        self.isEnabled = isEnabled
    }

    /// The app's recorder: stores into `HistoryStore.shared`, and closes the open listen
    /// when Tonearm quits.
    static func live(settings: AppSettings) -> PlayRecorder {
        let recorder = PlayRecorder(sink: HistoryStore.shared, isEnabled: { [weak settings] in
            settings?.recordHistory ?? false
        })
        recorder.terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak recorder] _ in
            MainActor.assumeIsolated { recorder?.stop() }
        }
        return recorder
    }

    func observe(track: Track?, playing: Bool, position: Double, at now: Date = Date()) {
        guard isEnabled() else {
            // Turned off: keep what was heard so far, then stop.
            if enabled {
                enabled = false
                stop(at: now)
            }
            return
        }
        enabled = true
        for listen in tracker.observe(track: track, playing: playing, position: position, at: now) {
            store(listen)
        }
        guard let open = tracker.current, open.msPlayed >= ListenTracker.minimumMs,
              open.msPlayed != lastSavedMs, now.timeIntervalSince(lastSave) >= Self.saveInterval
        else { return }
        store(open)
        lastSave = now
    }

    /// Closes the open listen and writes everything out. Spotify quit or Tonearm is quitting.
    func stop(at now: Date = Date()) {
        if let listen = tracker.close(at: now) { store(listen) }
        sink.flush()
    }

    private func store(_ listen: LiveListen) {
        sink.save(listen)
        lastSavedMs = listen.msPlayed
    }
}
