import AppKit
import CoreServices

/// `Tonearm --e2e <dir>` runs end-to-end scenarios against the fake Spotify in
/// Tools/FakeSpotify, through the real SpotifyBridge and PlayerModel: real AppleScript, real
/// Apple Events, real distributed notifications. It prints one line per check, writes them
/// to <dir>/report.txt, and exits 0 only if every check passed. Run it with scripts/e2e.sh.
///
/// It refuses to run unless the app registered as com.spotify.client is the fake, so it
/// never drives a real Spotify.
enum E2E {
    @MainActor
    static func run(outputDir: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let report = E2EReport(dir: outputDir)
        let timeout = E2ERunner.overallTimeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            report.write("FAIL timed out after \(Int(timeout)) s in: \(report.step)")
            exit(2)
        }
        let runner = E2ERunner(report: report)
        Task { @MainActor in
            let failed = await runner.runAll()
            exit(failed == 0 ? 0 : 1)
        }
        app.run()
        exit(1)
    }
}

/// Lines go to stdout and to report.txt as they are written, so a timeout keeps them.
final class E2EReport: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private var currentStep = "start"

    init(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("report.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
    }

    var step: String {
        get { locked { currentStep } }
        set { locked { currentStep = newValue } }
    }

    func write(_ line: String) {
        locked {
            print(line)
            fflush(stdout)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The fake's command log: "<unix time> <pid> <event>" per line.
struct FakeSpotifyLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TonearmE2E/fake-spotify.log")

    /// The end of the log now. Pass it to `events(since:)`.
    func mark() -> Int {
        (try? Data(contentsOf: Self.url).count) ?? 0
    }

    /// Events logged after `mark`, without time and pid.
    func events(since mark: Int) -> [String] {
        guard let data = try? Data(contentsOf: Self.url), data.count > mark else { return [] }
        return String(decoding: data[mark...], as: UTF8.self).split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            return parts.count == 3 ? String(parts[2]) : String(line)
        }
    }
}

/// A song the driver loads into the fake.
struct E2ESong {
    var id: String
    var name: String
    var artist = ""
    var album = ""
    var artwork = ""
    var durationMS = 0
    var artworkFails = false
}

@MainActor
final class E2ERunner {
    static let overallTimeout: TimeInterval = 300
    /// Checks a full passing run makes, not counting this one. A run that makes fewer fails,
    /// so deleting a scenario or a check can't pass. Raise it when you add checks.
    static let minimumChecks = 102
    static let controlNotification = Notification.Name("io.github.abulkosim.tonearm.e2e.control")

    /// The fake's state right after a launch. Keep in step with Tools/FakeSpotify/main.swift.
    static let first = E2ESong(id: "spotify:track:0FakeTrackOne00000000", name: "Fake Song One",
                               artist: "Fake Artist", album: "Fake Album",
                               artwork: "https://127.0.0.1:9/cover-one.jpg", durationMS: 201_000)
    static let secondName = "Fake Song Two"
    static let firstPosition = 12.5
    static let firstVolume = 64

    private let report: E2EReport
    private let log = FakeSpotifyLog()
    private var model: PlayerModel!
    private var bridge: SpotifyBridge { model.bridge }
    private var passed = 0
    private var failed = 0
    private var updates: [NowPlayingUpdate] = []
    private var observer: AnyObject?
    /// Every command the scenarios expected the fake to get, in order.
    private var expectedCommands: [String] = []

    init(report: E2EReport) {
        self.report = report
    }

    /// Returns the number of failed checks.
    func runAll() async -> Int {
        guard checkFakeOnly() else { return 1 }
        let start = log.mark()
        let scenarios: [(String, @MainActor () async -> Void)] = [
            ("Spotify not running at start", notRunningAtStart),
            ("launch and first read", launchAndRead),
            ("commands", commands),
            ("notification", notification),
            ("long and non-Latin text", longAndNonLatin),
            ("ad", ad),
            ("podcast episode", podcast),
            ("local file without artwork", localFile),
            ("nothing loaded and stopped", nothingLoaded),
            ("quit in the middle of a read", quitMidRead),
            ("relaunch", relaunch),
            ("quit while playing", quitWhilePlaying),
        ]
        for (name, scenario) in scenarios {
            report.step = name
            report.write("== \(name)")
            await scenario()
        }
        report.step = "end"
        report.write("== end")
        await checkAllCommands(since: start)
        await killFake()
        let ran = passed + failed
        check(ran >= Self.minimumChecks, "at least \(Self.minimumChecks) checks ran", "\(ran)")
        report.write("\(passed + failed) checks, \(failed) failed")
        return failed
    }

    // MARK: Scenarios

    private func notRunningAtStart() async {
        await killFake()
        let defaults = UserDefaults(suiteName: "io.github.abulkosim.tonearm.e2e") ?? .standard
        defaults.removePersistentDomain(forName: "io.github.abulkosim.tonearm.e2e")
        model = PlayerModel(bridge: SpotifyBridge(), settings: AppSettings(defaults: defaults), live: true)
        observer = SpotifyBridge.observeChanges { [weak self] update in
            MainActor.assumeIsolated {
                if let update { self?.updates.append(update) }
            }
        }
        check(bridge.isInstalled, "the fake is found as com.spotify.client")
        check(model.status == .notRunning, "status is notRunning", state())
        check(!model.spotifyRunning, "spotifyRunning is false")

        // The scripts' own guards, run directly, past the bridge's isRunning check.
        let read = runScript(SpotifyBridge.readSource)
        check(read.error == nil && read.reply?.stringValue == SpotifyBridge.notRunningReply,
              "the read script answers \(SpotifyBridge.notRunningReply)",
              "reply \(read.reply?.stringValue ?? "nil"), error \(read.error.map(String.init) ?? "nil")")
        let command = runScript(SpotifyBridge.source(for: .playPause))
        check(command.error == nil, "a command script does nothing", "error \(command.error.map(String.init) ?? "nil")")

        let result = await fetch()
        check(result == .failure(.notRunning), "a fetch fails with notRunning", "\(result)")
        model.playPause()
        model.next()
        await pause(2)
        check(fakeApps().isEmpty, "nothing launched Spotify")
    }

    private func launchAndRead() async {
        model.openSpotify()
        check(model.isLaunching, "isLaunching while Spotify starts")
        guard await waitFor("Spotify launched", timeout: 15, { !self.fakeApps().isEmpty }) else { return }
        reportPermission()
        guard await waitFor("status becomes ready", timeout: 20, { self.model.status == .ready }) else { return }
        await waitFor("the first read shows the fake's song", { self.model.track?.id == Self.first.id })
        let p = model.playback
        check(p.state == .paused, "state paused", "\(p.state)")
        check(p.track?.title == Self.first.name, "title", p.track?.title ?? "nil")
        check(p.track?.artist == Self.first.artist, "artist", p.track?.artist ?? "nil")
        check(p.track?.album == Self.first.album, "album", p.track?.album ?? "nil")
        check(p.track?.artworkURL == URL(string: Self.first.artwork), "artwork url",
              p.track?.artworkURL?.absoluteString ?? "nil")
        check(p.track?.duration == 201, "duration 201 s from 201000 ms", "\(p.track?.duration ?? -1)")
        check(abs(p.position - Self.firstPosition) < 0.01, "position 12.5", "\(p.position)")
        check(p.volume == Self.firstVolume, "volume 64", "\(p.volume)")
        check(!p.shuffling && !p.repeating, "shuffle and repeat off")
        check(model.trackURL?.absoluteString == "https://open.spotify.com/track/0FakeTrackOne00000000",
              "share link", model.trackURL?.absoluteString ?? "nil")
        check(!model.isLaunching, "isLaunching cleared")
    }

    private func commands() async {
        guard model.status == .ready else { return check(false, "player ready", state()) }

        var mark = log.mark()
        model.playPause()
        await expectEvent("playpause", since: mark)
        await waitFor("shows playing", { self.model.playback.state == .playing })

        mark = log.mark()
        model.playPause()
        await expectEvent("playpause", since: mark)
        await waitFor("shows paused", { self.model.playback.state == .paused })

        // `play` is sent after a ⌃⌥P launch; the model only reaches it from there.
        mark = log.mark()
        await send(.play)
        await expectEvent("play", since: mark)
        await waitFor("shows playing after play", { self.model.playback.state == .playing })

        mark = log.mark()
        model.next()
        await expectEvent("next track", since: mark)
        await waitFor("shows the next song", { self.model.track?.title == Self.secondName })

        mark = log.mark()
        model.previous()
        await expectEvent("previous track", since: mark)
        await waitFor("shows the previous song", { self.model.track?.title == Self.first.name })

        mark = log.mark()
        model.seek(to: 42.5)
        await expectEvent("set player position 42.50", since: mark)
        if case .success(let p) = await fetch() {
            check(p.position >= 42.5 && p.position < 47, "the fake's position after seek", "\(p.position)")
        } else {
            check(false, "read after seek")
        }

        mark = log.mark()
        model.setVolume(37)
        await expectEvent("set sound volume 37", since: mark)
        mark = log.mark()
        model.setVolume(150)
        await expectEvent("set sound volume 100", since: mark)
        await pause(1.2)
        model.refresh()
        await waitFor("volume reads back 100", { self.model.playback.volume == 100 })

        mark = log.mark()
        model.toggleShuffle()
        await expectEvent("set shuffling true", since: mark)
        mark = log.mark()
        model.toggleRepeat()
        await expectEvent("set repeating true", since: mark)
        if case .success(let p) = await fetch() {
            check(p.shuffling && p.repeating, "the fake has shuffle and repeat on")
        } else {
            check(false, "read after shuffle and repeat")
        }
        // Reads ignore Spotify's modes for a second after a change; then they must agree.
        await pause(1.5)
        model.refresh()
        await pause(0.5)
        check(model.shuffling && model.repeating, "shuffle and repeat stay on after a read", state())

        mark = log.mark()
        model.toggleShuffle()
        await expectEvent("set shuffling false", since: mark)
        mark = log.mark()
        model.toggleRepeat()
        await expectEvent("set repeating false", since: mark)
    }

    private func notification() async {
        let song = E2ESong(id: "spotify:track:0FakeNotified000000000", name: "Notified Song", artist: "Notifier",
                           album: "Signals", artwork: "https://127.0.0.1:9/notified.jpg", durationMS: 180_000)
        updates = []
        let start = Date()
        await load(song, state: "playing", position: 3, notify: true)
        guard await waitFor("the notification reaches Tonearm", { self.updates.contains { $0.track?.id == song.id } })
        else { return }
        if let u = updates.last(where: { $0.track?.id == song.id }) {
            check(u.state == .playing, "notification: state playing", "\(u.state)")
            check(u.track?.title == song.name && u.track?.artist == song.artist && u.track?.album == song.album,
                  "notification: title, artist, album", "\(String(describing: u.track))")
            check(u.track?.duration == 180, "notification: duration 180 s", "\(u.track?.duration ?? -1)")
            check(u.position.map { abs($0 - 3) < 1 } ?? false, "notification: position about 3 s",
                  "\(String(describing: u.position))")
        }
        // With the popover closed a playing player is read every 30 s, so a change within
        // 2 s came through the notification.
        await waitFor("the player shows the new song within 2 s of the change", timeout: 2,
                      { self.model.track?.title == song.name })
        report.write("   (took \(String(format: "%.2f", Date().timeIntervalSince(start))) s)")
        await waitFor("the read after the notification adds the artwork url",
                      { self.model.track?.artworkURL == URL(string: song.artwork) })
    }

    private func longAndNonLatin() async {
        let piece = "Ünïcödé Ñandú — 東京事変 能動的三分間 — Пётр Ильич Чайковский — عبد الحليم حافظ — 🎧🎶👩🏽‍🎤 — \"q\" \\ "
        let title = String(repeating: piece, count: 12)
        let song = E2ESong(id: "spotify:track:0FakeUnicode0000000000", name: title,
                           artist: "Сергей Рахманинов & 坂本龍一", album: "אלבום — 앨범 — ألبوم",
                           artwork: "https://127.0.0.1:9/unicode.jpg", durationMS: 3_723_000)
        updates = []
        await load(song, state: "playing", position: 1, notify: true)
        await waitFor("the notification carries the \(title.count)-character title intact",
                      { self.updates.contains { $0.track?.title == title } })
        await waitFor("the player shows the title intact", { self.model.track?.title == title })
        if case .success(let p) = await fetch() {
            check(p.track?.title == title, "AppleScript reads the title intact",
                  "got \(p.track?.title.count ?? 0) characters")
            check(p.track?.artist == song.artist, "artist intact", p.track?.artist ?? "nil")
            check(p.track?.album == song.album, "album intact", p.track?.album ?? "nil")
        } else {
            check(false, "read the long title")
        }
    }

    private func ad() async {
        let song = E2ESong(id: "spotify:ad:000000012c6a0f2b", name: "Spotify", durationMS: 30_000)
        await load(song, state: "playing", position: 0, notify: true)
        await waitFor("the player shows the ad", { self.model.track?.id == song.id })
        await pause(0.5)
        check(model.track?.duration == 30, "ad duration 30 s", "\(model.track?.duration ?? -1)")
        check(model.track?.artworkURL == nil, "no artwork url", model.track?.artworkURL?.absoluteString ?? "nil")
        check(model.trackURL == nil, "no share link for an ad", model.trackURL?.absoluteString ?? "nil")
        check(!model.copyTrackLink(), "copy link does nothing for an ad")
    }

    private func podcast() async {
        let song = E2ESong(id: "spotify:episode:5FakeEpisode0000000000", name: "Episode 12: A long talk",
                           artist: "A Show", album: "A Show", artwork: "https://127.0.0.1:9/show.jpg",
                           durationMS: 5_400_000)
        await load(song, state: "playing", position: 600, notify: true)
        await waitFor("the player shows the episode", { self.model.track?.id == song.id })
        check(model.track?.duration == 5400, "episode duration 5400 s", "\(model.track?.duration ?? -1)")
        check(model.trackURL?.absoluteString == "https://open.spotify.com/episode/5FakeEpisode0000000000",
              "episode share link", model.trackURL?.absoluteString ?? "nil")
        let mark = log.mark()
        model.seek(to: 3600)
        await expectEvent("set player position 3600.00", since: mark)
    }

    private func localFile() async {
        let song = E2ESong(id: "spotify:local:Local+Artist:Local+Album:Local+Song:200", name: "Local Song",
                           artist: "Local Artist", album: "Local Album", durationMS: 200_000, artworkFails: true)
        await load(song, state: "playing", position: 5, notify: true)
        let mark = log.mark()
        let result = await fetch()
        check(log.events(since: mark).contains("get artwork url"), "the read asked for the artwork url")
        if case .success(let p) = result {
            check(p.track?.title == "Local Song" && p.track?.artist == "Local Artist",
                  "the read keeps the other fields when artwork url fails", "\(String(describing: p.track))")
            check(p.track?.artworkURL == nil, "no artwork url")
        } else {
            check(false, "the read succeeds when artwork url fails", "\(result)")
        }
        await waitFor("the player shows the local file", { self.model.track?.title == "Local Song" })
        check(model.trackURL == nil, "no share link for a local file")
    }

    private func nothingLoaded() async {
        await load(E2ESong(id: "", name: ""), state: "paused", position: 0, notify: true)
        if case .success(let p) = await fetch() {
            check(p.track == nil && p.state == .paused, "an empty track reads as no track", "\(p)")
        } else {
            check(false, "read with nothing loaded")
        }
        await waitFor("the player shows no song", { self.model.track == nil })

        await load(Self.first, state: "stopped", position: 0, notify: true)
        if case .success(let p) = await fetch() {
            check(p.state == .stopped && p.track == nil, "stopped reads as no track", "\(p)")
        } else {
            check(false, "read while stopped")
        }
        await waitFor("the player shows stopped", { self.model.playback.state == .stopped && self.model.track == nil })
    }

    private func quitMidRead() async {
        await load(Self.first, state: "playing", position: 30, notify: true)
        await waitFor("playing before the quit", { self.model.playback.state == .playing })
        // Let the read that follows the notification finish first.
        await pause(0.5)
        guard await control("stall", ["seconds": "4"]) else { return }
        let mark = log.mark()
        var result: Result<Playback, BridgeError>?
        bridge.fetch { r, _ in result = r }
        guard await waitFor("the read reaches the fake", { self.log.events(since: mark).contains("stall begin") })
        else { return }
        await killFake()
        await waitFor("the read returns once Spotify is gone", timeout: 8, { result != nil })
        check(result == .failure(.notRunning), "the read fails with notRunning", "\(String(describing: result))")
        await waitFor("the player shows Spotify not running",
                      { self.model.status == .notRunning && self.model.track == nil })
        await pause(3)
        check(fakeApps().isEmpty, "no Apple Event relaunched Spotify")
    }

    private func relaunch() async {
        model.openSpotify()
        guard await waitFor("status ready after relaunch", timeout: 20, { self.model.status == .ready }) else { return }
        await waitFor("the fresh fake's song is shown", { self.model.track?.id == Self.first.id })
        check(model.playback.state == .paused && model.playback.volume == Self.firstVolume,
              "the fresh state is read", state())
        let mark = log.mark()
        model.playPause()
        await expectEvent("playpause", since: mark)
        await waitFor("shows playing", { self.model.playback.state == .playing })
    }

    /// Spotify pauses, posts that, and exits. Reads wait out the pause, so none reaches it mid-quit.
    private func quitWhilePlaying() async {
        let mark = log.mark()
        guard await control("quit") else { return }
        await waitFor("the player shows Spotify not running", timeout: 8,
                      { self.model.status == .notRunning && !self.model.spotifyRunning })
        await pause(4)
        check(fakeApps().isEmpty, "Spotify stays quit")
        check(!log.events(since: mark).contains("launched"), "no Apple Event relaunched Spotify",
              log.events(since: mark).joined(separator: " | "))
    }

    // MARK: Fake control

    /// Exits unless every app registered or running as com.spotify.client is the fake.
    private func checkFakeOnly() -> Bool {
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyBridge.bundleID)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyBridge.bundleID)
        let ok = Self.isFake(registered) && running.allSatisfy { Self.isFake($0.bundleURL) }
        if !ok {
            report.write("FAIL com.spotify.client is not the fake Spotify (\(registered?.path ?? "none")); refusing to run")
            failed += 1
        }
        return ok
    }

    private static func isFake(_ url: URL?) -> Bool {
        guard let url, let bundle = Bundle(url: url) else { return false }
        return bundle.object(forInfoDictionaryKey: "TonearmFakeSpotify") as? Bool == true
    }

    private func fakeApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyBridge.bundleID).filter { app in
            !app.isTerminated && kill(app.processIdentifier, 0) == 0
        }
    }

    private func killFake() async {
        for app in fakeApps() { app.forceTerminate() }
        let end = Date().addingTimeInterval(5)
        while !fakeApps().isEmpty, Date() < end { await pause(0.05) }
    }

    /// Posts a control action to the fake and waits until it logged that it took effect.
    @discardableResult
    private func control(_ action: String, _ args: [String: String] = [:]) async -> Bool {
        let token = UUID().uuidString
        var info = args
        info["action"] = action
        info["token"] = token
        let mark = log.mark()
        DistributedNotificationCenter.default().postNotificationName(
            Self.controlNotification, object: nil, userInfo: info, deliverImmediately: true
        )
        return await waitFor("fake: \(action)", quiet: true, { self.log.events(since: mark).contains("control \(action) \(token)") })
    }

    private func load(_ song: E2ESong, state: String, position: Double, notify: Bool) async {
        await control("load", [
            "id": song.id, "name": song.name, "artist": song.artist, "album": song.album,
            "artwork": song.artwork, "duration": String(song.durationMS),
            "artworkFails": song.artworkFails ? "1" : "0", "state": state,
            "position": String(position), "notify": notify ? "1" : "0",
        ])
    }

    // MARK: Helpers

    private func fetch() async -> Result<Playback, BridgeError> {
        await withCheckedContinuation { c in
            bridge.fetch { result, _ in c.resume(returning: result) }
        }
    }

    private func send(_ command: SpotifyBridge.Command) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            bridge.send(command) { c.resume() }
        }
    }

    private func runScript(_ source: String) -> (reply: NSAppleEventDescriptor?, error: Int?) {
        guard let script = NSAppleScript(source: source) else { return (nil, 0) }
        var info: NSDictionary?
        let out = script.executeAndReturnError(&info)
        if let info { return (nil, info[NSAppleScript.errorNumber] as? Int ?? 0) }
        return (out, nil)
    }

    /// Prints what macOS says about Automation access to Spotify, without asking.
    private func reportPermission() {
        let report = self.report
        DispatchQueue.global().async {
            let target = NSAppleEventDescriptor(bundleIdentifier: SpotifyBridge.bundleID)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, 0x636F_7265, 0x6765_7464, false)
            report.write("   Automation permission for Spotify: \(status) (0 = granted, -1744 = would ask)")
        }
    }

    /// The per-command "sent once" checks only see the moment a command arrives. This one
    /// reads the whole run's log after a pause, so a command repeated later is caught too.
    private func checkAllCommands(since start: Int) async {
        await pause(1.5)
        let names: Set = ["play", "playpause", "next track", "previous track"]
        let sent = log.events(since: start).filter { names.contains($0) || $0.hasPrefix("set ") }
        check(sent == expectedCommands, "the fake got exactly the \(expectedCommands.count) expected commands, in order",
              "got " + sent.joined(separator: " | "))
    }

    private func expectEvent(_ event: String, since mark: Int) async {
        expectedCommands.append(event)
        guard await waitFor("fake received \"\(event)\"", { self.log.events(since: mark).contains(event) }) else {
            return report.write("   fake log: " + log.events(since: mark).joined(separator: " | "))
        }
        let count = log.events(since: mark).filter { $0 == event }.count
        check(count == 1, "sent once", "\(count) times")
    }

    @discardableResult
    private func waitFor(_ what: String, timeout: TimeInterval = 5, quiet: Bool = false,
                         _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end {
                check(false, what, "not within \(timeout) s; \(state())")
                return false
            }
            await pause(0.05)
        }
        if !quiet { check(true, what) }
        return true
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            report.write("ok   \(what)")
        } else {
            failed += 1
            let detail = detail()
            report.write("FAIL \(what)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }

    private func state() -> String {
        guard let model else { return "no model" }
        let p = model.playback
        let title = p.track.map { String($0.title.prefix(40)) } ?? "none"
        return "status \(model.status), running \(model.spotifyRunning), \(p.state), track \(title), " +
            "pos \(String(format: "%.1f", p.position)), vol \(p.volume), shuffle \(p.shuffling), repeat \(p.repeating)"
    }
}
