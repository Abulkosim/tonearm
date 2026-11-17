import AppKit
import Combine
import SwiftUI

/// The Liner Notes window: a SwiftUI `Window` scene, opened from the player.
///
/// Tonearm is an agent app (LSUIElement): no Dock icon, and macOS does not bring its windows
/// forward on their own. While Liner Notes is open Tonearm becomes a regular app, so the
/// window comes to the front, shows in the Dock and in ⌘Tab, and goes back to being a menu
/// bar app when it closes. The window keeps its size and place between openings.
@MainActor
enum LinerNotesWindow {
    nonisolated static let id = "liner-notes"
    static let frameName = "TonearmLinerNotes"
    static let defaultSize = CGSize(width: 960, height: 820)
    static let minSize = CGSize(width: 820, height: 560)

    /// The open window, once its content has landed in it.
    private(set) static weak var window: NSWindow?
    /// SwiftUI's action that opens a scene, kept by any view that has it, so code outside
    /// views (the Dock icon, the launch argument) can open the window too.
    static var opener: OpenWindowAction?
    /// Set when someone asked for the window. SwiftUI may also open a `Window` scene on its
    /// own at launch; that one is closed at once.
    private static var requested = false
    private static var closeObserver: NSObjectProtocol?

    /// True for the Liner Notes window, so the player's window tracking leaves it alone.
    /// SwiftUI names a scene's windows after the scene id ("liner-notes-AppWindow-1").
    nonisolated static func isLinerNotes(identifier: String?) -> Bool {
        identifier?.hasPrefix(id) == true
    }

    static func owns(_ w: NSWindow) -> Bool {
        w === window || isLinerNotes(identifier: w.identifier?.rawValue)
    }

    /// Opens the window, or brings it to the front.
    static func open(_ action: OpenWindowAction? = nil) {
        requested = true
        NSApp.setActivationPolicy(.regular)
        Onboarding.activate()
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        (action ?? opener)?(id: id)
    }

    /// Brings an open window to the front. False when it is not open.
    @discardableResult
    static func bringToFront() -> Bool {
        guard let window, window.isVisible else { return false }
        open()
        return true
    }

    /// Called when the content lands in its window.
    fileprivate static func attach(_ w: NSWindow) {
        guard w !== window else { return }
        guard requested else {
            // Opened by SwiftUI at launch or by state restoration, not by the user.
            log("closed a window opened at launch", w)
            DispatchQueue.main.async { w.close() }
            return
        }
        window = w
        w.title = "Liner Notes"
        w.tabbingMode = .disallowed
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.contentMinSize = minSize
        if w.frameAutosaveName.isEmpty {
            _ = w.setFrameUsingName(frameName)
            _ = w.setFrameAutosaveName(frameName)
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { _ in
            MainActor.assumeIsolated { closed() }
        }
        Onboarding.activate()
        w.makeKeyAndOrderFront(nil)
        log("opened", w)
    }

    private static func closed() {
        requested = false
        window = nil
        ShareSheet.removeTemporaryFiles()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        // Back to a menu bar app, unless the welcome window or an update window is still up.
        let others = NSApp.windows.contains { w in
            w.isVisible && w.className != "NSStatusBarWindow" && w.styleMask.contains(.titled) && !owns(w)
        }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }

    /// `Tonearm --open-liner-notes` opens the window at launch, for CI to look at.
    static var openAtLaunch: Bool { CommandLine.arguments.contains("--open-liner-notes") }

    /// With `--open-liner-notes` or `--log-windows`, one line on stderr per window this
    /// code sees: its identifier, its size, and whether the player's window tracking would
    /// take it for the popover. scripts/liner-notes-live.sh reads these.
    private static func log(_ event: String, _ w: NSWindow) {
        guard openAtLaunch || CommandLine.arguments.contains("--log-windows") else { return }
        let id = w.identifier?.rawValue ?? "none"
        let popover = PlayerModel.isPopoverWindow(className: w.className,
                                                  classBundleID: Bundle(for: type(of: w)).bundleIdentifier,
                                                  identifier: w.identifier?.rawValue)
        let line = "liner-notes-window: \(event) id=\(id) number=\(w.windowNumber) "
            + "size=\(Int(w.frame.width))x\(Int(w.frame.height)) popover=\(popover ? "yes" : "no")\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// The scene's root view.
struct LinerNotesRoot: View {
    @StateObject private var model = LinerNotesModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LinerNotesView(model: model)
            .background(WindowAttacher())
            .onAppear {
                LinerNotesWindow.opener = openWindow
                model.start()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard let w = note.object as? NSWindow, w === LinerNotesWindow.window else { return }
                model.windowBecameKey()
            }
    }
}

/// Keeps SwiftUI's open-window action where code outside views can reach it, and opens the
/// window at launch for `--open-liner-notes`. Lives in the menu bar label, which always exists.
struct LinerNotesOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                LinerNotesWindow.opener = openWindow
                if LinerNotesWindow.openAtLaunch {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MainActor.assumeIsolated { LinerNotesWindow.open(openWindow) }
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

/// A zero-size AppKit view that tells `LinerNotesWindow` which window the content is in.
private struct WindowAttacher: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AttachingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class AttachingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated { LinerNotesWindow.attach(window) }
        }
    }
}
