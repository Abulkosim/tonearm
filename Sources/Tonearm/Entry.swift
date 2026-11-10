import AppKit
import SwiftUI

@main
enum Entry {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        TonearmApp.main()
    }
}

struct TonearmApp: App {
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        MenuBarExtra {
            PlayerView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
