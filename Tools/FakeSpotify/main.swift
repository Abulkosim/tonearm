// A stand-in for the Spotify desktop app, for Tonearm's end-to-end tests. Never shipped.
//
// It has bundle id com.spotify.client and answers the AppleScript terms in Spotify.sdef
// next to this file. The player lives in memory. Like Spotify, it posts the distributed
// notification com.spotify.client.PlaybackStateChanged when the song or play state changes.
// It appends one line per Apple Event it handles to ~/Library/Logs/TonearmE2E/fake-spotify.log,
// so a test can check what Tonearm sent.
//
// The test driver (`Tonearm --e2e`) changes its state with the distributed notification
// io.github.abulkosim.tonearm.e2e.control. See `handleControl`.
//
// Build: scripts/e2e.sh builds it with swiftc into build/e2e/Spotify.app.
import AppKit

let controlNotification = Notification.Name("io.github.abulkosim.tonearm.e2e.control")
let changedNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

// MARK: Log

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/TonearmE2E/fake-spotify.log")

/// Appends "<unix time> <pid> <event>" to the log.
func log(_ event: String) {
    let line = String(format: "%.3f %d ", Date().timeIntervalSince1970, getpid()) + event + "\n"
    let fm = FileManager.default
    try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
    guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
    handle.seekToEndOfFile()
    handle.write(Data(line.utf8))
    try? handle.close()
}

// MARK: Model

func fourCC(_ s: String) -> FourCharCode {
    s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}

enum PlayerState: String {
    case stopped, playing, paused

    /// Must match the enumerators in Spotify.sdef.
    var code: FourCharCode {
        switch self {
        case .stopped: return fourCC("kPSS")
        case .playing: return fourCC("kPSP")
        case .paused: return fourCC("kPSp")
        }
    }
}

/// The `track` class. Its object specifier is `current track of application`.
@objc(FakeTrack)
final class FakeTrack: NSObject {
    let id: String
    let title: String
    let artistName: String
    let albumName: String
    let artwork: String
    /// Milliseconds.
    let durationMS: Int
    /// Reading `artwork url` fails, like a property a local file does not have.
    let artworkFails: Bool

    init(id: String, title: String, artist: String, album: String, artwork: String, durationMS: Int,
         artworkFails: Bool = false) {
        self.id = id
        self.title = title
        self.artistName = artist
        self.albumName = album
        self.artwork = artwork
        self.durationMS = durationMS
        self.artworkFails = artworkFails
    }

    @objc var trackID: String { log("get id"); return id }
    @objc var name: String { log("get name"); return title }
    @objc var artist: String { log("get artist"); return artistName }
    @objc var album: String { log("get album"); return albumName }
    @objc var duration: Int { log("get duration"); return durationMS }

    @objc var artworkURL: String? {
        log("get artwork url")
        if artworkFails {
            NSScriptCommand.current()?.scriptErrorNumber = -1728 // errAENoSuchObject
            return nil
        }
        return artwork
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSPropertySpecifier(containerClassDescription: app, containerSpecifier: nil, key: "currentTrack")
    }
}

@objc(FakeSpotify)
final class FakeSpotify: NSObject, NSApplicationDelegate {
    static let shared = FakeSpotify()

    /// The start state. Tonearm's E2E driver expects these exact values after a launch.
    static let playlist = [
        FakeTrack(id: "spotify:track:0FakeTrackOne00000000", title: "Fake Song One", artist: "Fake Artist",
                  album: "Fake Album", artwork: "https://127.0.0.1:9/cover-one.jpg", durationMS: 201_000),
        FakeTrack(id: "spotify:track:0FakeTrackTwo00000000", title: "Fake Song Two", artist: "Second Artist",
                  album: "Second Album", artwork: "https://127.0.0.1:9/cover-two.jpg", durationMS: 154_500),
        FakeTrack(id: "spotify:track:0FakeTrackThree000000", title: "Fake Song Three", artist: "Third Artist",
                  album: "Third Album", artwork: "https://127.0.0.1:9/cover-three.jpg", durationMS: 300_000),
    ]

    private var playlist = FakeSpotify.playlist
    private var index = 0
    private var track: FakeTrack { playlist[index] }
    private var state = PlayerState.paused
    /// Position at `anchorDate`, advanced by the clock while playing.
    private var anchor = 12.5
    private var anchorDate = Date()
    private var volume = 64
    private var shuffle = false
    private var repeatOn = false
    /// The next `player state` read blocks the app for this long.
    private var stallSeconds = 0.0

