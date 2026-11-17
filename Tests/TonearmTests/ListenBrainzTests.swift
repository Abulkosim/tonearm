import XCTest
@testable import Tonearm

/// A fake ListenBrainz server: every request made through a session that uses it is
/// recorded, and answered with the next scripted reply (or `fallback`).
final class LBStub: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = #"{"status": "ok"}"#
        var error: URLError.Code?

        static let ok = Reply()
        static func offline() -> Reply { Reply(error: .notConnectedToInternet) }
    }

    struct Seen {
        var request: URLRequest
        var body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var listenType: String? { json["listen_type"] as? String }
        var payload: [[String: Any]] { json["payload"] as? [[String: Any]] ?? [] }
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var fallbackReply = Reply.ok
    private static var seenRequests: [Seen] = []

    static func reset(_ replies: [Reply] = [], fallback: Reply = .ok) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        fallbackReply = fallback
        seenRequests = []
    }

    static func setFallback(_ reply: Reply) {
        lock.lock()
        fallbackReply = reply
        lock.unlock()
    }

    static var seen: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seenRequests
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LBStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.seenRequests.append(Seen(request: request, body: body))
        let reply = Self.replies.isEmpty ? Self.fallbackReply : Self.replies.removeFirst()
        Self.lock.unlock()

        if let code = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A clock the tests move. Sleeping moves it forward at once and is recorded.
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var sleeps: [TimeInterval] = []
    var onSleep: (() -> Void)?

    func sleep(_ seconds: TimeInterval) {
        sleeps.append(seconds)
        now = now.addingTimeInterval(seconds)
        onSleep?()
    }
}

// MARK: - Client and payload

final class ListenBrainzClientTests: XCTestCase {
    private let star = LBListen(key: "k1", listenedAt: 1_700_000_000, track: "Звезда", artist: "Кино",
                                release: "Группа крови", durationMs: 214_000,
                                spotifyURI: "spotify:track:4uLU6hMCjMI75M1A2tKUQC")

    private func client() -> ListenBrainzClient { ListenBrainzClient(session: LBStub.session()) }

