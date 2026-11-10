import AppKit
import SwiftUI

// Why this exists
//
// With `.menuBarExtraStyle(.window)` SwiftUI sizes the window when it opens, but while it is
// open it does not shrink the window when the content gets shorter (player -> settings, or
// Spotify quitting). The short content then sits in the middle of a tall window, with the
// system material showing above and below it. Reopening can also bring back a stale size.
//
// The fix
//
// 1. Measure the content at its ideal height (`fixedSize` + GeometryReader).
// 2. A zero-size AppKit view finds the hosting NSWindow, and we set the window frame to that
//    size ourselves, keeping the top edge fixed so the window stays attached to the menu bar.
//    We re-check when the window opens or something else resizes it.
// 3. The content is pinned to the top of whatever space it gets, and the caller's background
//    goes outside this modifier, so it always fills the window edge to edge, even for the
//    few frames of a resize.
// 4. The window's own material is hidden and its background cleared, so only our view (with
//    its own rounded corners) is visible. If the material is an ancestor of our view and
//    cannot be hidden, our opaque background still covers it.

extension View {
    /// Keeps the MenuBarExtra window exactly the size of this view. Apply the background
    /// after this modifier so it fills the window.
    func fitsMenuBarWindow(_ enabled: Bool = true) -> some View {
        modifier(MenuBarWindowFit(enabled: enabled))
    }
}

private struct MenuBarWindowFit: ViewModifier {
    let enabled: Bool
    @StateObject private var fitter = WindowFitter()

    func body(content: Content) -> some View {
        if enabled {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { fitter.contentSizeChanged(geo.size) }
                        .onChange(of: geo.size) { fitter.contentSizeChanged($0) }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(WindowReader(fitter: fitter))
                .onAppear { fitter.windowShown() }
        } else {
            content
        }
    }
}

@MainActor
final class WindowFitter: ObservableObject {
    private weak var window: NSWindow?
    private var contentSize: CGSize = .zero
    private var observers: [NSObjectProtocol] = []
    private var animatingUntil = Date.distantPast
    /// Times we undid someone else's resize since the last change of ours. Capped so we
    /// never fight SwiftUI in a loop.
    private var reasserts = 0

    func contentSizeChanged(_ size: CGSize) {
        guard size != contentSize else { return }
        let first = contentSize == .zero
        contentSize = size
        reasserts = 0
        // Let SwiftUI finish this layout pass before touching the window.
        Task { @MainActor in self.fit(animate: !first) }
    }

    func windowShown() {
        reasserts = 0
        Task { @MainActor in self.fit(animate: false) }
    }

    fileprivate func attach(to window: NSWindow?, from view: NSView) {
        guard window !== self.window else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        self.window = window
        guard let window else { return }

        Self.hideSystemBackground(of: window, keeping: view)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                            object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windowShown() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                            object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windowResizedElsewhere() }
        })
        fit(animate: false)
    }

    private func windowResizedElsewhere() {
        // Our own setFrame also posts this; only a size we did not ask for counts.
        guard Date() > animatingUntil, needsFit, reasserts < 3 else { return }
        reasserts += 1
        fit(animate: false)
    }

    /// True when the window's content size differs from the measured size.
    private var needsFit: Bool {
        guard let window, contentSize.width > 0, contentSize.height > 0 else { return false }
        let current = window.contentRect(forFrameRect: window.frame)
        return abs(current.width - contentSize.width) > 0.5 || abs(current.height - contentSize.height) > 0.5
    }

    /// Sets the window's content size to the measured size, top edge fixed.
    private func fit(animate: Bool) {
        guard let window, needsFit else { return }
        let current = window.contentRect(forFrameRect: window.frame)

        var frame = window.frameRect(forContentRect: NSRect(origin: current.origin, size: contentSize))
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate && window.isVisible && !reduceMotion {
            let duration = 0.2
            animatingUntil = Date().addingTimeInterval(duration + 0.1)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak window] in
                Task { @MainActor in window?.invalidateShadow() }
            })
        } else {
            window.setFrame(frame, display: true, animate: false)
            window.invalidateShadow()
        }
    }

    /// Clears the window background and hides the system material views that are not
    /// ancestors of our content, so nothing shows around our rounded view.
    private static func hideSystemBackground(of window: NSWindow, keeping view: NSView) {
        window.isOpaque = false
        window.backgroundColor = .clear
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            if isMaterial(v), !view.isDescendant(of: v) {
                v.isHidden = true
                continue
            }
            stack.append(contentsOf: v.subviews)
        }
        if ProcessInfo.processInfo.environment["TONEARM_DEBUG_WINDOW"] != nil {
            NSLog("Tonearm window: %@ styleMask=%lu\n%@", String(describing: type(of: window)),
                  window.styleMask.rawValue, describe(root, depth: 0))
        }
    }

    private static func isMaterial(_ v: NSView) -> Bool {
        // NSGlassEffectView (macOS 26) is matched by name; this SDK may not have the class.
        v is NSVisualEffectView || String(describing: type(of: v)).contains("GlassEffect")
    }

    private static func describe(_ v: NSView, depth: Int) -> String {
        let line = String(repeating: "  ", count: depth)
            + "\(type(of: v)) \(NSStringFromRect(v.frame))\(v.isHidden ? " hidden" : "")"
        return ([line] + v.subviews.map { describe($0, depth: depth + 1) }).joined(separator: "\n")
    }
}

/// Zero-size view that reports the window it lands in.
private struct WindowReader: NSViewRepresentable {
    let fitter: WindowFitter

    func makeNSView(context: Context) -> NSView {
        let view = WindowReaderView()
        view.fitter = fitter
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowReaderView: NSView {
    weak var fitter: WindowFitter?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitter?.attach(to: window, from: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
