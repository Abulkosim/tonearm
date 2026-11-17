import Combine
import Foundation

/// Where "Send history" reads listens from. `HistoryStore` in the app.
protocol LBHistorySource: AnyObject {
    func summary() async throws -> HistorySummary
    func musicPage(after cursor: ListenCursor?, before: Int64, limit: Int) async throws -> [StoredListen]
    func longestPlays() async throws -> [Int64: Int64]
}

extension HistoryStore: LBHistorySource {}

/// Sends listens to ListenBrainz while the user has it on and has given a token.
///
/// - Live: each song Tonearm records is sent as "playing_now" when it starts, and queued as a
///   listen once it has played half its length or 4 minutes, whichever is less.
/// - The queue is a file next to the history. A listen leaves it only after ListenBrainz
///   answered 200, so going offline or quitting loses nothing. Sending is retried with
///   backoff, and waits as long as the rate limit headers ask.
/// - "Send history" sends the listens stored before ListenBrainz was turned on, with
///   listen_type "import", 1000 at a time. Where it got to is saved after each batch, so it
///   goes on from there after a quit or an error.
@MainActor
final class ListenBrainzSync: ObservableObject {
    static let shared = ListenBrainzSync(
        client: ListenBrainzClient(), tokens: KeychainTokenStore(), file: defaultFile,
        source: HistoryStore.shared, isOn: { AppSettings.shared.listenBrainz },
        changes: AppSettings.shared.$listenBrainz.dropFirst().eraseToAnyPublisher())

    static var defaultFile: URL {
        HistoryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("listenbrainz.json")
    }

    /// What is kept on disk between launches.
    struct Saved: Codable, Equatable {
        /// The ListenBrainz user the token belongs to.
        var userName: String?
        /// Listens waiting to be sent, oldest first.
        var pending: [LBListen] = []
        /// Listens ListenBrainz refused (400). Kept, not dropped in silence.
        var refused: [LBListen] = []
        /// Live plays queued lately, so one play is never queued twice.
        var recent: [Recent] = []
        /// Live listens sent since the token was added.
        var sent = 0
        /// When the token was added, UTC ms. "Send history" sends what started before it.
        var since: Int64?
        var history: HistorySend?
    }

    struct Recent: Codable, Equatable {
        var key: String
        /// Spotify URI, or "artist\u{1F}title" when there is none.
        var song: String
        var start: Int64
        var durationMs: Int64?
    }

    struct HistorySend: Codable, Equatable {
        /// Listens that started before this, UTC ms.
        var before: Int64
        /// The first listen's start, for progress.
        var first: Int64?
        /// The last listen handled.
        var cursor: ListenCursor?
        var sent = 0
        /// Plays too short to count as a listen.
        var skipped = 0
        var refused = 0
        var finished: Date?
    }

    enum Connection: Equatable {
        case noToken
        case checking
        case connected
        /// ListenBrainz said no to the token, when it was entered or later.
        case tokenRejected
    }

    @Published private(set) var saved: Saved
    @Published private(set) var connection: Connection
    /// The last thing that went wrong, in words for the settings panel. Nil when all is well.
    @Published private(set) var problem: String?
    /// When the next try is, after an error.
    @Published private(set) var retryAt: Date?
    /// True while a request or a history read is under way.
    @Published private(set) var busy = false

    let client: ListenBrainzClient
    private let tokens: LBTokenStore
    private let file: URL?
    private let source: LBHistorySource?
    private let isOn: () -> Bool
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void
    private var changes: AnyCancellable?

    private var worker: Task<Void, Never>?
    private var workerID = 0
    private var nowPlaying: (listen: LBListen, at: Date)?
    private var lastNowPlayingKey: String?
    private var notBefore = Date.distantPast
    private var failures = 0
    /// After a refused batch, the queue goes one listen at a time until it is empty.
    private var oneAtATime = false
    /// The same for history, up to this cursor.
    private var historyOneAtATimeUntil: ListenCursor?
    private var longest: [Int64: Int64]?

    static let maxRecent = 500
    static let maxBackoff: TimeInterval = 15 * 60
    /// "playing_now" is only worth sending while the song is new.
    static let nowPlayingFreshness: TimeInterval = 60

