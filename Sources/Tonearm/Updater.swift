import AppKit
import Combine
import Sparkle

/// Checks for, downloads and installs updates with Sparkle.
///
/// The feed, the public key and the defaults (check once a day, download in the
/// background) are in Info.plist. A downloaded update is installed, and Tonearm
/// relaunched, the next time the window is closed, so a menu bar app that never
/// quits still gets it.
///
/// Sparkle only starts in the real app (`start()`, called from `TonearmApp`). The
/// `--snapshot` run and the tests read this object but never start it.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// Sparkle's own user defaults key, so the switch shows the right value before start.
    private static let autoCheckKey = "SUEnableAutomaticChecks"

    @Published private(set) var canCheck = false

    /// Daily background checks. Off means updates only come from "Check for Updates…".
    @Published var automaticallyChecks: Bool {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var installTimer: Timer?

    override init() {
        let stored = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool
        let plist = Bundle.main.object(forInfoDictionaryKey: Self.autoCheckKey) as? Bool
        automaticallyChecks = stored ?? plist ?? true
        super.init()
    }

    /// Starts Sparkle. Does nothing outside a .app bundle with a feed URL,
    /// for example `swift run`, where Sparkle would only show an error.
    func start() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: self,
                                                      userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    /// "Check for Updates…": Sparkle shows its window, which has to come to the
    /// front because Tonearm has no Dock icon and is usually not the active app.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Installs a downloaded update once no Tonearm window is in use; checks again every minute.
    private func installWhenIdle() {
        guard let install = pendingInstall else { return }
        if NSApp.keyWindow == nil {
            pendingInstall = nil
            installTimer?.invalidate()
            installTimer = nil
            install()
            return
        }
        guard installTimer == nil else { return }
        installTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.installWhenIdle() }
        }
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallHandler
        installWhenIdle()
        return true
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// Tonearm is a background app: without this, Sparkle may open its update
    /// window behind other apps where nobody sees it.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