    func testSingleListenIsExactlyTheDocumentedShape() async throws {
        LBStub.reset()
        try await client().submit(.single, [star], token: "tok-123")
        let seen = try XCTUnwrap(LBStub.seen.first)
        XCTAssertEqual(LBStub.seen.count, 1)
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.listenbrainz.org/1/submit-listens")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Authorization"), "Token tok-123")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let expected: [String: Any] = [
            "listen_type": "single",
            "payload": [[
                "listened_at": 1_700_000_000,
                "track_metadata": [
                    "artist_name": "Кино",
                    "track_name": "Звезда",
                    "release_name": "Группа крови",
                    "additional_info": [
                        "media_player": "Spotify",
                        "submission_client": "Tonearm",
                        "submission_client_version": ListenBrainz.clientVersion,
                        "music_service": "spotify.com",
                        "spotify_id": "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC",
                        "duration_ms": 214_000,
                    ],
                ],
            ]],
        ]
        XCTAssertEqual(seen.json as NSDictionary, expected as NSDictionary)
    }

    func testPlayingNowHasNoTimestamp() async throws {
        LBStub.reset()
        try await client().submit(.playingNow, [star], token: "t")
        let seen = try XCTUnwrap(LBStub.seen.first)
        XCTAssertEqual(seen.listenType, "playing_now")
        XCTAssertEqual(seen.payload.count, 1)
        XCTAssertNil(seen.payload[0]["listened_at"], "the docs say to omit it for playing_now")
        XCTAssertNotNil(seen.payload[0]["track_metadata"])
    }

    func testUnknownFieldsAreLeftOutNotNull() throws {
        let local = LBListen(key: "k", listenedAt: 1_700_000_000, track: "Basement Take 3", artist: "Some Artist",
                             release: "", durationMs: nil, spotifyURI: "spotify:local:Some+Artist::Basement:187")
        let object = ListenBrainz.listenObject(local, type: .import)
        let meta = try XCTUnwrap(object["track_metadata"] as? [String: Any])
        XCTAssertNil(meta["release_name"])
        let info = try XCTUnwrap(meta["additional_info"] as? [String: Any])
        XCTAssertNil(info["spotify_id"], "local files have no Spotify link")
        XCTAssertNil(info["duration_ms"])
        XCTAssertEqual(Set(info.keys), ["media_player", "submission_client", "submission_client_version", "music_service"])
    }

    func testListenRule() {
        // Half the track or 4 minutes, whichever is lower.
        XCTAssertFalse(ListenBrainz.counts(msPlayed: 99_999, durationMs: 200_000))
        XCTAssertTrue(ListenBrainz.counts(msPlayed: 100_000, durationMs: 200_000))
        XCTAssertFalse(ListenBrainz.counts(msPlayed: 239_999, durationMs: 600_000))
        XCTAssertTrue(ListenBrainz.counts(msPlayed: 240_000, durationMs: 600_000))
        XCTAssertFalse(ListenBrainz.counts(msPlayed: 200_000, durationMs: nil))
        XCTAssertTrue(ListenBrainz.counts(msPlayed: 240_000, durationMs: nil))
        XCTAssertFalse(ListenBrainz.counts(msPlayed: 0, durationMs: 0))
    }

    func testSendableNeedsNamesAndATimeTheServerTakes() {
        XCTAssertTrue(ListenBrainz.isSendable(star, type: .single))
        var early = star
        early.listenedAt = ListenBrainz.minimumTimestamp - 1
        XCTAssertFalse(ListenBrainz.isSendable(early, type: .import))
        var noArtist = star
        noArtist.artist = ""
        XCTAssertFalse(ListenBrainz.isSendable(noArtist, type: .single))
        var huge = star
        huge.track = String(repeating: "x", count: ListenBrainz.maxListenBytes)
        XCTAssertFalse(ListenBrainz.isSendable(huge, type: .single))
    }

    func testBatchesStayWithinTheRequestLimits() {
        let many = (0..<2_345).map { i in
            LBListen(key: "\(i)", listenedAt: 1_700_000_000 + Int64(i), track: "Song \(i)", artist: "Artist")
        }
        let first = ListenBrainz.batch(many[...], type: .import)
        XCTAssertEqual(first.count, ListenBrainz.maxListensPerRequest)
        let big = (0..<2_000).map { i in
            LBListen(key: "\(i)", listenedAt: 1_700_000_000 + Int64(i), track: String(repeating: "y", count: 12_000),
                     artist: "Artist")
        }
        let b = ListenBrainz.batch(big[...], type: .import)
        XCTAssertGreaterThan(b.count, 0)
        XCTAssertLessThan(b.count, ListenBrainz.maxListensPerRequest, "12 KB each: 1000 would be over 10 MB")
        XCTAssertLessThanOrEqual(try ListenBrainz.body(.import, Array(b)).count, ListenBrainz.maxPayloadBytes)
        XCTAssertGreaterThan(try ListenBrainz.body(.import, Array(big[0...b.count])).count,
                             ListenBrainz.maxPayloadBytes, "one more would not fit")
    }

    func testValidateToken() async throws {
        LBStub.reset([.init(body: #"{"code": 200, "message": "Token valid.", "valid": true, "user_name": "rob"}"#)])
        let user = try await client().validate(token: "good")
        XCTAssertEqual(user, "rob")
        let seen = try XCTUnwrap(LBStub.seen.first)
        XCTAssertEqual(seen.request.httpMethod, "GET")
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.listenbrainz.org/1/validate-token")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Authorization"), "Token good")
    }

    func testInvalidTokenAsTheDocsShowIt() async {
        // Copied from the docs, trailing comma and all.
        LBStub.reset([.init(body: "{\n\"code\": 200,\n\"message\": \"Token invalid.\",\n\"valid\": false,\n}")])
        do {
            _ = try await client().validate(token: "bad")
            XCTFail("an invalid token was accepted")
        } catch {
            XCTAssertEqual(error as? LBError, .invalidToken)
        }
    }

    func testStatusCodes() async {
        func outcome(_ reply: LBStub.Reply) async -> LBError? {
            LBStub.reset([reply])
            do {
                try await client().submit(.single, [star], token: "t")
                return nil
            } catch {
                return error as? LBError
            }
        }
        let e401 = await outcome(.init(status: 401, body: #"{"code": 401, "error": "Invalid authorization token."}"#))
        XCTAssertEqual(e401, .invalidToken)
        let e429 = await outcome(.init(status: 429, headers: ["X-RateLimit-Reset-In": "7"]))
        XCTAssertEqual(e429, .rateLimited(7))
        let e400 = await outcome(.init(status: 400, body: #"{"code": 400, "error": "bad listen"}"#))
        XCTAssertEqual(e400, .rejected(400, "bad listen"))
        let e503 = await outcome(.init(status: 503))
        XCTAssertEqual(e503, .server(503))
        let offline = await outcome(.offline())
        if case .network = offline {} else { XCTFail("offline gave \(String(describing: offline))") }
    }

    func testRateLimitHeaders() throws {
        let url = URL(string: "https://api.listenbrainz.org/1/submit-listens")!
        let headers = ["X-RateLimit-Limit": "30", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset-In": "12"]
        let r = LBRateLimit(try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                           headerFields: headers)))
        XCTAssertEqual(r, LBRateLimit(limit: 30, remaining: 0, resetIn: 12))
        XCTAssertEqual(r.wait, 12, "none left: wait for the reset")
        XCTAssertEqual(LBRateLimit(limit: 30, remaining: 5, resetIn: 12).wait, 1, "one call a second at most")
        XCTAssertEqual(LBRateLimit().wait, 1)
    }

    func testKeychainRoundTrip() throws {
        let service = "io.github.abulkosim.tonearm.tests.\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service)
        defer { store.delete() }
        do {
            try store.write("first")
        } catch {
            throw XCTSkip("No usable Keychain here: \(error)")
        }
        try store.write("second")
        XCTAssertEqual(KeychainTokenStore(service: service).read(), "second", "a new instance reads the Keychain")
        store.delete()
        XCTAssertNil(KeychainTokenStore(service: service).read())
    }

    func testAKeychainDenialIsAskedOnce() {
        var asks = 0
        var status = errSecAuthFailed
        let denied = KeychainTokenStore(service: "unused") { _, _ in
            asks += 1
            return status
        }
        XCTAssertNil(denied.read())
        XCTAssertNil(denied.read())
        XCTAssertNil(denied.read())
        XCTAssertEqual(asks, 1, "a denial is remembered, so the prompt doesn't come back on every song")

        asks = 0
        status = errSecInteractionNotAllowed
        let locked = KeychainTokenStore(service: "unused") { _, _ in
            asks += 1
            return status
        }
        XCTAssertNil(locked.read())
        XCTAssertNil(locked.read())
        XCTAssertEqual(asks, 2, "a locked Keychain shows no prompt, so it is asked again")
    }
}

// MARK: - Sync: queue, retry, rate limit, history

@MainActor
final class ListenBrainzSyncTests: XCTestCase {
    private var dir: URL!
    private var clock: FakeClock!
    private var on = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-lb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clock = FakeClock()
        on = true
        LBStub.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("listenbrainz.json") }

    private func sync(token: String? = "tok", source: LBHistorySource? = nil) -> ListenBrainzSync {
        let clock = self.clock!
        let s = ListenBrainzSync(client: ListenBrainzClient(session: LBStub.session()), tokens: MemoryTokenStore(token),
                                 file: file, source: source, isOn: { [unowned self] in self.on },
                                 now: { clock.now }, sleep: { clock.sleep($0) })
        s.start()
        return s
    }

    /// A listen that started at `t0 + start` seconds and has played `played` seconds, last
    /// seen at `t0 + start + played`. The clock starts at `t0`, so one that ended over a
    /// minute before gets no playing_now.
    private func listen(_ id: String = "spotify:track:aaaaaaaaaaaaaaaaaaaaaa", start: TimeInterval = 0,
                        played: TimeInterval, duration: TimeInterval = 200) -> LiveListen {
        let started = t0.addingTimeInterval(start)
        return LiveListen(trackID: id, kind: ListenKind.of(spotifyID: id), title: "Song", artist: "Artist",
                          album: "Album", artworkURL: nil, durationMs: Int64(duration * 1000), startedAt: started,
                          endedAt: started.addingTimeInterval(played), msPlayed: Int64(played * 1000))
    }

    /// Fixed start of the tests' timelines.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func submitted(_ type: String) -> [LBStub.Seen] { LBStub.seen.filter { $0.listenType == type } }

    private func writeSaved(_ saved: ListenBrainzSync.Saved) throws {
        try JSONEncoder().encode(saved).write(to: file)
    }

    private func readSaved() throws -> ListenBrainzSync.Saved {
        try JSONDecoder().decode(ListenBrainzSync.Saved.self, from: Data(contentsOf: file))
    }

    func testPlayingNowThenOneListenAtHalfTheTrack() async throws {
        let s = sync()
        clock.now = t0.addingTimeInterval(10)
        s.heard(listen(played: 10))
        await s.waitUntilIdle()
        XCTAssertEqual(submitted("playing_now").count, 1)
        XCTAssertEqual(submitted("single").count, 0, "10 s of 200 s is not a listen yet")

        clock.now = t0.addingTimeInterval(200)
        s.heard(listen(played: 99))
        s.heard(listen(played: 100))
        s.heard(listen(played: 150))
        s.heard(listen(played: 200))
        await s.waitUntilIdle()
        XCTAssertEqual(submitted("playing_now").count, 1, "one playing_now per play")
        let singles = submitted("single")
        XCTAssertEqual(singles.count, 1, "the play is sent once, when it reaches half")
        XCTAssertEqual(singles.first?.payload.first?["listened_at"] as? Int, Int(t0.timeIntervalSince1970))
        XCTAssertTrue(s.saved.pending.isEmpty)
        XCTAssertEqual(s.saved.sent, 1)
    }

    func testPodcastsAndOffAndNoTokenSendNothing() async {
        let s = sync()
        s.heard(listen("spotify:episode:eeeeeeeeeeeeeeeeeeeeee", played: 600, duration: 1200))
        on = false
        s.heard(listen(played: 150))
        await s.waitUntilIdle()
        let none = sync(token: nil)
        on = true
        none.heard(listen(played: 150))
        await none.waitUntilIdle()
        XCTAssertTrue(LBStub.seen.isEmpty)
        XCTAssertTrue(s.saved.pending.isEmpty)
    }

    func testRetriesWithBackoffAndSendsOnce() async throws {
        LBStub.reset([.offline(), .init(status: 503), .init(status: 502), .ok])
        let s = sync()
        // Ended 170 s ago, so no playing_now.
        s.heard(listen(start: -320, played: 150))
        await s.waitUntilIdle()
        let singles = submitted("single")
        XCTAssertEqual(singles.count, 4, "three failures, then the one that worked")
        XCTAssertEqual(Set(singles.map(\.body)).count, 1, "every try sends the same listen")
        XCTAssertEqual(Array(clock.sleeps.prefix(3)), [15, 30, 60], "backoff doubles")
        XCTAssertTrue(s.saved.pending.isEmpty)
        XCTAssertNil(s.problem)
        // Nothing is left to send after a relaunch.
        let again = sync()
        await again.waitUntilIdle()
        XCTAssertEqual(LBStub.seen.count, 4)
        XCTAssertEqual(again.saved.sent, 1)
    }

    func testBackoffIsCapped() {
        XCTAssertEqual(ListenBrainzSync.backoff(1), 15)
        XCTAssertEqual(ListenBrainzSync.backoff(7), 900)
        XCTAssertEqual(ListenBrainzSync.backoff(30), 900)
    }

    func testOfflineListensWaitOnDiskAndGoOutAfterARelaunch() async throws {
        LBStub.reset(fallback: .offline())
        // Turn sending off after a few tries, as quitting would.
        clock.onSleep = { [unowned self] in if self.clock.sleeps.count >= 4 { self.on = false } }
        let s = sync()
        s.heard(listen(start: -320, played: 150))
        s.heard(listen("spotify:track:bbbbbbbbbbbbbbbbbbbbbb", start: -200, played: 100))
        await s.waitUntilIdle()
        XCTAssertFalse(LBStub.seen.isEmpty)
        XCTAssertEqual(try readSaved().pending.count, 2, "both listens are on disk")
        XCTAssertNotNil(s.retryAt)

        LBStub.reset()
        clock.onSleep = nil
        on = true
        let relaunched = sync()
        await relaunched.waitUntilIdle()
        let imports = submitted("import")
        XCTAssertEqual(imports.count, 1, "a backlog goes in one import request")
        XCTAssertEqual(imports.first?.payload.count, 2)
        XCTAssertTrue(try readSaved().pending.isEmpty)
        XCTAssertEqual(relaunched.saved.sent, 2)
    }

    func testRateLimitIsObeyed() async throws {
        LBStub.reset([
            .init(status: 429, headers: ["X-RateLimit-Reset-In": "7"]),
            .init(headers: ["X-RateLimit-Limit": "30", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset-In": "9"]),
            .ok,
        ])
        let s = sync()
        s.heard(listen(start: -320, played: 150))
        await s.waitUntilIdle()
        XCTAssertEqual(clock.sleeps.first, 7, "a 429 waits X-RateLimit-Reset-In")
        XCTAssertEqual(submitted("single").count, 2)
        // The next listen comes after the window resets, since none were left.
        s.heard(listen("spotify:track:bbbbbbbbbbbbbbbbbbbbbb", start: -320, played: 150))
        await s.waitUntilIdle()
        XCTAssertEqual(Array(clock.sleeps.suffix(1)), [9])
        XCTAssertEqual(submitted("single").count, 3)
        XCTAssertEqual(s.saved.sent, 2)
    }

    func testInvalidTokenStopsAndKeepsTheQueue() async throws {
        LBStub.reset([.init(status: 401, body: #"{"code": 401, "error": "Invalid authorization token."}"#)])
        let s = sync()
        s.heard(listen(start: -320, played: 150))
        await s.waitUntilIdle()
        XCTAssertEqual(LBStub.seen.count, 1, "no retries with a bad token")
        XCTAssertEqual(s.connection, .tokenRejected)
        XCTAssertEqual(try readSaved().pending.count, 1, "the listen waits for a new token")
        XCTAssertNotNil(s.problem)
    }

    func testConnectChecksTheToken() async throws {
        let tokens = MemoryTokenStore()
        let clock = self.clock!
        let s = ListenBrainzSync(client: ListenBrainzClient(session: LBStub.session()), tokens: tokens, file: file,
                                 source: nil, isOn: { true }, now: { clock.now }, sleep: { clock.sleep($0) })
        s.start()
        LBStub.reset([.init(body: #"{"code": 200, "message": "Token invalid.", "valid": false}"#)])
        await s.connect(token: " nope ")
        XCTAssertNil(tokens.token, "a bad token is not kept")
        XCTAssertEqual(s.connection, .noToken)
        XCTAssertEqual(LBStub.seen.first?.request.value(forHTTPHeaderField: "Authorization"), "Token nope")

        LBStub.reset([.init(body: #"{"code": 200, "message": "Token valid.", "valid": true, "user_name": "rob"}"#)])
        await s.connect(token: "good")
        XCTAssertEqual(tokens.token, "good")
        XCTAssertEqual(s.connection, .connected)
        XCTAssertEqual(s.saved.userName, "rob")
        XCTAssertEqual(s.saved.live, [.init(from: ListenBrainzSync.ms(clock.now))], "plays are queued from now")

        s.disconnect()
        XCTAssertNil(tokens.token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testARefusedBatchGoesOneByOneAndKeepsTheBadListen() async throws {
        let good = LBListen(key: "a", listenedAt: 1_700_000_000, track: "Good", artist: "Artist")
        let bad = LBListen(key: "b", listenedAt: 1_700_000_300, track: "Bad", artist: "Artist")
        let good2 = LBListen(key: "c", listenedAt: 1_700_000_600, track: "Good 2", artist: "Artist")
        var saved = ListenBrainzSync.Saved(userName: "rob")
        saved.pending = [good, bad, good2]
        try writeSaved(saved)
        LBStub.reset([.init(status: 400, body: #"{"code": 400, "error": "nope"}"#), .ok,
                      .init(status: 400, body: #"{"code": 400, "error": "nope"}"#), .ok])
        let s = sync()
        await s.waitUntilIdle()
        XCTAssertEqual(LBStub.seen.map(\.listenType), ["import", "single", "single", "single"])
        XCTAssertTrue(s.saved.pending.isEmpty)
        XCTAssertEqual(s.saved.refused, [bad])
        XCTAssertEqual(s.saved.sent, 2)
    }

    func testOnePlaySeenTwiceIsSentOnceButRepeatOneIsSentAgain() async {
        let s = sync()
        // Played 120 s, then Tonearm restarted at 130 s and saw the rest as a new listen.
        s.heard(listen(start: -500, played: 120))
        s.heard(listen(start: -370, played: 101))
        // Repeat one: the same song again from the top after it ended.
        s.heard(listen(start: -300, played: 150))
        await s.waitUntilIdle()
        let sent = (submitted("single") + submitted("import")).flatMap(\.payload)
        XCTAssertEqual(sent.count, 2)
    }

    // MARK: History

    /// 2,500 full plays, 300 short ones and 5 podcast episodes, as an extended export.
    private func historyStore() throws -> HistoryStore {
        var rows: [[String: Any]] = []
        let base = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        let iso = ISO8601DateFormatter()
        func uri(_ n: Int) -> String { "spotify:track:" + String(format: "%022d", n) }
        for i in 0..<2_500 {
            rows.append(["ts": iso.string(from: base.addingTimeInterval(Double(i) * 600 + 200)), "ms_played": 200_000,
                         "master_metadata_track_name": "Song \(i % 700)",
                         "master_metadata_album_artist_name": "Artist \(i % 40)",
                         "master_metadata_album_album_name": "Album", "spotify_track_uri": uri(i % 700)])
        }
        for j in 0..<300 {
            rows.append(["ts": iso.string(from: base.addingTimeInterval(Double(j) * 600 + 400)), "ms_played": 10_000,
                         "master_metadata_track_name": "Short \(j)", "master_metadata_album_artist_name": "Artist",
                         "master_metadata_album_album_name": "Album", "spotify_track_uri": uri(10_000 + j)])
        }
        for k in 0..<5 {
            rows.append(["ts": iso.string(from: base.addingTimeInterval(Double(k) * 600 + 500)), "ms_played": 900_000,
                         "master_metadata_track_name": NSNull(), "episode_name": "Ep \(k)", "episode_show_name": "Show",
                         "spotify_episode_uri": "spotify:episode:" + String(format: "%022d", k)])
        }
        let folder = dir.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: rows).write(to: folder.appendingPathComponent("Streaming_History_Audio_2020_0.json"))
        let store = HistoryStore(url: dir.appendingPathComponent("db/history.sqlite"))
        let result = try store.sync { try $0.importNow(urls: [folder]) }
        XCTAssertEqual(result.added, 2_805)
        return store
    }

    func testSendHistoryInBatchesResumesAndSendsEachListenOnce() async throws {
        let store = try historyStore()
        var saved = ListenBrainzSync.Saved(userName: "rob")
        saved.live = [.init(from: ListenBrainzSync.ms(Date(timeIntervalSince1970: 1_900_000_000)))]
        try writeSaved(saved)

        // The first batch goes through, then the network drops; sending is turned off after a few tries.
        LBStub.reset([.ok], fallback: .init(status: 500))
        clock.onSleep = { [unowned self] in if self.clock.sleeps.count >= 5 { self.on = false } }
        let s = sync(source: store)
        await s.sendHistory()
        await s.waitUntilIdle()
        XCTAssertEqual(s.saved.history?.sent, 1_000)
        XCTAssertNil(s.saved.history?.finished)
        let firstBatch = LBStub.seen[0]
        XCTAssertGreaterThan(LBStub.seen.count, 2, "failed batches were retried")
        XCTAssertEqual(try readSaved().history?.sent, 1_000, "progress is on disk")

        // Relaunch: it goes on from where it got to.
        LBStub.reset()
        clock.onSleep = nil
        on = true
        let relaunched = sync(source: store)
        await relaunched.waitUntilIdle()
        let h = try XCTUnwrap(relaunched.saved.history)
        XCTAssertNotNil(h.finished)
        XCTAssertEqual(h.sent, 2_500)
        XCTAssertEqual(h.skipped, 300, "10 s plays don't count")

        let batches = [firstBatch] + LBStub.seen
        XCTAssertEqual(batches.map(\.listenType), ["import", "import", "import"])
        XCTAssertEqual(batches.map(\.payload.count), [1_000, 1_000, 500])
        let times = batches.flatMap(\.payload).compactMap { $0["listened_at"] as? Int }
        XCTAssertEqual(times.count, 2_500)
        XCTAssertEqual(Set(times).count, 2_500, "no listen is sent twice")
        XCTAssertEqual(times, times.sorted(), "oldest first")
        let names = batches.flatMap(\.payload).compactMap { ($0["track_metadata"] as? [String: Any])?["track_name"] as? String }
        XCTAssertFalse(names.contains { $0.hasPrefix("Short") || $0.hasPrefix("Ep ") })
        XCTAssertNil(relaunched.historyProgress)
    }

    func testHistoryLeavesOutWhatWasQueuedLive() async throws {
        let store = try historyStore()
        var saved = ListenBrainzSync.Saved(userName: "rob")
        // 2020-01-01 + 100 * 600 s: the first 100 full plays (and their short neighbours) started before it.
        saved.live = [.init(from: ListenBrainzSync.ms(Date(timeIntervalSince1970: 1_577_836_800 + 100 * 600)))]
        try writeSaved(saved)
        let s = sync(source: store)
        await s.sendHistory()
        await s.waitUntilIdle()
        XCTAssertEqual(s.saved.history?.sent, 100)
        XCTAssertEqual(LBStub.seen.count, 1)
    }

    func testDeleteAllHistoryEmptiesTheQueueButKeepsTheToken() async throws {
        LBStub.reset(fallback: .offline())
        clock.onSleep = { [unowned self] in if self.clock.sleeps.count >= 2 { self.on = false } }
        let s = sync()
        s.heard(listen(start: -320, played: 150))
        await s.waitUntilIdle()
        XCTAssertEqual(try readSaved().pending.count, 1)
        s.deleteQueued()
        XCTAssertTrue(try readSaved().pending.isEmpty)
        XCTAssertTrue(try readSaved().recent.isEmpty, "no song names are left in the file")
        XCTAssertTrue(s.hasToken)

        // The song playing during the delete was deleted from the history, so it stays out.
        on = true
        clock.onSleep = { [unowned self] in self.on = false }
        s.heard(listen(start: -320, played: 160))
        s.heard(listen(start: -320, played: 200))
        await s.waitUntilIdle()
        XCTAssertTrue(try readSaved().pending.isEmpty, "the deleted play is not queued again")
        XCTAssertTrue(try readSaved().recent.isEmpty)
        // The next song is.
        on = true
        s.heard(listen("spotify:track:bbbbbbbbbbbbbbbbbbbbbb", start: clock.now.timeIntervalSince(t0) + 1, played: 150))
        await s.waitUntilIdle()
        XCTAssertEqual(try readSaved().pending.count, 1)
    }

    func testDeleteAllHistoryMakesNoFileForSomeoneWhoNeverConnected() {
        let s = sync(token: nil)
        s.deleteQueued()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAReadUnderWayDoesNotBringBackDeletedState() async throws {
        let source = GatedHistory()
        let s = sync(source: source)
        await s.sendHistory()
        XCTAssertNotNil(s.saved.history)
        // The worker is waiting on the store for a page when the history is deleted.
        await source.gate.reached()
        s.deleteQueued()
        await source.gate.open()
        // Let the old read finish.
        for _ in 0..<100 { await Task.yield() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(s.saved.history, "the read that was under way wrote nothing back")
        XCTAssertNil(try readSaved().history)
        XCTAssertNil(s.problem)
    }

    func testPlaysWhileSendingWasOffOrTheTokenWasRefusedAreNotLost() async throws {
        let store = HistoryStore(url: dir.appendingPathComponent("db/history.sqlite"))
        // Each play is 150 s of a 200 s song, recorded and then seen by the sync as it ends.
        func play(_ n: Int, at start: TimeInterval) throws -> LiveListen {
            let l = listen("spotify:track:" + String(format: "%022d", n), start: start, played: 150)
            clock.now = l.endedAt
            try store.sync { try $0.saveNow(l) }
            return l
        }
        let early = try play(1, at: -1_000)
        // Connected now: plays are queued from here.
        let s = sync(source: store)
        s.heard(try play(2, at: 100))
        await s.waitUntilIdle()
        // Sending off from 300 s to 700 s.
        clock.now = t0.addingTimeInterval(300)
        on = false
        s.switched(false)
        let whileOff = try play(3, at: 400)
        s.heard(whileOff)
        clock.now = t0.addingTimeInterval(700)
        on = true
        s.switched(true)
        s.heard(try play(4, at: 800))
        await s.waitUntilIdle()
        XCTAssertEqual(submitted("single").count, 2, "the plays while on went out live")

        // ListenBrainz stops taking the token. Plays wait in the queue.
        LBStub.reset(fallback: .init(status: 401, body: #"{"code": 401, "error": "Invalid authorization token."}"#))
        s.heard(try play(5, at: 1_000))
        await s.waitUntilIdle()
        XCTAssertEqual(s.connection, .tokenRejected)
        s.heard(try play(6, at: 1_200))
        await s.waitUntilIdle()
        XCTAssertEqual(s.saved.pending.count, 2, "plays made with a refused token wait for a new one")

        // A new token sends them.
        LBStub.reset([.init(body: #"{"code": 200, "message": "Token valid.", "valid": true, "user_name": "rob"}"#)])
        await s.connect(token: "new")
        await s.waitUntilIdle()
        XCTAssertTrue(s.saved.pending.isEmpty)
        XCTAssertEqual(s.saved.sent, 4)

        // Send earlier listens: the play from before connecting, and the one made while off.
        LBStub.reset()
        await s.sendHistory()
        await s.waitUntilIdle()
        let times = submitted("import").flatMap(\.payload).compactMap { $0["listened_at"] as? Int }
        XCTAssertEqual(times, [early, whileOff].map { Int($0.startedAt.timeIntervalSince1970) })
        XCTAssertEqual(s.saved.history?.sent, 2)
    }

    func testEarlierListensNeedHalfOfAPlayThatRanToTheEnd() async throws {
        let iso = ISO8601DateFormatter()
        let base = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        var n = 0
        // One extended-history row: ms played, how it ended, and whether it was skipped.
        func row(_ song: String, _ ms: Int, _ reason: String, skipped: Bool = false) -> [String: Any] {
            n += 1
            return ["ts": iso.string(from: base.addingTimeInterval(Double(n) * 1_000)), "ms_played": ms,
                    "master_metadata_track_name": song, "master_metadata_album_artist_name": "Artist",
                    "master_metadata_album_album_name": "Album",
                    "spotify_track_uri": "spotify:track:" + String(repeating: String(song.prefix(1)), count: 22),
                    "reason_end": reason, "skipped": skipped]
        }
        let extended = [
            row("X once, skipped at 40 s", 40_000, "fwdbtn", skipped: true),
            row("Y once, stopped at 100 s", 100_000, "endplay"),
            row("Z full", 210_000, "trackdone"),
            row("Z skipped at 2 min", 120_000, "fwdbtn", skipped: true),
            row("Z skipped at 1 min", 60_000, "fwdbtn", skipped: true),
            row("W a 35 s song", 35_000, "trackdone"),
            row("V stopped after 4 min", 250_000, "logout"),
        ].map { r -> [String: Any] in
            // Z's three plays are one song.
            var r = r
            if let name = r["master_metadata_track_name"] as? String, name.hasPrefix("Z") {
                r["master_metadata_track_name"] = "Z"
            }
            return r
        }
        // Account data says nothing about how a play ended.
        let account: [[String: Any]] = [["endTime": "2021-01-01 10:00", "artistName": "Artist",
                                         "trackName": "U once", "msPlayed": 100_000]]
        let folder = dir.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: extended)
            .write(to: folder.appendingPathComponent("Streaming_History_Audio_2020_0.json"))
        try JSONSerialization.data(withJSONObject: account)
            .write(to: folder.appendingPathComponent("StreamingHistory_music_0.json"))
        let store = HistoryStore(url: dir.appendingPathComponent("db/history.sqlite"))
        XCTAssertEqual(try store.sync { try $0.importNow(urls: [folder]) }.added, 8)

        let s = sync(source: store)
        await s.sendHistory()
        await s.waitUntilIdle()
        let sent = submitted("import").flatMap(\.payload)
        let names = sent.compactMap { ($0["track_metadata"] as? [String: Any])?["track_name"] as? String }
        let played = sent.compactMap {
            (($0["track_metadata"] as? [String: Any])?["additional_info"] as? [String: Any])?["duration_ms"]
        }
        XCTAssertEqual(names.sorted(), ["U once", "V stopped after 4 min", "W a 35 s song", "Z", "Z"])
        XCTAssertTrue(played.isEmpty, "exports have no lengths, so none are sent")
        XCTAssertEqual(s.saved.history?.skipped, 3)

        // The case from review: one 40 s play of a 3:30 song.
        let once = StoredListen(id: 1, startedAt: 0, msPlayed: 40_000, trackID: 1, title: "T", artist: "A",
                                album: "", uri: "", durationMs: nil, skipped: true, reasonEnd: "fwdbtn")
        XCTAssertFalse(ListenBrainzSync.historyCounts(once, lengths: PlayLengths(longest: 40_000, finished: nil)))
        XCTAssertFalse(ListenBrainzSync.historyCounts(once, lengths: PlayLengths(longest: 210_000, finished: 210_000)))
        var half = once
        half.msPlayed = 105_000
        XCTAssertTrue(ListenBrainzSync.historyCounts(half, lengths: PlayLengths(longest: 210_000, finished: 210_000)))
    }
}

/// A history whose pages wait until the test lets them go.
final class GatedHistory: LBHistorySource {
    let gate = Gate()

    func summary() async throws -> HistorySummary {
        HistorySummary(count: 1, first: Date(timeIntervalSince1970: 1_600_000_000), last: nil)
    }

    func musicPage(after cursor: ListenCursor?, before: Int64, limit: Int) async throws -> [StoredListen] {
        await gate.wait()
        return []
    }

    func longestPlays() async throws -> [Int64: PlayLengths] { [:] }
}

actor Gate {
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { waiting = $0 }
    }

    /// Returns once something waits at the gate.
    func reached() async {
        while waiting == nil { await Task.yield() }
    }

    func open() {
        waiting?.resume()
        waiting = nil
    }
}
