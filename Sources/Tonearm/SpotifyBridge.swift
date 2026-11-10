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
    var shuffling = false
    var repeating = false
}

/// Turns Spotify ids into links people can open in a browser.
enum SpotifyLink {
    /// Kinds of item that have a public page on open.spotify.com.
    static let shareableKinds: Set<String> = ["track", "episode", "album", "artist", "playlist", "show"]

    /// "spotify:track:XYZ" -> https://open.spotify.com/track/XYZ. Also accepts an
    /// open.spotify.com URL. Local files, ads and anything unknown give nil.
    static func webURL(for id: String) -> URL? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("https://open.spotify.com/") { return URL(string: id) }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify", shareableKinds.contains(String(parts[1])) else {
            return nil
        }
        let key = parts[2]
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(key)")
    }

    /// Cover URL Tonearm can load. Upgrades http to https (App Transport Security blocks
    /// plain http) and drops anything that is not a web URL, such as local file art.
    static func artworkURL(_ raw: String) -> URL? {
        var raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("http://") { raw = "https://" + raw.dropFirst("http://".count) }
        guard raw.lowercased().hasPrefix("https://"), let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }
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
        let id = info["Track ID"] as? String ?? ""
        let name = info["Name"] as? String ?? ""
        if state != .stopped, !(id.isEmpty && name.isEmpty) {
            update.track = Track(
                id: id,
                title: name,
                artist: info["Artist"] as? String ?? "",
                album: info["Album"] as? String ?? "",
                artworkURL: nil,
                duration: max(0, (number(info["Duration"]) ?? 0) / 1000)
            )
        }
        return update
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return finiteOrNil(n.doubleValue)
        case let s as String: return parseNumber(s)
        default: return nil
        }
    }
}

/// Parses "12.5", "12,5" and " 12 " the same way in every locale. Nil for junk, NaN and infinity.
func parseNumber(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    return Double(t).flatMap(finiteOrNil)
}