    private static let scriptKeys: Set<String> = [
        "currentTrack", "playerState", "playerPosition", "soundVolume", "shuffling", "repeating",
    ]

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        Self.scriptKeys.contains(key)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleControl(_:)), name: controlNotification,
            object: nil, suspensionBehavior: .deliverImmediately
        )
        log("launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("terminating")
    }

    // MARK: Properties

    private var position: Double {
        var p = anchor
        if state == .playing { p += Date().timeIntervalSince(anchorDate) }
        return min(max(0, p), Double(track.durationMS) / 1000)
    }

    private func setPosition(_ p: Double) {
        anchor = max(0, p)
        anchorDate = Date()
    }

    @objc var currentTrack: FakeTrack {
        log("get current track")
        return track
    }

    @objc var playerState: NSNumber {
        log("get player state")
        if stallSeconds > 0 {
            let seconds = stallSeconds
            stallSeconds = 0
            log("stall begin")
            Thread.sleep(forTimeInterval: seconds)
            log("stall end")
        }
        return NSNumber(value: state.code)
    }

    @objc var playerPosition: Double {
        get {
            log("get player position")
            return position
        }
        set {
            log(String(format: "set player position %.2f", newValue))
            setPosition(newValue)
        }
    }

    @objc var soundVolume: Int {
        get {
            log("get sound volume")
            return volume
        }
        set {
            log("set sound volume \(newValue)")
            volume = min(100, max(0, newValue))
        }
    }

    @objc var shuffling: Bool {
        get {
            log("get shuffling")
            return shuffle
        }
        set {
            log("set shuffling \(newValue)")
            shuffle = newValue
        }
    }

    @objc var repeating: Bool {
        get {
            log("get repeating")
            return repeatOn
        }
        set {
            log("set repeating \(newValue)")
            repeatOn = newValue
        }
    }

    // MARK: Commands

    func perform(_ command: String) {
        log(command)
        switch command {
        case "play":
            setState(.playing)
        case "playpause":
            setState(state == .playing ? .paused : .playing)
        case "next track":
            index = (index + 1) % playlist.count
            setPosition(0)
            if state == .stopped { state = .playing }
        case "previous track":
            index = (index + playlist.count - 1) % playlist.count
            setPosition(0)
            if state == .stopped { state = .playing }
        default:
            break
        }
        postChange()
    }

    private func setState(_ new: PlayerState) {
        let p = position
        state = new
        setPosition(p)
    }

    /// Posts what Spotify posts: the state, and the track unless stopped. Duration is in
    /// milliseconds and position in seconds.
    private func postChange() {
        var info: [String: Any] = ["Player State": state.rawValue.capitalized]
        if state != .stopped {
            info["Track ID"] = track.id
            info["Name"] = track.title
            info["Artist"] = track.artistName
            info["Album"] = track.albumName
            info["Duration"] = NSNumber(value: track.durationMS)
            info["Playback Position"] = NSNumber(value: position)
        }
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: "com.spotify.client", userInfo: info, deliverImmediately: true
        )
        log("posted \(state.rawValue)")
    }

    // MARK: Test control

    /// userInfo: "action", "token", and string arguments.
    /// - load: replaces the current track and state. Keys: id, name, artist, album, artwork,
    ///   duration (ms), artworkFails ("1"), state, position, notify ("1" posts a change).
    /// - stall: the next `player state` read blocks for "seconds".
    /// - quit: posts a paused change, as Spotify does when it quits, then quits.
    /// - ping: does nothing.
    /// Every action logs "control <action> <token>" once it took effect.
    @objc private func handleControl(_ note: Notification) {
        let info = note.userInfo as? [String: String] ?? [:]
        let action = info["action"] ?? ""
        let token = info["token"] ?? ""
        switch action {
        case "load":
            let loaded = FakeTrack(
                id: info["id"] ?? "", title: info["name"] ?? "", artist: info["artist"] ?? "",
                album: info["album"] ?? "", artwork: info["artwork"] ?? "",
                durationMS: Int(info["duration"] ?? "") ?? 0, artworkFails: info["artworkFails"] == "1"
            )
            playlist[index] = loaded
            state = info["state"].flatMap(PlayerState.init(rawValue:)) ?? state
            setPosition(Double(info["position"] ?? "") ?? 0)
            log("control \(action) \(token)")
            if info["notify"] == "1" { postChange() }
        case "stall":
            stallSeconds = Double(info["seconds"] ?? "") ?? 0
            log("control \(action) \(token)")
        case "quit":
            if state == .playing { state = .paused }
            postChange()
            log("control \(action) \(token)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        default:
            log("control \(action) \(token)")
        }
    }
}

// MARK: Script commands

@objc(FakePlayCommand)
final class FakePlayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        FakeSpotify.shared.perform("play")
        return nil
    }
}

@objc(FakePlayPauseCommand)
final class FakePlayPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        FakeSpotify.shared.perform("playpause")
        return nil
    }
}

@objc(FakeNextCommand)
final class FakeNextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        FakeSpotify.shared.perform("next track")
        return nil
    }
}

@objc(FakePreviousCommand)
final class FakePreviousCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        FakeSpotify.shared.perform("previous track")
        return nil
    }
}

let app = NSApplication.shared
app.delegate = FakeSpotify.shared
app.run()
