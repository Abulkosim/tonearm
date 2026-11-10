import AppKit
import SwiftUI

@main
enum Entry {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            Snapshot.render(to: url)
            let dir = url.pathExtension.lowercased() == "png" ? url.deletingLastPathComponent() : url
            SettingsView.renderSnapshot(to: dir.appendingPathComponent("settings.png"))
            exit(0)
        }
        // Runs once the app's run loop is up. Never reached in --snapshot runs or tests.
        Task { @MainActor in Updater.shared.start() }
        TonearmApp.main()
    }
}

struct TonearmApp: App {
    @StateObject private var model = PlayerModel()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some Scene {
        MenuBarExtra {
            PlayerView()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(launchAtLogin)
        } label: {
            MenuBarLabel(model: model, settings: settings)
        }
        .menuBarExtraStyle(.window)
    }
}
