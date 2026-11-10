import AppKit
import ServiceManagement

/// Wraps SMAppService.mainApp. Only works when running from a real .app bundle;
/// failures are logged and the switch falls back to the real status.
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    /// Read at start, so the switch is right before the settings panel first appears.
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status

    /// On when registered, or registered and waiting for the user's approval.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        let s = SMAppService.mainApp.status
        if s != status { status = s }
    }

    func setEnabled(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("Tonearm: launch at login %@ failed: %@",
                  on ? "register" : "unregister", error.localizedDescription)
        }
        refresh()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
