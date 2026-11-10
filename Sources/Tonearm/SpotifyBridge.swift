import AppKit

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    /// Seconds.
    var duration: Double
}

enum PlayState: String {
    case playing, paused, stopped
}

struct Playback: Equatable {
    var state: PlayState
    var track: Track?
    /// Seconds.
    var position: Double
    /// 0...100
    var volume: Int
}

enum BridgeError: Error, Equatable {
    case notRunning
    /// The user denied Automation access (errAEEventNotPermitted, -1743).
    case notAuthorized
    case script(Int, String)
}

/// Talks to the Spotify desktop app through its AppleScript dictionary.
/// Every call runs on one serial background queue.
final class SpotifyBridge {
    static let bundleID = "com.spotify.client"
    static let changedNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private let queue = DispatchQueue(label: "tonearm.applescript", qos: .userInitiated)

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    private static let readScript = """
    tell application id "com.spotify.client"
        set s to player state as string
        set p to player position
        set v to sound volume
        if s is "stopped" then return {s, p, v}
        set t to current track
        return {s, p, v, id of t, name of t, artist of t, album of t, artwork url of t, duration of t}
    end tell
    """

    func fetch(_ done: @escaping (Result<Playback, BridgeError>) -> Void) {
        guard isRunning else { return done(.failure(.notRunning)) }
        queue.async {
            let result = Self.execute(Self.readScript).flatMap { Self.parse($0) }
            DispatchQueue.main.async { done(result) }
        }
    }

    func send(_ command: String, then done: (() -> Void)? = nil) {
        guard isRunning else { return }
        queue.async {
            _ = Self.execute("tell application id \"com.spotify.client\" to \(command)")
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }
    func seek(to seconds: Double) { send("set player position to \(max(0, seconds))") }
    func setVolume(_ volume: Int) { send("set sound volume to \(min(100, max(0, volume)))") }

    func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    private static func execute(_ source: String) -> Result<NSAppleEventDescriptor, BridgeError> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.script(0, "could not compile script"))
        }
        var info: NSDictionary?
        let out = script.executeAndReturnError(&info)
        if let info {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 { return .failure(.notAuthorized) }
            if code == -600 { return .failure(.notRunning) }
            return .failure(.script(code, (info[NSAppleScript.errorMessage] as? String) ?? ""))
        }
        return .success(out)
    }

    static func parse(_ d: NSAppleEventDescriptor) -> Result<Playback, BridgeError> {
        func str(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double { Double(str(i).replacingOccurrences(of: ",", with: ".")) ?? 0 }
        guard d.numberOfItems >= 3 else { return .failure(.script(0, "unexpected reply")) }
        let state = PlayState(rawValue: str(1)) ?? .stopped
        var playback = Playback(state: state, track: nil, position: num(2), volume: Int(num(3)))
        if d.numberOfItems >= 9 {
            playback.track = Track(
                id: str(4),
                title: str(5),
                artist: str(6),
                album: str(7),
                artworkURL: URL(string: str(8)),
                duration: num(9) / 1000
            )
        }
        return .success(playback)
    }
}
