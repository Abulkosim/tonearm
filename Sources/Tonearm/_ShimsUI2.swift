// TEMPORARY. Stand-ins for the model and settings API that the core agent adds in round 2
// (shuffle, repeat, relative seek and volume, show in Spotify, copy link, layout and the two
// new settings). They let the UI build on its own. Delete this file when the core PR merges.

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

    func copyTrackLink() {
        guard let url = trackURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
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
