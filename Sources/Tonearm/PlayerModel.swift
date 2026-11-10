import AppKit
import Combine
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
    @Published private(set) var playback = Playback(state: .stopped, track: nil, position: 0, volume: 50) {
        didSet {
            let old = oldValue.track, new = playback.track
            if old?.id != new?.id || old?.title != new?.title { notifier?.trackChanged(new) }
        }
    }
    /// When `playback.position` was true, used to advance the progress bar locally.
    @Published private(set) var positionDate = Date()
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkColors: ArtworkColors?
    /// True from `openSpotify()` until Spotify answers, or 20 seconds pass.
    @Published private(set) var isLaunching = false
    /// True while macOS shows its "Tonearm wants to control Spotify" prompt. `status` is
    /// `.notAuthorized` meanwhile (never `.notRunning` while Spotify runs), so check this first.
    @Published private(set) var isAskingPermission = false
    /// True while the popover is open. Polls faster while visible. The view sets it on
    /// appear and disappear; the model also follows the popover window, because a
    /// MenuBarExtra window does not reliably call those again after the first open.
    @Published var popoverVisible = false {
        didSet { if popoverVisible != oldValue { popoverVisibilityChanged() } }
    }

    let bridge: SpotifyBridge
    let settings: AppSettings
    private let live: Bool
    private var observers: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var spotifyRunning = false
    private var hotKeys: HotKeys?
    private var notifier: TrackNotifier?

    private var pollTimer: Timer?
    private var pollInterval: TimeInterval?
    private var fetchInFlight = false
    private var fetchQueued = false
    private var delayedRefresh: DispatchWorkItem?
    /// Bumped by every local command. Fetches started before a command are stale.
    private var commandGeneration = 0

    private var holdPositionUntil = Date.distantPast
    private var holdVolumeUntil = Date.distantPast
    private var holdStateUntil = Date.distantPast
    private var holdModesUntil = Date.distantPast
    private var seekInFlight = false
    private var queuedSeek: Double?
    private var volumeInFlight = false
    private var queuedVolume: Int?
    /// Last volume Tonearm set. Spotify often reads it back one lower.
    private var lastSentVolume: Int?
    private var launchTimeout: DispatchWorkItem?

    private var artworkURL: URL?
    /// The URL whose image is in `artwork`. `artwork` keeps the old cover while a new one loads.
    private var loadedArtworkURL: URL?
    private var artworkFailure: (url: URL, date: Date)?
    private let artworkCache = ArtworkCache(limit: 10)

    /// Position corrections smaller than this are ignored while playing.
    static let driftTolerance = 0.75
    /// Seconds between reads while the popover shows a playing song, and otherwise.
    static let visiblePollInterval: TimeInterval = 2
    static let backgroundPollInterval: TimeInterval = 5

    var track: Track? { playback.track }
    var isPlaying: Bool { playback.state == .playing }
    var shuffling: Bool { playback.shuffling }
    var repeating: Bool { playback.repeating }
    /// open.spotify.com link for the current song or episode. Nil for local files and ads.
    var trackURL: URL? { track.flatMap { SpotifyLink.webURL(for: $0.id) } }

    init(bridge: SpotifyBridge = SpotifyBridge(), settings: AppSettings = .shared, live: Bool = true) {
        self.bridge = bridge
        self.settings = settings
        self.live = live
        guard live else { return }

        bridge.permissionPromptChanged = { [weak self] asking in self?.permissionPromptChanged(asking) }
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
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(after: 2) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheckIfBlocked() }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                // Let the window finish ordering in or out before looking.
                DispatchQueue.main.async {
                    Task { @MainActor in self?.followPopoverWindow() }
                }
            })
        }

        startExtras()

        spotifyRunning = bridge.isRunning
        if spotifyRunning { refresh() } else { spotifyStopped() }
    }

    private nonisolated static func isSpotify(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == SpotifyBridge.bundleID
    }

    /// Global shortcuts and song notifications, driven by settings. Live mode only.
    private func startExtras() {
        hotKeys = HotKeys { [weak self] action in
            Task { @MainActor in self?.perform(action) }
        }
        notifier = TrackNotifier(
            isEnabled: { [weak self] in self?.settings.notifyOnTrackChange ?? false },
            isPopoverVisible: { [weak self] in self?.popoverVisible ?? false }
        )
        // The publishers fire before the value is stored, so read it again after a hop.
        settings.$globalShortcuts.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hotKeys?.setEnabled(self.settings.globalShortcuts)
            }
        }.store(in: &cancellables)
        settings.$notifyOnTrackChange.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.notifySettingChanged() }
        }.store(in: &cancellables)
    }

    private func notifySettingChanged() {
        guard settings.notifyOnTrackChange else { return }
        TrackNotifier.requestAuthorization { [weak self] granted in
            // Turn the switch back off if macOS will not show them.
            if !granted { self?.settings.notifyOnTrackChange = false }
        }
    }

    private func permissionPromptChanged(_ asking: Bool) {
        let asking = asking && spotifyRunning
        if isAskingPermission != asking { isAskingPermission = asking }
        // Spotify is running and the answer is pending: not ready, but not "not running" either.
        if asking, status != .ready { status = .notAuthorized }
    }

    private func perform(_ action: HotKeys.Action) {
        switch action {
        case .playPause: playPause()
        case .next: next()
        case .previous: previous()
        }
    }

    /// The MenuBarExtra panel is the app's only window besides the status item's own.
    private func followPopoverWindow() {
        let visible = NSApp.windows.contains { window in
            window.className != "NSStatusBarWindow" && window.isVisible
                && window.occlusionState.contains(.visible) && window.frame.width > 40
        }
        if visible != popoverVisible { popoverVisible = visible }
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
        delayedRefresh?.cancel()
        delayedRefresh = nil
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

    /// One refresh after `delay`, replacing any already scheduled.
    private func scheduleRefresh(after delay: TimeInterval) {
        delayedRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        delayedRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
            merge(state: p.state, track: p.track, reportedPosition: p.position, volume: p.volume,
                  modes: (p.shuffling, p.repeating), at: readAt, fromNotification: false)
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
        let previousID = playback.track?.id
        if let update, status == .ready {
            var track = update.track
            if track?.id == playback.track?.id { track?.artworkURL = playback.track?.artworkURL }
            merge(state: update.state, track: track, reportedPosition: update.position, volume: nil,
                  modes: nil, at: Date(), fromNotification: true)
        }
        // One AppleScript read for artwork, volume and the exact position. Spotify pauses
        // when it quits, and an Apple Event that reaches it mid-quit makes AppleScript
        // relaunch it. So a pause or stop without a new song waits until a quit is visible.
        let newSong = update?.track != nil && update?.track?.id != previousID
        if let update, update.state != .playing, !newSong {
            scheduleRefresh(after: 1.5)
        } else {
            refresh()
        }
        updatePolling()
    }

    /// Applies new state from Spotify without undoing recent local changes.
    private func merge(state reportedState: PlayState, track: Track?, reportedPosition: Double?, volume: Int?,
                       modes: (shuffling: Bool, repeating: Bool)?, at readAt: Date, fromNotification: Bool) {
        let now = Date()
        let sameTrack = track?.id == playback.track?.id
        // Spotify posts its notification after a change, so it settles play/pause at once.
        // A read that started right after play/pause can still see the old state.
        if fromNotification { holdStateUntil = .distantPast }
        let state = sameTrack && now < holdStateUntil ? playback.state : reportedState
        let playing = state == .playing
        var next = playback
        next.state = state
        next.track = track

        let newClock: PositionClock
        if !sameTrack {
            newClock = PositionClock(position: max(0, reportedPosition ?? 0), date: readAt, isPlaying: playing,
                                     duration: track?.duration)
        } else if let reported = reportedPosition, now >= holdPositionUntil, state == reportedState {
            newClock = clock.reconciled(reported: reported, at: readAt, isPlaying: playing,
                                        tolerance: Self.driftTolerance)
        } else {
            // Recently seeked, held state, or no position given: keep the local playhead,
            // re-anchor on a state change.
            newClock = clock.reconciled(reported: clock.position(at: now), at: now, isPlaying: playing,
                                        tolerance: .infinity)
        }
        next.position = newClock.position
        if let volume, now >= holdVolumeUntil, !volumeInFlight, queuedVolume == nil {
            let shown = PlayerMath.volumeToShow(reported: volume, local: playback.volume, lastSent: lastSentVolume)
            if shown != lastSentVolume { lastSentVolume = nil }
            next.volume = shown
        }
        if let modes, now >= holdModesUntil {
            next.shuffling = modes.shuffling
            next.repeating = modes.repeating
        }
        if next != playback { playback = next }
        if newClock.date != positionDate { positionDate = newClock.date }
    }

    private func updatePolling() {
        var interval: TimeInterval?
        if live && spotifyRunning {
            interval = popoverVisible && isPlaying && status == .ready
                ? Self.visiblePollInterval : Self.backgroundPollInterval
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
        if isAskingPermission { isAskingPermission = false }
        fetchQueued = false
        delayedRefresh?.cancel()
        delayedRefresh = nil
        let idle: Status = bridge.isInstalled ? .notRunning : .notInstalled
        if status != idle { status = idle }
        let empty = Playback(state: .stopped, track: nil, position: 0, volume: playback.volume)
        if playback != empty { playback = empty }
        artworkURL = nil
        loadedArtworkURL = nil
        if artwork != nil { artwork = nil }
        if artworkColors != nil { artworkColors = nil }
        updatePolling()
    }

    // MARK: Artwork

    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else {
            // Same cover as before, e.g. the next song on the same album.
            if url == nil || loadedArtworkURL == url { artworkSettled(url, image: artwork) }
            return
        }
        artworkURL = url
        guard let url else {
            setArtwork(nil, colors: nil, for: nil)
            return
        }
        if let hit = artworkCache[url] {
            setArtwork(hit.image, colors: hit.colors, for: url)
            return
        }
        if let failure = artworkFailure, failure.url == url, Date().timeIntervalSince(failure.date) < 30 {
            // Failed a moment ago. Leave `artworkURL` unset so a later read tries again.
            artworkURL = nil
            setArtwork(nil, colors: nil, for: url)
            return
        }
        // Keep the old cover until the new one arrives, so it does not flash empty.
        URLSession.shared.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let data = ok ? data : nil
            // Decode and pick colors here, off the main thread.
            let image = data.flatMap(NSImage.init(data:))
            let colors = data.flatMap(ArtworkColors.init(data:))
            Task { @MainActor [weak self] in
                guard let self, self.artworkURL == url else { return }
                if let image {
                    self.artworkCache[url] = ArtworkCache.Entry(image: image, colors: colors)
                } else {
                    // Try again on a later read instead of never.
                    self.artworkFailure = (url, Date())
                    self.artworkURL = nil
                }
                self.setArtwork(image, colors: colors, for: url)
            }
        }.resume()
    }

    private func setArtwork(_ image: NSImage?, colors: ArtworkColors?, for url: URL?) {
        loadedArtworkURL = image == nil ? nil : url
        if artwork !== image { artwork = image }
        let colors = image == nil ? nil : colors
        if artworkColors != colors { artworkColors = colors }
        artworkSettled(url, image: image)
    }

    /// Hands the cover to the notifier once it is known for the current song.
    private func artworkSettled(_ url: URL?, image: NSImage?) {
        guard let track, track.artworkURL == url else { return }
        notifier?.artworkReady(image, trackID: track.id)
    }

    // MARK: Commands

    func playPause() {
        guard status == .ready else { return }
        let now = Date()
        playback.position = position(at: now)
        positionDate = now
        playback.state = isPlaying ? .paused : .playing
        holdStateUntil = now.addingTimeInterval(1.5)
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

    func toggleShuffle() {
        guard status == .ready else { return }
        playback.shuffling.toggle()
        sendMode(.shuffle(playback.shuffling))
    }

    func toggleRepeat() {
        guard status == .ready else { return }
        playback.repeating.toggle()
        sendMode(.repeating(playback.repeating))
    }

    /// Shows the new shuffle or repeat value at once; reads ignore Spotify's until it caught up.
    private func sendMode(_ command: SpotifyBridge.Command) {
        holdModesUntil = Date().addingTimeInterval(5)
        bridge.send(command) { [weak self] in
            guard let self else { return }
            self.holdModesUntil = Date().addingTimeInterval(1)
            self.refresh()
        }
    }

    /// Moves the playhead now and tells Spotify. Rapid calls coalesce: one send in flight, last value wins.
    func seek(to seconds: Double) {
        guard status == .ready, let track else { return }
        let s = PlayerMath.clampPosition(seconds, duration: track.duration)
        playback.position = s
        positionDate = Date()
        holdPositionUntil = Date().addingTimeInterval(1.5)
        commandGeneration += 1
        queuedSeek = s
        sendQueuedSeek()
    }

    /// Jumps forward (positive) or back (negative) from the current position.
    func seek(by seconds: Double) {
        guard status == .ready, track != nil else { return }
        seek(to: position(at: Date()) + seconds)
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
        let v = SpotifyBridge.clampVolume(v)
        holdVolumeUntil = Date().addingTimeInterval(1)
        if v == playback.volume && !volumeInFlight && queuedVolume == nil { return }
        playback.volume = v
        queuedVolume = v
        sendQueuedVolume()
    }

    /// Adds `delta` to the volume, clamped to 0...100.
    func changeVolume(by delta: Int) {
        setVolume(playback.volume + delta)
    }

    private func sendQueuedVolume() {
        guard !volumeInFlight, let v = queuedVolume else { return }
        queuedVolume = nil
        volumeInFlight = true
        lastSentVolume = v
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
        launchSpotify(activate: false)
    }

    /// Brings Spotify to the front, opening its window. Launches it if it is not running.
    func showInSpotify() {
        guard live else { return }
        launchSpotify(activate: true)
    }

    private func launchSpotify(activate: Bool) {
        if !spotifyRunning {
            isLaunching = true
            launchTimeout?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.isLaunching = false }
            }
            launchTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        }
        bridge.launch(activate: activate) { [weak self] ok in
            guard let self, !ok, !self.spotifyRunning else { return }
            self.isLaunching = false
            self.spotifyStopped()
        }
    }

    /// Puts the open.spotify.com link of the current song on the clipboard.
    /// Returns false, and leaves the clipboard alone, for local files, ads and no song.
    @discardableResult
    func copyTrackLink() -> Bool {
        guard let url = trackURL else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        pasteboard.setString(url.absoluteString, forType: .URL)
        return true
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
            case .granted, .needsConsent, .unknown:
                self.refresh()
            }
        }
    }

    /// Used by the snapshot renderer: the state while the permission prompt is open.
    func setPreviewAskingPermission() {
        status = .notAuthorized
        isAskingPermission = true
    }

    /// Used by the snapshot renderer and previews.
    func setPreview(_ playback: Playback, artwork: NSImage?) {
        status = .ready
        isAskingPermission = false
        self.playback = playback
        self.positionDate = Date()
        self.artwork = artwork
        self.artworkColors = artwork.flatMap(ArtworkColors.init(image:))
    }
}

/// Pure helpers for the model, kept apart for tests.
enum PlayerMath {
    /// Clamps a seek target to 0...duration. A duration of 0 means unknown: no upper bound.
    static func clampPosition(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        var s = max(0, seconds)
        if duration > 0 { s = min(s, duration) }
        return s
    }

    /// The volume to show after Spotify reported `reported`. Spotify often reads a volume
    /// back one lower than it was set to; keep ours then, so the bar does not twitch.
    static func volumeToShow(reported: Int, local: Int, lastSent: Int?) -> Int {
        let reported = SpotifyBridge.clampVolume(reported)
        if let lastSent, local == lastSent, abs(reported - lastSent) <= 1 { return local }
        return reported
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