func finiteOrNil(_ x: Double) -> Double? { x.isFinite ? x : nil }

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
        case shuffle(Bool)
        case repeating(Bool)

        var appleScript: String {
            switch self {
            case .playPause: return "playpause"
            case .next: return "next track"
            case .previous: return "previous track"
            case .seek(let s):
                // AppleScript source always uses a dot for decimals. String(format:) without a
                // locale does too, and never switches to exponent notation.
                return "set player position to " + String(format: "%.2f", s.isFinite ? max(0, s) : 0)
            case .volume(let v): return "set sound volume to \(SpotifyBridge.clampVolume(v))"
            case .shuffle(let on): return "set shuffling to \(on)"
            case .repeating(let on): return "set repeating to \(on)"
            }
        }
    }

    enum Permission: Equatable {
        case granted, denied, notRunning
        /// The user has not decided yet (errAEEventWouldRequireUserConsent, from an `ask: false` check).
        case needsConsent
        /// AEDeterminePermissionToAutomateTarget gave an unexpected status; fall back to AppleScript.
        case unknown(Int32)

        static func from(_ status: OSStatus) -> Permission {
            switch status {
            case 0: return .granted
            case -1743: return .denied
            case -1744: return .needsConsent
            case -600: return .notRunning
            default: return .unknown(status)
            }
        }
    }

    /// Serial, so Apple Events never overlap. `.workItem` drains the autorelease pool after
    /// every script; the default only drains when the thread goes idle, which polling can delay.
    private let queue = DispatchQueue(label: "tonearm.applescript", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    // Only touched on `queue`.
    private var readScript: NSAppleScript?
    private var commandScripts: [String: NSAppleScript] = [:]
    private var authorized = false

    /// Safe on any thread.
    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).contains { !$0.isTerminated }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    static let notRunningReply = "tonearm:not-running"

    /// Apple Event errors that must reach Swift instead of being swallowed by a `try` in the
    /// script: timeout, permission, and Spotify going away.
    static let fatalErrorNumbers = [-1712, -1743, -1744, -600, -609, -903]

    /// Reply layout: {state, position, volume, shuffling, repeating} and, when there is a
    /// current track, {id, name, artist, album, artwork url, duration ms} after that.
    /// Optional properties are read one by one, so a podcast, ad or local file that lacks
    /// one still shows the rest.
    static let readSource: String = {
        let fatal = SpotifyBridge.fatalErrorNumbers.map { String($0) }.joined(separator: ", ")
        func get(_ variable: String, _ expression: String, default value: String) -> String {
            """
                    set \(variable) to \(value)
                    try
                        set \(variable) to \(expression)
                    on error number n
                        if n is in {\(fatal)} then error number n
                    end try

            """
        }
        let head = """
        if application id "com.spotify.client" is not running then return "\(SpotifyBridge.notRunningReply)"
        tell application id "com.spotify.client"
            with timeout of 5 seconds
                set s to player state as string
                set p to player position
                set v to sound volume

        """
        let currentTrack = """
                if s is "stopped" then return {s, p, v, sh, rp}
                try
                    set t to current track
                on error number n
                    if n is in {\(fatal)} then error number n
                    return {s, p, v, sh, rp}
                end try

        """
        let tail = """
                return {s, p, v, sh, rp, tid, tn, ta, tal, tu, td}
            end timeout
        end tell
        """
        let parts: [String] = [
            head,
            get("sh", "shuffling", default: "false"),
            get("rp", "repeating", default: "false"),
            currentTrack,
            get("tid", "id of t", default: "\"\""),
            get("tn", "name of t", default: "\"\""),
            get("ta", "artist of t", default: "\"\""),
            get("tal", "album of t", default: "\"\""),
            get("tu", "artwork url of t", default: "\"\""),
            get("td", "duration of t", default: "0"),
            tail,
        ]
        return parts.joined()
    }()

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
            // Spotify may have quit while this waited in the queue. Sending to a process that
            // just died makes AppleScript relaunch it, so check again right before.
            guard self.isRunning else {
                return DispatchQueue.main.async { done(.failure(.notRunning), start) }
            }
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

    /// Sends a command. `done` always runs on the main queue, even when Spotify is not
    /// running, so callers that track an in-flight send never get stuck.
    func send(_ command: Command, then done: (() -> Void)? = nil) {
        guard isRunning else {
            if let done { DispatchQueue.main.async(execute: done) }
            return
        }
        queue.async {
            if self.isRunning {
                _ = Self.execute(self.script(for: command))
            }
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

    /// Launches Spotify, in the background unless `activate`. If it is already running,
    /// `activate` brings it to the front and reopens its window. Calls back on the main queue.
    func launch(activate: Bool = false, _ done: @escaping (Bool) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            return done(false)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
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

    /// Runs on `queue`. Compiled once per command text; seek and volume values vary, so
    /// those are compiled each time and not kept.
    private func script(for command: Command) -> NSAppleScript? {
        let source = Self.source(for: command)
        switch command {
        case .seek, .volume:
            return NSAppleScript(source: source)
        default:
            if let cached = commandScripts[source] { return cached }
            let script = NSAppleScript(source: source)
            commandScripts[source] = script
            return script
        }
    }

    /// Runs on `queue`, never on the main thread: AEDeterminePermissionToAutomateTarget
    /// blocks until the user answers the prompt, and can stall while Spotify is starting.
    /// Returns an error if the script must not run.
    private func ensurePermission() -> BridgeError? {
        guard !authorized else { return nil }
        // Ask without a prompt first. Only an undecided user gets the prompt, once.
        var permission = Self.determinePermission(ask: false)
        if permission == .needsConsent { permission = Self.determinePermission(ask: true) }
        switch permission {
        case .granted:
            authorized = true
            return nil
        case .denied:
            return .notAuthorized
        case .notRunning:
            return .notRunning
        case .needsConsent, .unknown:
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
        guard d.numberOfItems >= 5 else { return .failure(.script(0, "unexpected reply")) }
        func item(_ i: Int) -> NSAppleEventDescriptor? { d.atIndex(i) }
        func str(_ i: Int) -> String { item(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double {
            guard let x = item(i) else { return 0 }
            if textTypes.contains(x.descriptorType) { return parseNumber(x.stringValue ?? "") ?? 0 }
            return finiteOrNil(x.doubleValue) ?? 0
        }
        func bool(_ i: Int) -> Bool {
            guard let x = item(i) else { return false }
            if textTypes.contains(x.descriptorType) { return x.stringValue?.lowercased() == "true" }
            return x.booleanValue
        }
        let state = PlayState(rawValue: str(1).lowercased()) ?? .stopped
        var playback = Playback(state: state, track: nil, position: max(0, num(2)),
                                volume: clampVolume(Int(num(3).rounded())),
                                shuffling: bool(4), repeating: bool(5))
        if d.numberOfItems >= 11, state != .stopped {
            let id = str(6), title = str(7)
            // Spotify with nothing loaded reports a track with every field empty.
            if !(id.isEmpty && title.isEmpty) {
                playback.track = Track(
                    id: id,
                    title: title,
                    artist: str(8),
                    album: str(9),
                    artworkURL: SpotifyLink.artworkURL(str(10)),
                    duration: max(0, num(11) / 1000)
                )
            }
        }
        return .success(playback)
    }

    static func clampVolume(_ v: Int) -> Int { min(100, max(0, v)) }
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
