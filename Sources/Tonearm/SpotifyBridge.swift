import AppKit
import CoreServices

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

    /// Maps an AppleScript / Apple Event error number to a bridge error.
    static func from(code: Int, message: String) -> BridgeError {
        switch code {
        case -1743, -1744:
            // errAEEventNotPermitted, errAEEventWouldRequireUserConsent
            return .notAuthorized
        case -600, -609, -903, -10661:
            // procNotFound, connectionInvalid, noPortErr: Spotify quit (or is quitting) mid-call.
            return .notRunning
        default:
            return .script(code, message)
        }
    }
}

/// What a PlaybackStateChanged notification tells us. It has no artwork URL or volume.
struct NowPlayingUpdate: Equatable {
    var state: PlayState
    var track: Track?
    /// Seconds, if the notification had it.
    var position: Double?

    /// Parses the userInfo of "com.spotify.client.PlaybackStateChanged".
    /// Keys: "Player State" (Playing/Paused/Stopped), "Track ID", "Name", "Artist", "Album",
    /// "Duration" (ms), "Playback Position" (s).
    static func parse(_ info: [AnyHashable: Any]) -> NowPlayingUpdate? {
        guard let rawState = info["Player State"] as? String,
              let state = PlayState(rawValue: rawState.lowercased())
        else { return nil }
        var update = NowPlayingUpdate(state: state, track: nil, position: number(info["Playback Position"]))
        if let id = info["Track ID"] as? String, !id.isEmpty, state != .stopped {
            update.track = Track(
                id: id,
                title: info["Name"] as? String ?? "",
                artist: info["Artist"] as? String ?? "",
                album: info["Album"] as? String ?? "",
                artworkURL: nil,
                duration: (number(info["Duration"]) ?? 0) / 1000
            )
        }
        return update
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.replacingOccurrences(of: ",", with: "."))
        default: return nil
        }
    }
}

/// Local model of the playhead: a position anchored at a date, advanced by wall-clock time while playing.
struct PositionClock: Equatable {
    var position: Double
    var date: Date
    var isPlaying: Bool
    /// Seconds; 0 or nil means unknown, so no upper clamp.
    var duration: Double?

    func position(at time: Date) -> Double {
        var p = position
        if isPlaying { p += max(0, time.timeIntervalSince(date)) }
        if let duration, duration > 0 { p = min(p, duration) }
        return max(0, p)
    }

    /// The clock to use after Spotify reported `reported` seconds at `time`.
    /// While playing, differences under `tolerance` are ignored so AppleScript latency
    /// does not make the bar step backwards. A state change always re-anchors.
    func reconciled(reported: Double, at time: Date, isPlaying playing: Bool, tolerance: Double) -> PositionClock {
        let local = position(at: time)
        let keepLocal = abs(local - reported) < tolerance
        if keepLocal && playing == isPlaying { return self }
        return PositionClock(position: keepLocal ? local : max(0, reported), date: time,
                             isPlaying: playing, duration: duration)
    }
}

/// Talks to the Spotify desktop app through its AppleScript dictionary.
/// Every Apple Event goes through one serial background queue. Scripts check
/// `is running` first, so they never launch Spotify by accident.
final class SpotifyBridge {
    static let bundleID = "com.spotify.client"
    static let changedNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    enum Command: Equatable {
        case playPause, next, previous
        case seek(Double)
        case volume(Int)

        var appleScript: String {
            switch self {
            case .playPause: return "playpause"
            case .next: return "next track"
            case .previous: return "previous track"
            case .seek(let s): return "set player position to \(max(0, s))"
            case .volume(let v): return "set sound volume to \(min(100, max(0, v)))"
            }
        }
    }

    enum Permission: Equatable {
        case granted, denied, notRunning
        /// AEDeterminePermissionToAutomateTarget gave an unexpected status; fall back to AppleScript.
        case unknown(Int32)

        static func from(_ status: OSStatus) -> Permission {
            switch status {
            case 0: return .granted
            case -1743, -1744: return .denied
            case -600: return .notRunning
            default: return .unknown(status)
            }
        }
    }

