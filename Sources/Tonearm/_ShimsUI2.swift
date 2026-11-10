// TEMPORARY. Stand-ins for the model, settings and hot key API from the core PR (#9):
// shuffle, repeat, relative seek and volume, show in Spotify, copy link, permission prompt
// state, layout, the two new settings and HotKeys.Action. They mirror its signatures so the
// UI builds on its own. Delete this file when #9 merges.

import AppKit
import SwiftUI

enum PlayerLayout: String, CaseIterable {
    case large
    case compact
}

extension PlayerModel {
    var shuffling: Bool { false }
    var repeating: Bool { false }

    func toggleShuffle() {}
    func toggleRepeat() {}

    func seek(by seconds: Double) {
        seek(to: position(at: Date()) + seconds)
    }

    func changeVolume(by delta: Int) {
        setVolume(playback.volume + delta)
    }

    var trackURL: URL? {
        guard let id = track?.id, id.hasPrefix("spotify:track:") else { return nil }
        return URL(string: "https://open.spotify.com/track/" + id.dropFirst("spotify:track:".count))
    }

    func showInSpotify() {
        NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyBridge.bundleID)
            .first?.activate(options: [])
    }

    var isAskingPermission: Bool { false }

    func copyTrackLink() -> Bool {
        guard let url = trackURL else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        return true
    }
}

extension AppSettings {
    var layout: PlayerLayout {
        get {
            UserDefaults.standard.string(forKey: "shim.layout").flatMap(PlayerLayout.init(rawValue:)) ?? .large
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: "shim.layout")
        }
    }

    var globalShortcuts: Bool {
        get { UserDefaults.standard.bool(forKey: "shim.globalShortcuts") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "shim.globalShortcuts")
        }
    }

    var notifyOnTrackChange: Bool {
        get { UserDefaults.standard.bool(forKey: "shim.notifyOnTrackChange") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "shim.notifyOnTrackChange")
        }
    }
}

final class HotKeys {
    enum Action: UInt32, CaseIterable {
        case playPause = 1
        case next
        case previous

        var keys: String {
            switch self {
            case .playPause: return "⌃⌥P"
            case .next: return "⌃⌥N"
            case .previous: return "⌃⌥B"
            }
        }

        var title: String {
            switch self {
            case .playPause: return "Play or pause"
            case .next: return "Next song"
            case .previous: return "Previous song"
            }
        }
    }
}
