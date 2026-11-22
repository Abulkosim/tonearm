import AppKit
import UserNotifications

/// Posts a notification when the song changes, with the cover if it arrives in time.
/// Skips the first song seen after launch, ads, changes while the popover is open, and
/// songs skipped before they settled: skipping through five songs posts one notification.
@MainActor
final class TrackNotifier {
    /// UNUserNotificationCenter throws an Objective-C exception outside an .app bundle,
    /// so `swift test` and a bare binary must never touch it.
    nonisolated static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// How long to wait for the cover before posting without it.
    static let artworkWait: TimeInterval = 2.5
    /// How long a song must play before it gets a notification. A cover already loaded
    /// arrives at once, so without this every skip posted one.
    static let settleTime: TimeInterval = 1
    static let requestID = "tonearm.track"

    private let isEnabled: @MainActor () -> Bool
    private let isPopoverVisible: @MainActor () -> Bool
    private let settle: TimeInterval
    private let artworkWait: TimeInterval
    private let post: @MainActor (Track, NSImage?) -> Void
    /// Id of the last song seen, nil before the first.
    private var lastSeenID: String?
    private var pending: Track?
    private var pendingImage: NSImage?
    /// The cover for `pending` loaded, or is known to be missing.
    private var artworkKnown = false
    /// `pending` has been the song for `settle` seconds.
    private var settled = false
    private var timers: [DispatchWorkItem] = []

    /// `settle` and `artworkWait` default to `settleTime` and `artworkWait`. `post` shows the
    /// notification; tests pass their own.
    init(isEnabled: @escaping @MainActor () -> Bool, isPopoverVisible: @escaping @MainActor () -> Bool,
         settle: TimeInterval? = nil, artworkWait: TimeInterval? = nil,
         post: (@MainActor (Track, NSImage?) -> Void)? = nil) {
        self.isEnabled = isEnabled
        self.isPopoverVisible = isPopoverVisible
        let settle = settle ?? Self.settleTime
        self.settle = settle
        self.artworkWait = max(artworkWait ?? Self.artworkWait, settle)
        self.post = post ?? { Self.show($0, image: $1) }
    }

    /// Pure decision, for tests.
    nonisolated static func shouldNotify(previousID: String?, track: Track?, enabled: Bool,
                                         popoverVisible: Bool) -> Bool {
        guard enabled, !popoverVisible, let track, let previousID else { return false }
        guard track.id != previousID, !track.title.isEmpty else { return false }
        return !track.id.hasPrefix("spotify:ad:")
    }

    /// "Artist — Album", leaving out empty parts.
    nonisolated static func body(for track: Track) -> String {
        [track.artist, track.album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// Call whenever the current song may have changed.
    func trackChanged(_ track: Track?) {
        guard let track, !track.id.isEmpty || !track.title.isEmpty else { return }
        let key = Self.key(track)
        let previous = lastSeenID
        guard key != previous else { return }
        lastSeenID = key
        cancelPending()
        var keyed = track
        keyed.id = key
        guard Self.shouldNotify(previousID: previous, track: keyed, enabled: isEnabled(),
                                popoverVisible: isPopoverVisible())
        else { return }
        pending = track
        after(settle) { notifier in
            notifier.settled = true
            if notifier.artworkKnown { notifier.postPending() }
        }
        after(artworkWait) { $0.postPending() }
    }

    /// Call when the cover for `trackID` has loaded, or is known to be missing.
    func artworkReady(_ image: NSImage?, trackID: String) {
        guard let pending, pending.id == trackID, !artworkKnown else { return }
        pendingImage = image
        artworkKnown = true
        if settled { postPending() }
    }

    private func after(_ seconds: TimeInterval, _ body: @escaping @MainActor (TrackNotifier) -> Void) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
        timers.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Asks for permission to post. macOS shows its prompt only while the user has not
    /// answered yet, so call it only for `.notDetermined`. Calls back on the main actor.
    static func requestAuthorization(_ done: @escaping @MainActor (Bool) -> Void) {
        guard isAvailable else { return done(false) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error { NSLog("Tonearm: notification permission failed: %@", error.localizedDescription) }
            Task { @MainActor in done(granted) }
        }
    }

    enum Authorization: Equatable {
        case allowed, denied, notDetermined
        /// Not inside Tonearm.app (tests, a bare binary).
        case unavailable
    }

    /// What macOS currently allows, without asking. Calls back on the main actor.
    static func authorization(_ done: @escaping @MainActor (Authorization) -> Void) {
        guard isAvailable else { return done(.unavailable) }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let result: Authorization
            switch settings.authorizationStatus {
            case .denied: result = .denied
            case .notDetermined: result = .notDetermined
            default: result = .allowed
            }
            Task { @MainActor in done(result) }
        }
    }

    /// True when the user wants notifications but macOS blocks them. Pure, for tests.
    nonisolated static func isBlocked(settingOn: Bool, authorization: Authorization) -> Bool {
        settingOn && authorization == .denied
    }

    /// Makes banners show while Tonearm is the active app (macOS hides them otherwise) and
    /// runs `onClick` when the user clicks one. Call once, at startup.
    static func installDelegate(onClick: @escaping @MainActor @Sendable () -> Void) {
        guard isAvailable, delegate == nil else { return }
        let d = NotificationDelegate(onClick: onClick)
        delegate = d
        UNUserNotificationCenter.current().delegate = d
    }

    /// The notification center keeps only a weak reference.
    private static var delegate: NotificationDelegate?

    // MARK: Private

    /// Songs without an id (some local files) are told apart by title.
    private static func key(_ track: Track) -> String {
        track.id.isEmpty ? "title:\(track.title)|\(track.artist)" : track.id
    }

    private func cancelPending() {
        timers.forEach { $0.cancel() }
        timers = []
        pending = nil
        pendingImage = nil
        artworkKnown = false
        settled = false
    }

    private func postPending() {
        guard let track = pending else { return }
        let image = pendingImage
        cancelPending()
        // The popover may have opened while waiting for the cover.
        guard isEnabled(), !isPopoverVisible() else { return }
        post(track, image)
    }

    /// Posts to Notification Center. Only inside Tonearm.app. The cover is encoded and
    /// written off the main thread.
    private static func show(_ track: Track, image: NSImage?) {
        guard isAvailable else { return }
        let title = track.title, body = Self.body(for: track), id = requestID
        let cover = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        DispatchQueue.global(qos: .utility).async {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let file = cover.flatMap(writeTemporaryJPEG)
            if let file, let attachment = try? UNNotificationAttachment(identifier: "cover", url: file, options: nil) {
                content.attachments = [attachment]
            }
            // One identifier, so each song replaces the last one in Notification Center.
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { NSLog("Tonearm: notification failed: %@", error.localizedDescription) }
                // macOS moves the file into its own store on success; clean up if it did not.
                if let file { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    private nonisolated static func writeTemporaryJPEG(_ cg: CGImage) -> URL? {
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg,
                                                                      properties: [.compressionFactor: 0.85])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tonearm-cover-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let onClick: @MainActor @Sendable () -> Void

    init(onClick: @escaping @MainActor @Sendable () -> Void) {
        self.onClick = onClick
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let onClick = onClick
            Task { @MainActor in onClick() }
        }
        completionHandler()
    }
}
