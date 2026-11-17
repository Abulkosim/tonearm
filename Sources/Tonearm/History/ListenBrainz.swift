import Foundation

/// One listen in the form ListenBrainz takes. Built from a live listen or a stored one.
struct LBListen: Codable, Equatable {
    /// Tonearm's own id for the play, so it is queued once. Never sent.
    var key: String
    /// When the play started, in Unix seconds (UTC). Nil only for "playing now".
    var listenedAt: Int64?
    var track: String
    var artist: String
    var release: String?
    var durationMs: Int64?
    /// spotify:track:..., if Spotify gave one.
    var spotifyURI: String?
}

/// The ListenBrainz API: the rules from its docs and an HTTP client. Off unless the user
/// turns it on and gives a token. See docs/history.md.
///
/// Docs: https://listenbrainz.readthedocs.io/en/latest/users/api/core.html and
/// https://listenbrainz.readthedocs.io/en/latest/users/json.html
enum ListenBrainz {
    static let api = URL(string: "https://api.listenbrainz.org")!
    static let settingsPage = URL(string: "https://listenbrainz.org/settings/")!

    // Limits from the API docs.
    static let maxListensPerRequest = 1000
    static let maxPayloadBytes = 10_240_000
    static let maxListenBytes = 10_240
    static let minimumTimestamp: Int64 = 1_033_430_400
    static let maxDurationMs: Int64 = 2_073_600_000

    enum ListenType: String {
        case single
        case playingNow = "playing_now"
        case `import`
    }

    /// "Listens should be submitted for tracks when the user has listened to half the track
    /// or 4 minutes of the track, whichever is lower." Without a length, 4 minutes.
    static func threshold(durationMs: Int64?) -> Int64 {
        guard let d = durationMs, d > 0 else { return 240_000 }
        return min(240_000, d / 2)
    }

    static func counts(msPlayed: Int64, durationMs: Int64?) -> Bool {
        msPlayed > 0 && msPlayed >= threshold(durationMs: durationMs)
    }

    static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// One element of "payload". Optional fields are left out when unknown, as the docs ask.
    static func listenObject(_ l: LBListen, type: ListenType) -> [String: Any] {
        var info: [String: Any] = [
            "media_player": "Spotify",
            "submission_client": "Tonearm",
            "submission_client_version": clientVersion,
            "music_service": "spotify.com",
        ]
        if let uri = l.spotifyURI, uri.hasPrefix("spotify:track:"), let url = SpotifyLink.webURL(for: uri) {
            info["spotify_id"] = url.absoluteString
        }
        if let d = l.durationMs, d > 0, d <= maxDurationMs {
            info["duration_ms"] = d
        }
        var meta: [String: Any] = [
            "artist_name": l.artist,
            "track_name": l.track,
            "additional_info": info,
        ]
        if let release = l.release, !release.isEmpty { meta["release_name"] = release }
        var object: [String: Any] = ["track_metadata": meta]
        // "Timestamp must be omitted from a playing_now submission."
        if type != .playingNow, let at = l.listenedAt { object["listened_at"] = at }
        return object
    }

