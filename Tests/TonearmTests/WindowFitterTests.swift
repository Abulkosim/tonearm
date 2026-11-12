import AppKit
import XCTest
@testable import Tonearm

@MainActor
final class WindowFitterTests: XCTestCase {
    private func window(height: CGFloat) -> NSWindow {
        NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: height),
                 styleMask: [.borderless], backing: .buffered, defer: true)
    }

    private func contentHeight(_ window: NSWindow) -> CGFloat {
        window.contentRect(forFrameRect: window.frame).height
    }

    /// Lets the fitter's deferred `fit` run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// The v0.3.3 log: the reader is replaced (the old one leaves after the new one arrived),
    /// then settings open. The window must still grow to the settings height.
    func testGrowsAfterReaderSwap() async {
        let window = window(height: 158)
        let fitter = WindowFitter()
        fitter.contentSizeChanged(CGSize(width: 300, height: 158))
        fitter.attach(to: window, from: NSView())
        fitter.attach(to: window, from: NSView())
        fitter.attach(to: nil, from: NSView())
        fitter.contentSizeChanged(CGSize(width: 300, height: 717))
        await settle()
        XCTAssertEqual(contentHeight(window), 717, accuracy: 0.5)
    }

    func testKeepsTopEdgeWhenShrinking() async {
        let window = window(height: 717)
        let top = window.frame.maxY
        let fitter = WindowFitter()
        fitter.attach(to: window, from: NSView())
        fitter.contentSizeChanged(CGSize(width: 300, height: 158))
        await settle()
        XCTAssertEqual(contentHeight(window), 158, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
    }

    /// Only the owner sizes the window: an older copy can't shrink it back.
    func testOnlyOwnerFits() async {
        let window = window(height: 158)
        let stale = WindowFitter()
        stale.contentSizeChanged(CGSize(width: 300, height: 158))
        stale.attach(to: window, from: NSView())
        let live = WindowFitter()
        live.attach(to: window, from: NSView())
        live.contentSizeChanged(CGSize(width: 300, height: 717))
        await settle()
        stale.windowShown()
        await settle()
        XCTAssertEqual(contentHeight(window), 717, accuracy: 0.5)
    }

    func testSizeTextHandlesUnlimitedSizes() {
        XCTAssertEqual(WindowFitter.text(CGSize(width: 300, height: 157.6)), "300 x 158")
        let unlimited = CGSize(width: CGFloat(Float.greatestFiniteMagnitude), height: .infinity)
        XCTAssertEqual(WindowFitter.text(unlimited), "max x max")
        XCTAssertEqual(WindowFitter.text(CGSize(width: CGFloat.nan, height: 1)), "max x 1")
    }
}
