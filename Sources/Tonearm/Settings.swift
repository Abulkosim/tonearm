import Foundation

/// How much of the player the popover shows.
enum PlayerLayout: String, CaseIterable {
    /// Big cover on top.
    case large
    /// Small cover next to the title, for a shorter popover.
    case compact
}

/// User preferences, stored in UserDefaults.
final class AppSettings: ObservableObject {
    enum MenuBarStyle: String, CaseIterable {
        case songTitle
        case iconOnly
    }

    static let shared = AppSettings()

    static let titleLengthRange = 15...60
    static let titleLengthStep = 4
    /// Short enough to stay visible beside the notch on MacBooks that have one. People who
    /// changed the length keep theirs: it is stored, and only the fallback changed.
    static let defaultTitleLength = 24

    private enum Key {
        static let menuBarStyle = "menuBarStyle"
        static let maxTitleLength = "maxTitleLength"
        static let showArtist = "showArtist"
        static let layout = "layout"
        static let globalShortcuts = "globalShortcuts"
        static let notifyOnTrackChange = "notifyOnTrackChange"
    }

    private let defaults: UserDefaults

    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle) }
    }

    /// Longest menu bar title, in characters, ellipsis included.
    @Published var maxTitleLength: Int {
        didSet { defaults.set(Self.clampLength(maxTitleLength), forKey: Key.maxTitleLength) }
    }

    /// Adds " · Artist" after the song title in the menu bar.
    @Published var showArtist: Bool {
        didSet { defaults.set(showArtist, forKey: Key.showArtist) }
    }

    @Published var layout: PlayerLayout {
        didSet { defaults.set(layout.rawValue, forKey: Key.layout) }
    }

    /// ⌃⌥P, ⌃⌥N and ⌃⌥B control Spotify from any app. See `HotKeys`.
    @Published var globalShortcuts: Bool {
        didSet { defaults.set(globalShortcuts, forKey: Key.globalShortcuts) }
    }

    /// Shows a notification when the song changes. See `TrackNotifier`.
    @Published var notifyOnTrackChange: Bool {
        didSet { defaults.set(notifyOnTrackChange, forKey: Key.notifyOnTrackChange) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarStyle = defaults.string(forKey: Key.menuBarStyle).flatMap(MenuBarStyle.init(rawValue:)) ?? .songTitle
        maxTitleLength = Self.clampLength(defaults.object(forKey: Key.maxTitleLength) as? Int ?? Self.defaultTitleLength)
        showArtist = defaults.bool(forKey: Key.showArtist)
        layout = defaults.string(forKey: Key.layout).flatMap(PlayerLayout.init(rawValue:)) ?? .large
        globalShortcuts = defaults.bool(forKey: Key.globalShortcuts)
        notifyOnTrackChange = defaults.bool(forKey: Key.notifyOnTrackChange)
    }

    static func clampLength(_ n: Int) -> Int {
        min(max(n, titleLengthRange.lowerBound), titleLengthRange.upperBound)
    }
}
