import AppKit
import SwiftUI

/// Tonearm has no Dock icon and no window, so opening it shows nothing until you find its
/// icon in the menu bar. On a full menu bar, or behind the notch, there may be nothing to
/// find. The welcome window says where it went, once, on the first launch. Opening the app
/// again while it runs opens the player, or the welcome window when the icon is hidden.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Onboarding.welcomeShown else { return }
        // Give the status item a moment to appear, so the window can sit under it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in Onboarding.showWelcome() }
        }
    }

    /// Opening Tonearm.app while it already runs, from Finder, Spotlight or Launchpad.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Onboarding.reopened()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

enum Onboarding {
    /// Identifies the welcome window, so the player's key handling and window tracking skip it.
    static let windowID = NSUserInterfaceItemIdentifier("tonearm.welcome")
    static let spotifyDownloadURL = URL(string: "https://www.spotify.com/download")!
    private static let shownKey = "welcomeShown"

    static var welcomeShown: Bool {
        get { UserDefaults.standard.bool(forKey: shownKey) }
        set { UserDefaults.standard.set(newValue, forKey: shownKey) }
    }

    private static var controller: WelcomeWindowController?

    /// Shows the welcome window and brings Tonearm to the front.
    @MainActor
    static func showWelcome() {
        welcomeShown = true
        let controller = controller ?? WelcomeWindowController()
        Self.controller = controller
        controller.show()
    }

    @MainActor
    static func reopened() {
        if let controller, controller.isVisible {
            controller.show()
        } else if StatusItem.isPlayerOpen {
            activate()
        } else if StatusItem.isProbablyVisible, StatusItem.click() {
            return
        } else {
            showWelcome()
        }
    }

    /// From the welcome window's button: close it, then open the player under the icon.
    @MainActor
    static func openPlayer() {
        controller?.close()
        guard StatusItem.isProbablyVisible else { return }
        // Let the welcome window finish closing, or the player opens and loses focus at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in StatusItem.click() }
        }
    }

    /// An agent app (LSUIElement) is not brought forward on its own.
    @MainActor
    static func activate() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Status item

/// Finds the MenuBarExtra's status item. SwiftUI does not expose it, so this looks for the
/// window AppKit puts the menu bar button in. Everything here fails soft.
@MainActor
enum StatusItem {
    static var window: NSWindow? {
        NSApp.windows.first { $0.className == "NSStatusBarWindow" }
    }

    static var button: NSStatusBarButton? {
        var stack: [NSView] = window?.contentView.map { [$0] } ?? []
        while !stack.isEmpty {
            let view = stack.removeFirst()
            if let button = view as? NSStatusBarButton { return button }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// True when a window other than the status item and the welcome window is on screen.
    static var isPlayerOpen: Bool {
        NSApp.windows.contains { w in
            w.className != "NSStatusBarWindow" && w.identifier != Onboarding.windowID
                && w.isVisible && w.frame.width > 40
        }
    }

    /// False when the icon is missing, off screen (a full menu bar) or under the notch.
    static var isProbablyVisible: Bool {
        guard let window, window.isVisible, window.occlusionState.contains(.visible),
              window.frame.width > 0
        else { return false }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return false }
        return !Notch.hides(window.frame, left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
    }

    /// Clicks the icon, which opens the player. False when there is no icon to click.
    @discardableResult
    static func click() -> Bool {
        guard let button else { return false }
        Onboarding.activate()
        button.performClick(nil)
        return true
    }
}

/// Pure geometry, for tests.
enum Notch {
    /// True when the item's center falls in the gap between the menu bar areas left and
    /// right of the camera housing. Screens without a notch have no such areas.
    static func hides(_ item: NSRect, left: NSRect?, right: NSRect?) -> Bool {
        guard let left, let right, right.minX > left.maxX else { return false }
        return item.midX > left.maxX && item.midX < right.minX
    }
}

// MARK: - Window

@MainActor
private final class WelcomeWindowController {
    private let window: NSWindow

    init() {
        let window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: WelcomeView.width, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.identifier = Onboarding.windowID
        window.title = "Welcome to Tonearm"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0x18 / 255, green: 0x18 / 255, blue: 0x18 / 255, alpha: 1)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let content = WelcomeView(
            spotifyInstalled: NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyBridge.bundleID) != nil,
            openPlayer: { Onboarding.openPlayer() }
        )
        let hosting = NSHostingView(rootView: content)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        self.window = window
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        if !window.isVisible { place() }
        Onboarding.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    /// Under the menu bar icon when it is visible, so the drawn arrow points at the real
    /// one. Centered otherwise.
    private func place() {
        guard StatusItem.isProbablyVisible, let item = StatusItem.window,
              let screen = item.screen ?? NSScreen.main
        else { return window.center() }
        let area = screen.visibleFrame
        let size = window.frame.size
        var x = item.frame.midX - size.width + WelcomeView.arrowTipFromRight
        x = min(max(x, area.minX + 12), area.maxX - size.width - 12)
        window.setFrameTopLeftPoint(NSPoint(x: x, y: area.maxY - 12))
    }
}

/// Closes on Escape, like a sheet.
private final class WelcomeWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

// MARK: - View

/// Content of the welcome window. No AppKit controls inside, so snapshots can render it.
struct WelcomeView: View {
    static let width: CGFloat = 360
    private static let padding: CGFloat = 24
    /// Where the arrow ends, measured from the right edge of the content.
    static let arrowTipFromRight: CGFloat = padding + MenuBarSketch.glyphCenterFromRight