    private let queue = DispatchQueue(label: "tonearm.applescript", qos: .userInitiated)
    // Only touched on `queue`.
    private var readScript: NSAppleScript?
    private var authorized = false

    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).contains { !$0.isTerminated }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    static let notRunningReply = "tonearm:not-running"

    static let readSource = """
    if application id "com.spotify.client" is not running then return "\(notRunningReply)"
    tell application id "com.spotify.client"
        with timeout of 5 seconds
            set s to player state as string
            set p to player position
            set v to sound volume
            if s is "stopped" then return {s, p, v}
            try
                set t to current track
                return {s, p, v, id of t, name of t, artist of t, album of t, artwork url of t, duration of t}
            end try
            return {s, p, v}
        end timeout
    end tell
    """

    static func source(for command: Command) -> String {
        """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                with timeout of 5 seconds
                    \(command.appleScript)
                end timeout
            end tell
        end if
        """
    }

    /// Reads player state, track, position and volume. `readAt` is the best guess of
    /// when Spotify sampled the position. Calls back on the main queue.
    func fetch(_ done: @escaping (Result<Playback, BridgeError>, _ readAt: Date) -> Void) {
        guard isRunning else { return done(.failure(.notRunning), Date()) }
        queue.async {
            let result: Result<Playback, BridgeError>
            let start = Date()
            if let denied = self.ensurePermission() {
                result = .failure(denied)
            } else {
                if self.readScript == nil { self.readScript = NSAppleScript(source: Self.readSource) }
                result = Self.execute(self.readScript).flatMap(Self.parse)
                if result == .failure(.notAuthorized) { self.authorized = false }
            }
            let readAt = start.addingTimeInterval(Date().timeIntervalSince(start) / 2)
            DispatchQueue.main.async { done(result, readAt) }
        }
    }

    func send(_ command: Command, then done: (() -> Void)? = nil) {
        guard isRunning else { return }
        queue.async {
            _ = Self.execute(NSAppleScript(source: Self.source(for: command)))
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    /// Asks macOS whether Tonearm may send Apple Events to Spotify. With `ask`, macOS shows
    /// its Automation prompt if the user has not decided yet (only once; after a denial the
    /// answer can only change in System Settings). Calls back on the main queue.
    func checkPermission(ask: Bool, _ done: @escaping (Permission) -> Void) {
        guard isRunning else { return done(.notRunning) }
        queue.async {
            let p = Self.determinePermission(ask: ask)
            self.authorized = p == .granted
            DispatchQueue.main.async { done(p) }
        }
    }

    /// Launches Spotify in the background. Calls back on the main queue with success.
    func launch(_ done: @escaping (Bool) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            return done(false)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            let ok = app != nil && error == nil
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Calls `handler` on the main thread for every PlaybackStateChanged notification.
    /// Keep the returned object alive for as long as you want updates.
    static func observeChanges(_ handler: @escaping (NowPlayingUpdate?) -> Void) -> AnyObject {
        ChangeObserver(handler: handler)
    }

    // MARK: Private

    /// Runs on `queue`. Returns an error if the script must not run.
    private func ensurePermission() -> BridgeError? {
        guard !authorized else { return nil }
        switch Self.determinePermission(ask: true) {
        case .granted:
            authorized = true
            return nil
        case .denied:
            return .notAuthorized
        case .notRunning:
            return .notRunning
        case .unknown:
            // Let the AppleScript call trigger the prompt itself.
            return nil
        }
    }

    private static func determinePermission(ask: Bool) -> Permission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let coreClass: AEEventClass = 0x636F_7265 // 'core'
        let getData: AEEventID = 0x6765_7464 // 'getd'
        return .from(AEDeterminePermissionToAutomateTarget(target.aeDesc, coreClass, getData, ask))
    }

    private static func execute(_ script: NSAppleScript?) -> Result<NSAppleEventDescriptor, BridgeError> {
        guard let script else { return .failure(.script(0, "could not create script")) }
        var info: NSDictionary?
        let out = script.executeAndReturnError(&info)
        if let info {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            return .failure(.from(code: code, message: (info[NSAppleScript.errorMessage] as? String) ?? ""))
        }
        return .success(out)
    }

    private static let textTypes: Set<DescType> = [
        0x7574_7874, // 'utxt'
        0x7574_6638, // 'utf8'
        0x5445_5854, // 'TEXT'
    ]

    /// Parses the reply of `readSource`.
    static func parse(_ d: NSAppleEventDescriptor) -> Result<Playback, BridgeError> {
        if textTypes.contains(d.descriptorType) {
            return d.stringValue == notRunningReply
                ? .failure(.notRunning) : .failure(.script(0, "unexpected reply"))
        }
        guard d.numberOfItems >= 3 else { return .failure(.script(0, "unexpected reply")) }
        func item(_ i: Int) -> NSAppleEventDescriptor? { d.atIndex(i) }
        func str(_ i: Int) -> String { item(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double {
            guard let x = item(i) else { return 0 }
            if textTypes.contains(x.descriptorType) {
                return Double((x.stringValue ?? "").replacingOccurrences(of: ",", with: ".")) ?? 0
            }
            let v = x.doubleValue
            return v.isFinite ? v : 0
        }
        let state = PlayState(rawValue: str(1)) ?? .stopped
        var playback = Playback(state: state, track: nil, position: max(0, num(2)),
                                volume: min(100, max(0, Int(num(3).rounded()))))
        if d.numberOfItems >= 9, state != .stopped {
            let art = str(8)
            playback.track = Track(
                id: str(4),
                title: str(5),
                artist: str(6),
                album: str(7),
                artworkURL: art.isEmpty ? nil : URL(string: art),
                duration: num(9) / 1000
            )
        }
        return .success(playback)
    }
}

/// Distributed notifications are delivered immediately even while Tonearm is inactive,
/// which the block-based API does not guarantee.
private final class ChangeObserver: NSObject {
    private let handler: (NowPlayingUpdate?) -> Void

    init(handler: @escaping (NowPlayingUpdate?) -> Void) {
        self.handler = handler
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed(_:)), name: SpotifyBridge.changedNotification,
            object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func changed(_ note: Notification) {
        handler(note.userInfo.flatMap(NowPlayingUpdate.parse))
    }
}
