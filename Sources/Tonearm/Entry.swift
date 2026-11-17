import AppKit
import SwiftUI

@main
enum Entry {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--stats") {
            // Liner Notes from a Spotify export, without the app. See HistoryCLI.
            exit(HistoryCLI.run(Array(args.dropFirst())))
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            Snapshot.render(to: url)
            let dir = url.pathExtension.lowercased() == "png" ? url.deletingLastPathComponent() : url
            SettingsView.renderSnapshot(to: dir.appendingPathComponent("settings.png"))
            exit(0)
        }
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count {
            Snapshot.renderDemo(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        // Every screen in every state, for review. Fails when one is clipped. See StateWalk.
        if let i = args.firstIndex(of: "--states"), i + 1 < args.count {
            exit(StateWalk.render(to: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
        }
        // Runs once the app's run loop is up. Never reached in --snapshot, --demo or --states runs, or tests.
        Task { @MainActor in Updater.shared.start() }
        TonearmApp.main()
    }
}

struct TonearmApp: App {
    /// First-run welcome window, and opening the player when Tonearm.app is opened again.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