    let spotifyInstalled: Bool
    let openPlayer: () -> Void
    @ObservedObject private var login = LaunchAtLogin.shared

    init(spotifyInstalled: Bool, openPlayer: @escaping () -> Void) {
        self.spotifyInstalled = spotifyInstalled
        self.openPlayer = openPlayer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarSketch()

            Text("Tonearm lives in the menu bar")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 20)
            Text("Click its icon at the top of the screen to open the player")
                .font(.system(size: 13))
                .foregroundColor(PlayerTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                note(title: "Don't see it?",
                     text: "Your menu bar may be full; hold ⌘ and drag other icons out, or quit a few menu bar apps")
                if !spotifyInstalled {
                    note(title: "Spotify isn't installed",
                         text: "Tonearm works with the Spotify desktop app") {
                        Button("Get Spotify") { NSWorkspace.shared.open(Onboarding.spotifyDownloadURL) }
                            .buttonStyle(TextButtonStyle())
                            .padding(.horizontal, -4)
                            .help("Opens spotify.com/download")
                    }
                }
            }
            .padding(.top, 16)

            PlayerTheme.hairline
                .frame(height: 1)
                .padding(.top, 20)

            HStack(spacing: 12) {
                Text("Launch at login")
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                GreenSwitch(isOn: Binding(get: { login.isOn }, set: { login.setEnabled($0) }),
                            label: "Launch at login")
                Spacer(minLength: 12)
                Button("Open player", action: openPlayer)
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, 40)
        .padding(.bottom, Self.padding)
        .frame(width: Self.width)
        .background(PlayerTheme.fallback)
        .environment(\.colorScheme, .dark)
        .hidesSystemFocusRing()
        .onAppear { login.refresh() }
    }

    private func note(title: String, text: String) -> some View {
        note(title: title, text: text) { EmptyView() }
    }

    private func note<Action: View>(title: String, text: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(PlayerTheme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// A sketch of the right end of the menu bar with Tonearm's icon picked out, and an arrow
/// from the app icon up to it.
struct MenuBarSketch: View {
    private static let barHeight: CGFloat = 28
    private static let iconSize: CGFloat = 56
    private static let height: CGFloat = 112
    private static let edge: CGFloat = 12
    private static let glyphWidth: CGFloat = 28
    private static let gap: CGFloat = 12
    /// Clock, battery and Wi-Fi sit right of the glyph, in fixed boxes, so its spot is known.
    private static let trailing: [CGFloat] = [36, 24, 16]
    static let glyphCenterFromRight: CGFloat =
        edge + trailing.reduce(0, +) + gap * CGFloat(trailing.count) + glyphWidth / 2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let tip = CGPoint(x: w - Self.glyphCenterFromRight, y: Self.barHeight + 6)
            let start = CGPoint(x: Self.iconSize + 12, y: Self.height - Self.iconSize / 2)
            ZStack(alignment: .topLeading) {
                bar
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .offset(y: Self.height - Self.iconSize)
                    .accessibilityHidden(true)
                Arrow(from: start, to: tip)
                    .stroke(PlayerTheme.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    private var bar: some View {
        HStack(spacing: Self.gap) {
            Spacer(minLength: 0)
            // Other apps' icons, left abstract.
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 14, height: 12)
            }
            Image(systemName: MenuBarLabel.appGlyph)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(width: Self.glyphWidth, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.2)))
            Image(systemName: "wifi")
                .frame(width: Self.trailing[2])
            Image(systemName: "battery.75")
                .frame(width: Self.trailing[1])
            Text("10:42")
                .frame(width: Self.trailing[0], alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(PlayerTheme.textSecondary)
        .padding(.trailing, Self.edge)
        .frame(height: Self.barHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// A curve that leaves `from` going right and reaches `to` going up, with a small head.
private struct Arrow: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: CGPoint(x: to.x, y: from.y))
        p.move(to: CGPoint(x: to.x - 5, y: to.y + 7))
        p.addLine(to: to)
        p.addLine(to: CGPoint(x: to.x + 5, y: to.y + 7))
        return p
    }
}

// MARK: - Snapshot

extension Onboarding {
    /// The welcome window's content, for snapshots.
    @MainActor
    static func snapshotView(spotifyInstalled: Bool) -> some View {
        WelcomeView(spotifyInstalled: spotifyInstalled, openPlayer: {})
    }
}
