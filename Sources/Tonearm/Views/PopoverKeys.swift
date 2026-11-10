import AppKit

/// Keyboard shortcuts while the popover is open.
enum KeyCommand: Equatable {
    case playPause
    case seekBack, seekForward
    case previous, next
    case volumeUp, volumeDown
    case shuffle, repeating
    case settings
    /// Escape: leaves settings. Outside settings the key goes on and closes the window.
    case back
    case quit

    var repeats: Bool {
        switch self {
        case .seekBack, .seekForward, .volumeUp, .volumeDown: return true
        default: return false
        }
    }

    /// Seconds per arrow press.
    static let seekStep = 10.0
    /// Volume points per arrow press.
    static let volumeStep = 10

    /// Maps a key press to a command. Letters match by character, or by key position when
    /// the layout types something else there (Cyrillic, for example). Pure, for tests.
    static func from(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> KeyCommand? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        let char = characters?.lowercased() ?? ""
        let asciiChar = char.unicodeScalars.allSatisfy(\.isASCII) && !char.isEmpty
        func letter(_ l: String, _ code: UInt16) -> Bool {
            asciiChar ? char == l : keyCode == code
        }

        switch mods {
        case []:
            switch keyCode {
            case 49: return .playPause
            case 123: return .seekBack
            case 124: return .seekForward
            case 126: return .volumeUp
            case 125: return .volumeDown
            case 53: return .back
            default: break
            }
            if letter("s", 1) { return .shuffle }
            if letter("r", 15) { return .repeating }
        case [.command]:
            switch keyCode {
            case 123: return .previous
            case 124: return .next
            default: break
            }
            if letter(",", 43) { return .settings }
            if letter("q", 12) { return .quit }
        default:
            break
        }
        return nil
    }

    /// Shown in settings, in this order. Keys are separated by spaces, one keycap each.
    /// ⌘Q is left out: the Quit row in settings shows it.
    static let help: [(keys: String, action: String)] = [
        ("Space", "Play or pause"),
        ("← →", "Seek 10 s"),
        ("⌘← ⌘→", "Previous, next"),
        ("↑ ↓", "Volume"),
        ("S", "Shuffle"),
        ("R", "Repeat"),
        ("⌘,", "Settings"),
    ]
}

/// Local key monitor, on only while the popover is open.
@MainActor
final class PopoverKeys {
    private var monitor: Any?

    /// `handle` returns true when it used the key, which then goes no further.
    func start(_ handle: @escaping @MainActor (KeyCommand) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Keys typed in the welcome window are not for the player.
            if event.window?.identifier == Onboarding.windowID { return event }
            guard let command = KeyCommand.from(keyCode: event.keyCode,
                                                characters: event.charactersIgnoringModifiers,
                                                modifiers: event.modifierFlags)
            else { return event }
            // Holding a key repeats seeking and volume, not toggles.
            if event.isARepeat && !command.repeats { return nil }
            // Local monitors run on the main thread.
            let used = MainActor.assumeIsolated { handle(command) }
            return used ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
