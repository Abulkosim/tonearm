import AppKit
import SwiftUI

@MainActor
final class PlayerModel: ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case notRunning
        case notAuthorized
        case ready
    }

    @Published private(set) var status: Status = .notRunning
    @Published private(set) var playback = Playback(state: .stopped, track: nil, position: 0, volume: 50)
    /// When `playback.position` was true, used to advance the progress bar locally.
    @Published private(set) var positionDate = Date()
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkColors: ArtworkColors?
    /// True from `openSpotify()` until Spotify answers, or 20 seconds pass.
    @Published private(set) var isLaunching = false
    /// Set by the view while the popover is open. Polls faster while visible.
    @Published var popoverVisible = false {
        didSet { if popoverVisible != oldValue { popoverVisibilityChanged() } }
    }

    let bridge: SpotifyBridge
    private let live: Bool
    private var observers: [Any] = []
    private var spotifyRunning = false

    private var pollTimer: Timer?
    private var pollInterval: TimeInterval?
    private var fetchInFlight = false
    private var fetchQueued = false
    /// Bumped by every local command. Fetches started before a command are stale.
    private var commandGeneration = 0

    private var holdPositionUntil = Date.distantPast
    private var holdVolumeUntil = Date.distantPast
    private var seekInFlight = false
    private var queuedSeek: Double?
    private var volumeInFlight = false
    private var queuedVolume: Int?
    private var launchTimeout: DispatchWorkItem?

    private var artworkURL: URL?
    private let artworkCache = ArtworkCache(limit: 10)

    /// Position corrections smaller than this are ignored while playing.
    static let driftTolerance = 0.75

    var track: Track? { playback.track }
    var isPlaying: Bool { playback.state == .playing }

    init(bridge: SpotifyBridge = SpotifyBridge(), live: Bool = true) {
        self.bridge = bridge
        self.live = live
        guard live else { return }

        observers.append(SpotifyBridge.observeChanges { [weak self] update in
            Task { @MainActor in self?.notificationArrived(update) }
        })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard Self.isSpotify(note) else { return }
            Task { @MainActor in self?.spotifyLaunched() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard Self.isSpotify(note) else { return }
            Task { @MainActor in self?.spotifyTerminated() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheckIfBlocked() }
        })

        spotifyRunning = bridge.isRunning
        if spotifyRunning { refresh() } else { spotifyStopped() }
    }

    private nonisolated static func isSpotify(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == SpotifyBridge.bundleID
    }

    // MARK: Position

    private var clock: PositionClock {
        PositionClock(position: playback.position, date: positionDate, isPlaying: isPlaying,
                      duration: track?.duration)
    }

    /// Current position, advanced by wall-clock time while playing.
    func position(at date: Date) -> Double { clock.position(at: date) }

    // MARK: Updates

    func refresh() {
        guard live else { return }
        guard spotifyRunning else { return spotifyStopped() }
        if fetchInFlight { fetchQueued = true; return }
        fetchInFlight = true
        let generation = commandGeneration
        bridge.fetch { [weak self] result, readAt in
            guard let self else { return }
            self.fetchInFlight = false
            self.fetched(result, readAt: readAt, generation: generation)
            if self.fetchQueued {
                self.fetchQueued = false
                self.refresh()
            }
            self.updatePolling()
        }
    }

    private func fetched(_ result: Result<Playback, BridgeError>, readAt: Date, generation: Int) {
        guard spotifyRunning else { return }
        switch result {
        case .success(let p):
            status = .ready
            isLaunching = false
            launchTimeout?.cancel()
            // A command was sent while this fetch ran; its answer may predate the command.
            guard generation == commandGeneration else { fetchQueued = true; return }
            merge(state: p.state, track: p.track, reportedPosition: p.position, volume: p.volume, at: readAt)
            loadArtwork(p.track?.artworkURL)
        case .failure(.notAuthorized):
            status = .notAuthorized
        case .failure(.notRunning):
            // Spotify quit mid-call, or is still starting. The terminate notification handles a real quit.
            if !bridge.isRunning { spotifyTerminated() }
        case .failure:
            // Transient (timeout, no current track, Spotify busy). Keep the last good state.
            break
        }
    }

    private func notificationArrived(_ update: NowPlayingUpdate?) {
        guard live else { return }
        if !spotifyRunning {
            guard bridge.isRunning else { return }
            spotifyRunning = true
        }
        if let update, status == .ready {
            var track = update.track
            if track?.id == playback.track?.id { track?.artworkURL = playback.track?.artworkURL }
            merge(state: update.state, track: track, reportedPosition: update.position, volume: nil, at: Date())
        }
        // One AppleScript read for artwork, volume and the exact position.
        refresh()
        updatePolling()
    }

    /// Applies new state from Spotify without undoing recent local changes.
    private func merge(state: PlayState, track: Track?, reportedPosition: Double?, volume: Int?, at readAt: Date) {
        let now = Date()
        let sameTrack = track?.id == playback.track?.id
        let playing = state == .playing
        var next = playback
        next.state = state
        next.track = track

        let newClock: PositionClock
        if !sameTrack {
            newClock = PositionClock(position: reportedPosition ?? 0, date: readAt, isPlaying: playing,
                                     duration: track?.duration)
        } else if let reported = reportedPosition, now >= holdPositionUntil {
            newClock = clock.reconciled(reported: reported, at: readAt, isPlaying: playing,
                                        tolerance: Self.driftTolerance)
        } else {
            // Recently seeked, or no position given: keep the local playhead, re-anchor on a state change.
            newClock = clock.reconciled(reported: clock.position(at: now), at: now, isPlaying: playing,
                                        tolerance: .infinity)
        }
        next.position = newClock.position

        if let volume, now >= holdVolumeUntil, !volumeInFlight, queuedVolume == nil {
            next.volume = volume
        }
        if next != playback { playback = next }
        if newClock.date != positionDate { positionDate = newClock.date }
    }

    private func updatePolling() {
        var interval: TimeInterval?
        if live && spotifyRunning {
            interval = popoverVisible && isPlaying && status == .ready ? 1 : 5
        }
        guard interval != pollInterval else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = interval
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func popoverVisibilityChanged() {
        guard live else { return }
        if popoverVisible {
            if spotifyRunning { refresh() } else { spotifyStopped() }
        }
        updatePolling()
    }

    private func recheckIfBlocked() {
        if status == .notAuthorized || !spotifyRunning { refresh() }
    }

    // MARK: Spotify lifecycle

    private func spotifyLaunched() {
        spotifyRunning = true
        if status == .notInstalled { status = .notRunning }
        updatePolling()
        refresh()
        // Spotify answers Apple Events a moment after the process starts.
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    private func spotifyTerminated() {
        spotifyRunning = bridge.isRunning
        if !spotifyRunning { spotifyStopped() }
    }

    /// Resets to the idle state. Never sends Apple Events.
    private func spotifyStopped() {
        spotifyRunning = false
        fetchQueued = false
        let idle: Status = bridge.isInstalled ? .notRunning : .notInstalled
        if status != idle { status = idle }
        let empty = Playback(state: .stopped, track: nil, position: 0, volume: playback.volume)
        if playback != empty { playback = empty }
        artworkURL = nil
        if artwork != nil { artwork = nil }
        if artworkColors != nil { artworkColors = nil }
        updatePolling()
    }

    // MARK: Artwork

    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkURL = url
        guard let url, url.scheme == "https" || url.scheme == "http" else {
            artwork = nil
            artworkColors = nil
            return
        }
        if let hit = artworkCache[url] {
            artwork = hit.image
            artworkColors = hit.colors
            return
        }
        // Keep the old cover until the new one arrives, so it does not flash empty.
        URLSession.shared.dataTask(with: url) { data, _, _ in
            // Decode and pick colors here, off the main thread.
            let image = data.flatMap(NSImage.init(data:))
            let colors = data.flatMap(ArtworkColors.init(data:))
            Task { @MainActor [weak self] in
                guard let self, self.artworkURL == url else { return }
                if let image { self.artworkCache[url] = ArtworkCache.Entry(image: image, colors: colors) }
                self.artwork = image
                self.artworkColors = image == nil ? nil : colors
            }
        }.resume()
    }

    // MARK: Commands

    func playPause() {
        guard status == .ready else { return }
        let now = Date()
        playback.position = position(at: now)
        positionDate = now
        playback.state = isPlaying ? .paused : .playing
        commandGeneration += 1
        bridge.send(.playPause) { [weak self] in self?.refresh() }
        updatePolling()
    }

    func next() {
        guard status == .ready else { return }
        commandGeneration += 1
        bridge.send(.next) { [weak self] in self?.refresh() }
    }

    func previous() {
        guard status == .ready else { return }
        commandGeneration += 1
        bridge.send(.previous) { [weak self] in self?.refresh() }
    }

    /// Moves the playhead now and tells Spotify. Rapid calls coalesce: one send in flight, last value wins.
    func seek(to seconds: Double) {
        guard status == .ready, track != nil else { return }
        var s = max(0, seconds)
        if let d = track?.duration, d > 0 { s = min(s, d) }
        playback.position = s
        positionDate = Date()
        holdPositionUntil = Date().addingTimeInterval(1.5)
        commandGeneration += 1
        queuedSeek = s
        sendQueuedSeek()
    }

    private func sendQueuedSeek() {
        guard !seekInFlight, let s = queuedSeek else { return }
        queuedSeek = nil
        seekInFlight = true
        bridge.send(.seek(s)) { [weak self] in
            guard let self else { return }
            self.seekInFlight = false
            self.holdPositionUntil = Date().addingTimeInterval(1)
            self.sendQueuedSeek()
        }
    }

    /// Sets the volume (0...100) now and tells Spotify. Rapid calls coalesce: one send in flight,
    /// last value wins. Volume read back from Spotify is ignored for a second after a change.
    func setVolume(_ v: Int) {
        guard status == .ready else { return }
        let v = min(100, max(0, v))
        holdVolumeUntil = Date().addingTimeInterval(1)
        if v == playback.volume && !volumeInFlight && queuedVolume == nil { return }
        playback.volume = v
        queuedVolume = v
        sendQueuedVolume()
    }

    private func sendQueuedVolume() {
        guard !volumeInFlight, let v = queuedVolume else { return }
        queuedVolume = nil
        volumeInFlight = true
        bridge.send(.volume(v)) { [weak self] in
            guard let self else { return }
            self.volumeInFlight = false
            self.holdVolumeUntil = Date().addingTimeInterval(1)
            self.sendQueuedVolume()
        }
    }

    /// Launches Spotify in the background without taking focus.
    func openSpotify() {
        guard live, !spotifyRunning else { return }
        isLaunching = true
        launchTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.isLaunching = false }
        }
        launchTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        bridge.launch { [weak self] ok in
            guard let self, !ok else { return }
            self.isLaunching = false
            self.spotifyStopped()
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Asks macOS for Automation access to Spotify (shows the prompt if the user has not
    /// answered yet), then refreshes. macOS never asks twice, so after a denial this opens
    /// the Automation pane in System Settings instead.
    func requestPermission() {
        guard live else { return }
        guard spotifyRunning else { return refresh() }
        bridge.checkPermission(ask: true) { [weak self] permission in
            guard let self else { return }
            switch permission {
            case .denied:
                self.status = .notAuthorized
                self.openAutomationSettings()
            case .notRunning:
                self.spotifyTerminated()
            case .granted, .unknown:
                self.refresh()
            }
        }
    }

    /// Used by the snapshot renderer and previews.
    func setPreview(_ playback: Playback, artwork: NSImage?) {
        status = .ready
        self.playback = playback
        self.positionDate = Date()
        self.artwork = artwork
        self.artworkColors = artwork.flatMap(ArtworkColors.init(image:))
    }
}

/// Last few covers and their colors, keyed by URL.
@MainActor
final class ArtworkCache {
    struct Entry {
        var image: NSImage
        var colors: ArtworkColors?
    }

    private let limit: Int
    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []

    init(limit: Int) { self.limit = limit }

    subscript(url: URL) -> Entry? {
        get {
            guard let e = entries[url] else { return nil }
            order.removeAll { $0 == url }
            order.append(url)
            return e
        }
        set {
            order.removeAll { $0 == url }
            entries[url] = newValue
            guard newValue != nil else { return }
            order.append(url)
            while order.count > limit { entries[order.removeFirst()] = nil }
        }
    }

    var count: Int { entries.count }
}