    init(client: ListenBrainzClient, tokens: LBTokenStore, file: URL?, source: LBHistorySource?,
         isOn: @escaping () -> Bool, changes: AnyPublisher<Bool, Never>? = nil,
         now: @escaping () -> Date = { Date() },
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) }) {
        self.client = client
        self.tokens = tokens
        self.file = file
        self.source = source
        self.isOn = isOn
        self.now = now
        self.sleep = sleep
        saved = file.flatMap(Self.load) ?? Saved()
        connection = .noToken
        self.changes = changes?.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            MainActor.assumeIsolated { self?.switched(on) }
        }
    }

    /// For snapshots: fixed state, no disk, no network.
    static func preview(connection: Connection, saved: Saved = Saved(), problem: String? = nil,
                        retryAt: Date? = nil) -> ListenBrainzSync {
        let sync = ListenBrainzSync(client: ListenBrainzClient(), tokens: MemoryTokenStore(), file: nil,
                                    source: nil, isOn: { false })
        sync.connection = connection
        sync.saved = saved
        sync.problem = problem
        sync.retryAt = retryAt
        return sync
    }

    /// At launch: reads the token and goes on with anything left from last time.
    func start() {
        connection = hasToken ? .connected : .noToken
        kick()
    }

    var hasToken: Bool { tokens.read() != nil }
    var pendingCount: Int { saved.pending.count }

    /// Progress of "Send history", 0 to 1, by time.
    var historyProgress: Double? {
        guard let h = saved.history, h.finished == nil else { return nil }
        guard let first = h.first, h.before > first else { return 0 }
        let at = h.cursor?.startedAt ?? first
        return min(1, max(0, Double(at - first) / Double(h.before - first)))
    }

    private func switched(_ on: Bool) {
        if on {
            kick()
        } else {
            stopWorker()
            nowPlaying = nil
        }
    }

    // MARK: Token

    /// Checks the token with ListenBrainz and keeps it in the Keychain if it is good.
    func connect(token raw: String) async {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        connection = .checking
        problem = nil
        do {
            let user = try await client.validate(token: token)
            try tokens.write(token)
            saved.userName = user.isEmpty ? nil : user
            if saved.since == nil { saved.since = Self.ms(now()) }
            connection = .connected
            failures = 0
            notBefore = .distantPast
            retryAt = nil
            persist()
            kick()
        } catch LBError.invalidToken {
            connection = hasToken ? .tokenRejected : .noToken
            problem = "ListenBrainz did not accept that token."
        } catch let error as LBError {
            connection = hasToken ? .connected : .noToken
            problem = error.message
        } catch {
            connection = hasToken ? .connected : .noToken
            problem = "Could not save the token in the Keychain. \(error)"
        }
    }

    /// Forgets the token and everything queued for ListenBrainz.
    func disconnect() {
        stopWorker()
        tokens.delete()
        saved = Saved()
        nowPlaying = nil
        lastNowPlayingKey = nil
        problem = nil
        retryAt = nil
        connection = .noToken
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// "Delete all history" also deletes the queue: it holds song names. The token stays.
    func deleteQueued() {
        stopWorker()
        saved = Saved(userName: saved.userName, since: saved.since)
        nowPlaying = nil
        oneAtATime = false
        historyOneAtATimeUntil = nil
        longest = nil
        persist()
        kick()
    }

    // MARK: Live

    /// A look at what `PlayRecorder` stores: called with the open listen as it grows and
    /// once more when it closes. Same `dedupKey`, same play.
    func heard(_ listen: LiveListen) {
        guard isOn(), hasToken, connection != .tokenRejected, listen.kind == .music else { return }
        let key = "live:\(listen.dedupKey)"
        let uri = listen.trackID.hasPrefix("spotify:") ? listen.trackID : nil
        let lb = LBListen(key: key, listenedAt: Int64(listen.startedAt.timeIntervalSince1970.rounded(.down)),
                          track: listen.title, artist: listen.artist, release: listen.album,
                          durationMs: listen.durationMs, spotifyURI: uri)
        let current = now()
        if lastNowPlayingKey != key, current.timeIntervalSince(listen.endedAt) < Self.nowPlayingFreshness,
           ListenBrainz.isSendable(lb, type: .playingNow) {
            lastNowPlayingKey = key
            nowPlaying = (lb, current)
        }
        if ListenBrainz.counts(msPlayed: listen.msPlayed, durationMs: listen.durationMs),
           !saved.recent.contains(where: { $0.key == key }), ListenBrainz.isSendable(lb, type: .single) {
            var recent = Recent(key: key, song: uri ?? "\(listen.artist)\u{1F}\(listen.title)",
                                start: Self.ms(listen.startedAt), durationMs: listen.durationMs)
            if let first = samePlay(recent) {
                // Remembered as part of the first one, so the play after it is still new.
                recent.start = first.start
                recent.durationMs = first.durationMs
            } else {
                saved.pending.append(lb)
            }
            saved.recent.append(recent)
            if saved.recent.count > Self.maxRecent { saved.recent.removeFirst(saved.recent.count - Self.maxRecent) }
            persist()
        }
        kick()
    }

    /// Tonearm can see one play as two listens: it quit and started again mid-song, or the
    /// song was sought back to the start. A second start inside the first one's length is
    /// the same play. The next play of the same song (repeat one) starts after it ends.
    private func samePlay(_ r: Recent) -> Recent? {
        saved.recent.first { old in
            let gap = r.start - old.start
            let length = (old.durationMs ?? 240_000) - 5_000
            return old.song == r.song && gap >= 0 && gap < length
        }
    }

    // MARK: History

    /// Starts (or starts again) sending the listens stored before the token was added.
    func sendHistory() async {
        guard hasToken, let source else { return }
        let before = saved.since ?? Self.ms(now())
        let first = try? await source.summary().first.map(Self.ms)
        saved.history = HistorySend(before: before, first: first)
        historyOneAtATimeUntil = nil
        longest = nil
        persist()
        kick()
    }

    // MARK: Worker

    private func kick() {
        guard worker == nil, isOn(), hasToken, connection != .tokenRejected else { return }
        workerID += 1
        let id = workerID
        worker = Task { [weak self] in
            await self?.run()
            if self?.workerID == id { self?.worker = nil }
        }
    }

    private func stopWorker() {
        worker?.cancel()
        worker = nil
        workerID += 1
        busy = false
    }

    /// Waits until there is nothing left to send right now. For tests.
    func waitUntilIdle() async {
        while let w = worker { await w.value }
    }

    private enum Job {
        case playingNow(LBListen)
        case queued([LBListen], ListenBrainz.ListenType)
        case history([LBListen], through: ListenCursor, skipped: Int)
    }

    private func run() async {
        while !Task.isCancelled {
            guard isOn(), let token = tokens.read(), connection != .tokenRejected, hasWork else {
                busy = false
                return
            }
            let wait = notBefore.timeIntervalSince(now())
            if wait > 0 {
                busy = false
                await sleep(wait)
                continue
            }
            busy = true
            guard let job = await nextJob(), !Task.isCancelled else {
                busy = false
                return
            }
            await perform(job, token: token)
        }
    }

    private var hasWork: Bool {
        nowPlaying != nil || !saved.pending.isEmpty
            || (source != nil && saved.history != nil && saved.history?.finished == nil)
    }

    private func nextJob() async -> Job? {
        if let np = nowPlaying {
            nowPlaying = nil
            if now().timeIntervalSince(np.at) < Self.nowPlayingFreshness { return .playingNow(np.listen) }
        }
        if !saved.pending.isEmpty {
            if saved.pending.count == 1 || oneAtATime { return .queued([saved.pending[0]], .single) }
            return .queued(Array(ListenBrainz.batch(saved.pending[...], type: .import)), .import)
        }
        oneAtATime = false
        return await nextHistoryBatch()
    }

    private func nextHistoryBatch() async -> Job? {
        guard var h = saved.history, h.finished == nil, let source else { return nil }
        do {
            if longest == nil { longest = try await source.longestPlays() }
            var cursor = h.cursor
            var out: [LBListen] = []
            var skipped = 0
            var limit = ListenBrainz.maxListensPerRequest
            if let until = historyOneAtATimeUntil {
                if let c = cursor, !Self.before(c, until) {
                    historyOneAtATimeUntil = nil
                } else {
                    limit = 1
                }
            }
            reading: while out.count < limit {
                let rows = try await source.musicPage(after: cursor, before: h.before, limit: 1000)
                if rows.isEmpty { break }
                for r in rows {
                    cursor = r.cursor
                    if let l = historyListen(r) {
                        out.append(l)
                    } else {
                        skipped += 1
                    }
                    if out.count >= limit { break reading }
                }
            }
            guard let through = cursor, !out.isEmpty else {
                // Nothing left that counts.
                h.cursor = cursor
                h.skipped += skipped
                h.finished = now()
                saved.history = h
                persist()
                return nil
            }
            return .history(out, through: through, skipped: skipped)
        } catch {
            problem = "Can't read the history: \(error)"
            return nil
        }
    }

    /// A stored listen as ListenBrainz should get it, or nil when it doesn't count. Exports
    /// have no track lengths, so the longest play of the song stands in, and a play must
    /// also be at least 30 s (Spotify's own count of a stream).
    private func historyListen(_ r: StoredListen) -> LBListen? {
        let length = r.durationMs ?? longest?[r.trackID]
        guard r.msPlayed >= 30_000, ListenBrainz.counts(msPlayed: r.msPlayed, durationMs: length) else { return nil }
        let uri = r.uri.hasPrefix("spotify:") ? r.uri : nil
        let l = LBListen(key: "db:\(r.id)", listenedAt: Self.floorDiv(r.startedAt, 1000), track: r.title,
                         artist: r.artist, release: r.album, durationMs: r.durationMs, spotifyURI: uri)
        guard ListenBrainz.isSendable(l, type: .import) else { return nil }
        // Sent live already.
        let song = uri ?? "\(r.artist)\u{1F}\(r.title)"
        if saved.recent.contains(where: { $0.song == song && abs($0.start - r.startedAt) < 1000 }) { return nil }
        return l
    }

    private func perform(_ job: Job, token: String) async {
        let type: ListenBrainz.ListenType
        let listens: [LBListen]
        switch job {
        case .playingNow(let l): (type, listens) = (.playingNow, [l])
        case .queued(let ls, let t): (type, listens) = (t, ls)
        case .history(let ls, _, _): (type, listens) = (.import, ls)
        }
        do {
            let rate = try await client.submit(type, listens, token: token)
            // Recorded even if cancelled meanwhile: ListenBrainz has these now.
            succeeded(job)
            failures = 0
            retryAt = nil
            problem = nil
            notBefore = now().addingTimeInterval(rate.wait)
        } catch {
            busy = false
            if Task.isCancelled { return }
            failed(job, error as? LBError ?? .network("\(error)"))
        }
    }

    private func succeeded(_ job: Job) {
        switch job {
        case .playingNow:
            return
        case .queued(let ls, _):
            let keys = Set(ls.map(\.key))
            saved.pending.removeAll { keys.contains($0.key) }
            saved.sent += ls.count
        case .history(let ls, let through, let skipped):
            guard var h = saved.history else { return }
            h.cursor = through
            h.sent += ls.count
            h.skipped += skipped
            saved.history = h
        }
        persist()
    }

    private func failed(_ job: Job, _ error: LBError) {
        switch error {
        case .rateLimited(let seconds):
            notBefore = now().addingTimeInterval(max(1, seconds))
        case .invalidToken:
            connection = .tokenRejected
            problem = "ListenBrainz no longer accepts the token. Paste a new one."
        case .rejected:
            switch job {
            case .playingNow:
                break
            case .queued(let ls, _):
                if ls.count > 1 {
                    oneAtATime = true
                } else if let l = ls.first {
                    saved.pending.removeAll { $0.key == l.key }
                    saved.refused.append(l)
                    persist()
                }
            case .history(let ls, let through, let skipped):
                if ls.count > 1 {
                    historyOneAtATimeUntil = through
                } else if var h = saved.history {
                    h.cursor = through
                    h.refused += 1
                    h.skipped += skipped
                    saved.history = h
                    persist()
                }
            }
            notBefore = now().addingTimeInterval(1)
        case .server, .network:
            failures += 1
            let delay = Self.backoff(failures)
            retryAt = now().addingTimeInterval(delay)
            notBefore = retryAt ?? notBefore
            problem = error.message
        }
    }

    /// 15 s, 30 s, 1 min, ... up to 15 min.
    static func backoff(_ failures: Int) -> TimeInterval {
        min(maxBackoff, 15 * pow(2, Double(max(0, failures - 1))))
    }

    // MARK: Disk

    private static func load(_ url: URL) -> Saved? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Saved.self, from: data)
        } catch {
            // Keep the unreadable file for a person to look at, and start afresh.
            NSLog("Tonearm: could not read %@: %@", url.path, "\(error)")
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable"))
            return nil
        }
    }

    private func persist() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        } catch {
            NSLog("Tonearm: could not save the ListenBrainz queue: %@", "\(error)")
        }
    }

    // MARK: Helpers

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func before(_ a: ListenCursor, _ b: ListenCursor) -> Bool {
        a.startedAt != b.startedAt ? a.startedAt < b.startedAt : a.id < b.id
    }
}

/// Sends what `PlayRecorder` records to the history and to ListenBrainz.
final class ListenTee: ListenSink {
    private let store: ListenSink
    private let listenBrainz: ListenBrainzSync

    init(store: ListenSink, listenBrainz: ListenBrainzSync) {
        self.store = store
        self.listenBrainz = listenBrainz
    }

    func save(_ listen: LiveListen) {
        store.save(listen)
        // PlayRecorder runs on the main actor.
        MainActor.assumeIsolated { listenBrainz.heard(listen) }
    }

    func flush(timeout: TimeInterval) {
        store.flush(timeout: timeout)
    }
}