    static func body(_ type: ListenType, _ listens: [LBListen]) throws -> Data {
        let object: [String: Any] = [
            "listen_type": type.rawValue,
            "payload": listens.map { listenObject($0, type: type) },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Bytes one listen adds to a request.
    static func size(_ l: LBListen, type: ListenType) -> Int {
        (try? JSONSerialization.data(withJSONObject: listenObject(l, type: type)).count) ?? maxListenBytes
    }

    /// Something the server can take: a name, an artist, a time it accepts, and not too big.
    static func isSendable(_ l: LBListen, type: ListenType) -> Bool {
        guard !l.track.isEmpty, !l.artist.isEmpty else { return false }
        if type != .playingNow {
            guard let at = l.listenedAt, at >= minimumTimestamp else { return false }
        }
        return size(l, type: type) < maxListenBytes - 200
    }

    /// The longest run from `listens`, in order, that fits one request.
    static func batch(_ listens: ArraySlice<LBListen>, type: ListenType, limit: Int = maxListensPerRequest)
        -> ArraySlice<LBListen>
    {
        var bytes = 64
        var end = listens.startIndex
        while end < listens.endIndex, end - listens.startIndex < limit {
            let next = size(listens[end], type: type) + 1
            if bytes + next > maxPayloadBytes { break }
            bytes += next
            end += 1
        }
        return listens[listens.startIndex..<max(end, min(listens.startIndex + 1, listens.endIndex))]
    }
}

/// What the rate limit headers said after a request.
struct LBRateLimit: Equatable {
    var limit: Int?
    var remaining: Int?
    /// "X-RateLimit-Reset-In": seconds until the window resets.
    var resetIn: TimeInterval?

    init(limit: Int? = nil, remaining: Int? = nil, resetIn: TimeInterval? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.resetIn = resetIn
    }

    init(_ response: HTTPURLResponse) {
        func number(_ name: String) -> Double? {
            response.value(forHTTPHeaderField: name).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        limit = number("X-RateLimit-Limit").map { Int($0) }
        remaining = number("X-RateLimit-Remaining").map { Int($0) }
        resetIn = number("X-RateLimit-Reset-In")
    }

    /// How long to wait before the next request: at least a second (the docs ask for no
    /// more than one call per second), and until the reset when none are left.
    var wait: TimeInterval {
        if remaining == 0, let resetIn { return max(1, resetIn) }
        return 1
    }
}

enum LBError: Error, Equatable {
    /// 401, or validate-token said the token is not valid.
    case invalidToken
    /// 429. Seconds to wait.
    case rateLimited(TimeInterval)
    /// 400 or 413: the server will never take this request as it is.
    case rejected(Int, String)
    /// 5xx or anything else unexpected. Worth trying again.
    case server(Int)
    /// No answer: offline, timed out, DNS.
    case network(String)

    var retryable: Bool {
        switch self {
        case .server, .network, .rateLimited: return true
        case .invalidToken, .rejected: return false
        }
    }

    var message: String {
        switch self {
        case .invalidToken: return "ListenBrainz did not accept the token."
        case .rateLimited: return "ListenBrainz asked Tonearm to slow down."
        case .rejected(let status, let text): return "ListenBrainz refused a listen (\(status)). \(text)"
        case .server(let status): return "ListenBrainz had an error (\(status))."
        case .network: return "Can't reach ListenBrainz."
        }
    }
}

/// Talks to the ListenBrainz API. Stateless; `ListenBrainzSync` decides what to send when.
final class ListenBrainzClient: @unchecked Sendable {
    let session: URLSession
    let base: URL

    init(session: URLSession = ListenBrainzClient.defaultSession(), base: URL = ListenBrainz.api) {
        self.session = session
        self.base = base
    }

    static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    /// GET /1/validate-token. Returns the ListenBrainz user name for a good token.
    func validate(token: String) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("1/validate-token"))
        request.httpMethod = "GET"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await send(request)
        switch http.statusCode {
        case 200:
            return try Self.parseValidation(data)
        case 400, 401: throw LBError.invalidToken
        case 429: throw LBError.rateLimited(LBRateLimit(http).resetIn ?? 10)
        default: throw LBError.server(http.statusCode)
        }
    }

    /// Reads a validate-token reply. The docs show the "invalid" reply with a trailing comma,
    /// which is not valid JSON, so this does not depend on the JSON parsing.
    static func parseValidation(_ data: Data) throws -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard object["valid"] as? Bool == true else { throw LBError.invalidToken }
            return object["user_name"] as? String ?? ""
        }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: " ", with: "")
        if text.contains("\"valid\":true") { return "" }
        throw LBError.invalidToken
    }

    /// POST /1/submit-listens. Throws `LBError`.
    @discardableResult
    func submit(_ type: ListenBrainz.ListenType, _ listens: [LBListen], token: String) async throws -> LBRateLimit {
        var request = URLRequest(url: base.appendingPathComponent("1/submit-listens"))
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ListenBrainz.body(type, listens)
        let (data, http) = try await send(request)
        let rate = LBRateLimit(http)
        switch http.statusCode {
        case 200: return rate
        case 401: throw LBError.invalidToken
        case 429: throw LBError.rateLimited(rate.resetIn ?? 10)
        case 400, 413: throw LBError.rejected(http.statusCode, Self.errorText(data))
        default: throw LBError.server(http.statusCode)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LBError.network("not HTTP") }
            return (data, http)
        } catch let error as LBError {
            throw error
        } catch {
            throw LBError.network(error.localizedDescription)
        }
    }

    private static func errorText(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["error"] as? String) ?? ""
    }
}
