import Foundation

/// User preferences, stored in UserDefaults.
final class AppSettings: ObservableObject {
    enum MenuBarStyle: String, CaseIterable {
        case songTitle
        case iconOnly
    }

    static let shared = AppSettings()

    static let titleLengthRange = 15...60
    static let titleLengthStep = 5
    static let defaultTitleLength = 30

    private enum Key {
        static let menuBarStyle = "menuBarStyle"
        static let maxTitleLength = "maxTitleLength"
        static let showArtist = "showArtist"
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarStyle = defaults.string(forKey: Key.menuBarStyle).flatMap(MenuBarStyle.init(rawValue:)) ?? .songTitle
        maxTitleLength = Self.clampLength(defaults.object(forKey: Key.maxTitleLength) as? Int ?? Self.defaultTitleLength)
        showArtist = defaults.bool(forKey: Key.showArtist)
    }

    static func clampLength(_ n: Int) -> Int {
        min(max(n, titleLengthRange.lowerBound), titleLengthRange.upperBound)
    }
}
