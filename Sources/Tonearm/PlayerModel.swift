import AppKit
import Combine

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
    /// When `playback.position` was read, used to advance the progress bar locally.
    @Published private(set) var positionDate = Date()
    @Published private(set) var artwork: NSImage?

    let bridge: SpotifyBridge
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var artworkURL: URL?

    var track: Track? { playback.track }
    var isPlaying: Bool { playback.state == .playing }

    init(bridge: SpotifyBridge = SpotifyBridge(), live: Bool = true) {
        self.bridge = bridge
        guard live else { return }

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: SpotifyBridge.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyBridge.bundleID else { return }
                Task { @MainActor in self?.refresh() }
            })
        }
        // Light fallback polling in case a notification is missed.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Current position, advanced by wall-clock time while playing.
    func position(at date: Date) -> Double {
        guard isPlaying else { return playback.position }
        let p = playback.position + date.timeIntervalSince(positionDate)
        return min(p, track?.duration ?? p)
    }

    func refresh() {
        guard bridge.isInstalled else { status = .notInstalled; return }
        bridge.fetch { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let p):
                self.status = .ready
                if p != self.playback { self.playback = p }
                self.positionDate = Date()
                self.loadArtwork(p.track?.artworkURL)
            case .failure(.notRunning):
                self.status = .notRunning
                self.playback = Playback(state: .stopped, track: nil, position: 0, volume: self.playback.volume)
            case .failure(.notAuthorized):
                self.status = .notAuthorized
            case .failure:
                break
            }
        }
    }

    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkURL = url
        guard let url else { artwork = nil; return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            Task { @MainActor [weak self] in
                guard let self, self.artworkURL == url else { return }
                self.artwork = image
            }
        }.resume()
    }

    // MARK: Commands

    func playPause() {
        playback.position = position(at: Date())
        positionDate = Date()
        playback.state = isPlaying ? .paused : .playing
        bridge.send("playpause") { [weak self] in self?.refresh() }
    }

    func next() { bridge.send("next track") { [weak self] in self?.refresh() } }
    func previous() { bridge.send("previous track") { [weak self] in self?.refresh() } }

    func openSpotify() { bridge.launch() }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Used by the snapshot renderer and previews.
    func setPreview(_ playback: Playback, artwork: NSImage?) {
        status = .ready
        self.playback = playback
        self.positionDate = Date()
        self.artwork = artwork
    }
}
