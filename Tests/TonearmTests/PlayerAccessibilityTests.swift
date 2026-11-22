import AppKit
import SwiftUI
import XCTest
@testable import Tonearm

/// Walks the accessibility tree AppKit builds for the player, the way VoiceOver sees it.
@MainActor
final class PlayerAccessibilityTests: XCTestCase {
    struct Element: CustomStringConvertible {
        var role: String
        var label: String
        var value: String
        var description: String { "\(role) \"\(label)\" = \"\(value)\"" }
    }

    /// SwiftUI builds its accessibility tree only once an assistive app asks for one. These
    /// are the attributes assistive apps set on an app to ask. The setter is called by name:
    /// its declaration is deprecated, and the attributes have no modern setter.
    override func setUp() {
        super.setUp()
        let set = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            _ = NSApplication.shared.perform(set, with: NSNumber(value: true), with: attribute)
        }
    }

    /// Asks an element for one attribute, the way an assistive app does. SwiftUI's own
    /// elements answer these messages without declaring NSAccessibilityProtocol, so a cast
    /// would skip them.
    private func ask(_ node: Any, _ name: String) -> Any? {
        guard let object = node as? NSObject else { return nil }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    /// Every element under the view, depth first, as AppKit reports them.
    private func elements<V: View>(of view: V, height: CGFloat = 700) -> [Element] {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var found: [Element] = []
        func walk(_ node: Any, depth: Int) {
            guard depth < 60 else { return }
            let role = ask(node, "accessibilityRole") as? String ?? ""
            let label = ask(node, "accessibilityLabel") as? String ?? ""
            // VoiceOver speaks the value description when there is one: a slider's value is
            // its number, the description is the words.
            let words = ask(node, "accessibilityValueDescription") as? String ?? ""
            let value = words.isEmpty ? ask(node, "accessibilityValue").map { "\($0)" } ?? "" : words
            if !(label.isEmpty && value.isEmpty) || role == NSAccessibility.Role.button.rawValue {
                found.append(Element(role: role, label: label, value: value))
            }
            for child in ask(node, "accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(host, depth: 0)
        window.orderOut(nil)
        window.contentView = nil
        return found
    }

    private func player(_ layout: PlayerLayout, state: PlayState = .playing, duration: Double = 214,
                        shuffling: Bool = false) -> some View {
        let model = PlayerModel(live: false)
        let track = Track(id: "spotify:track:a", title: "A Song", artist: "An Artist", album: "An Album",
                          artworkURL: nil, duration: duration)
        model.setPreview(Playback(state: state, track: track, position: 83, volume: 70, shuffling: shuffling),
                         artwork: nil)
        return PlayerView(preview: .init(layout: layout)).environmentObject(model)
    }

    private func element(_ label: String, in list: [Element], file: StaticString = #filePath,
                         line: UInt = #line) -> Element? {
        let match = list.first { $0.label == label }
        if match == nil {
            XCTFail("no element \"\(label)\" in:\n" + list.map(\.description).joined(separator: "\n"),
                    file: file, line: line)
        }
        return match
    }

    func testLargePlayerNamesEveryControlAndItsState() {
        let list = elements(of: player(.large))
        print("Large player accessibility tree:\n" + list.map(\.description).joined(separator: "\n"))
        XCTAssertNotNil(element("Pause", in: list), "play/pause says what it does while playing")
        XCTAssertNotNil(element("Previous track", in: list))
        XCTAssertNotNil(element("Next track", in: list))
        XCTAssertEqual(element("Shuffle", in: list)?.value, "Off")
        XCTAssertEqual(element("Repeat", in: list)?.value, "Off")
        let position = element("Playback position", in: list)
        XCTAssertEqual(position?.value, "1:23 of 3:34")
        XCTAssertEqual(position?.role, NSAccessibility.Role.slider.rawValue)
        let volume = element("Volume", in: list)
        XCTAssertEqual(volume?.value, "70 percent")
        XCTAssertEqual(volume?.role, NSAccessibility.Role.slider.rawValue)
        XCTAssertNotNil(element("Mute", in: list))
        XCTAssertNotNil(element("Settings", in: list))
        XCTAssertNotNil(element("Liner Notes", in: list))
        let unnamed = list.filter { $0.role == NSAccessibility.Role.button.rawValue && $0.label.isEmpty }
        XCTAssertEqual(unnamed.map(\.description), [], "buttons without a name")
    }

    func testCompactPlayerAndModes() {
        let list = elements(of: player(.compact, state: .paused, shuffling: true), height: 200)
        print("Compact player accessibility tree:\n" + list.map(\.description).joined(separator: "\n"))
        XCTAssertNotNil(element("Play", in: list), "play/pause says what it does while paused")
        XCTAssertEqual(element("Shuffle", in: list)?.value, "On")
        XCTAssertNotNil(element("Open in Spotify", in: list))
        let unnamed = list.filter { $0.role == NSAccessibility.Role.button.rawValue && $0.label.isEmpty }
        XCTAssertEqual(unnamed.map(\.description), [], "buttons without a name")
    }

    func testPositionDescription() {
        XCTAssertEqual(PlayerView.positionDescription(83, duration: 214, hasTrack: true), "1:23 of 3:34")
        XCTAssertEqual(PlayerView.positionDescription(83, duration: 5400, hasTrack: true), "0:01:23 of 1:30:00")
        // No length from Spotify: it read "1:23 of 0:00".
        XCTAssertEqual(PlayerView.positionDescription(83, duration: 0, hasTrack: true), "1:23 played")
        XCTAssertEqual(PlayerView.positionDescription(0, duration: 0, hasTrack: false), "Nothing playing")
    }

    func testMenuBarLabelSpeaksTheWholeSong() {
        let track = Track(id: "spotify:track:a", title: "A Very Long Song Title That Gets Cut",
                          artist: "Artist", album: "", artworkURL: nil, duration: 200)
        XCTAssertEqual(MenuBarLabel.spokenState(Playback(state: .playing, track: track, position: 0, volume: 50)),
                       "Playing A Very Long Song Title That Gets Cut by Artist")
        XCTAssertEqual(MenuBarLabel.spokenState(Playback(state: .paused, track: track, position: 0, volume: 50)),
                       "Paused, A Very Long Song Title That Gets Cut by Artist")
        XCTAssertEqual(MenuBarLabel.spokenState(Playback(state: .stopped, track: track, position: 0, volume: 50)), "")
        XCTAssertEqual(MenuBarLabel.spokenState(Playback(state: .playing, track: nil, position: 0, volume: 50)), "")
    }

    /// Space presses the focused control. Every control style reports its focus up the tree.
    func testFocusedControlIsReportedToThePlayer() {
        XCTAssertTrue(KeyCommand.playPause.yieldsToFocusedControl)
        for command in [KeyCommand.seekBack, .seekForward, .volumeUp, .volumeDown, .next, .shuffle, .back, .settings] {
            XCTAssertFalse(command.yieldsToFocusedControl, "\(command)")
        }

        final class Box { var focused: Bool? }
        let box = Box()
        let view = VStack {
            Color.clear.frame(width: 10, height: 10).focusOutline(Rectangle(), isFocused: false)
            Color.clear.frame(width: 10, height: 10).focusOutline(Rectangle(), isFocused: true)
            Color.clear.frame(width: 10, height: 10).focusOutline(Rectangle(), isFocused: false)
        }
        .onPreferenceChange(ControlFocusKey.self) { box.focused = $0 }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(box.focused, true)
    }
}
