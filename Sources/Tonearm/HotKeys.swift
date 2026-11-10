import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts through Carbon's RegisterEventHotKey. Unlike a global key monitor,
/// this needs no Accessibility permission. Handlers run on the main thread.
final class HotKeys {
    enum Action: UInt32, CaseIterable {
        case playPause = 1
        case next
        case previous

        var keyCode: Int {
            switch self {
            case .playPause: return kVK_Space
            case .next: return kVK_RightArrow
            case .previous: return kVK_LeftArrow
            }
        }

        /// Shown in settings.
        var keys: String {
            switch self {
            case .playPause: return "⌃⌥Space"
            case .next: return "⌃⌥→"
            case .previous: return "⌃⌥←"
            }
        }

        var title: String {
            switch self {
            case .playPause: return "Play or pause"
            case .next: return "Next song"
            case .previous: return "Previous song"
            }
        }
    }

    static let modifiers = UInt32(controlKey | optionKey)
    /// 'TnAm'
    private static let signature: OSType = 0x546E_416D

    private let perform: (Action) -> Void
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// True when at least one shortcut is registered.
    private(set) var isEnabled = false

    init(perform: @escaping (Action) -> Void) {
        self.perform = perform
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Registers or unregisters all shortcuts. Call on the main thread.
    func setEnabled(_ on: Bool) {
        if on { register() } else { unregister() }
    }

    private func register() {
        guard refs.isEmpty else { return }
        installHandler()
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(UInt32(action.keyCode), Self.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                // Another app may own the same keys.
                NSLog("Tonearm: could not register %@ (%d)", action.keys, status)
            }
        }
        isEnabled = !refs.isEmpty
    }

    private func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        isEnabled = false
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            return hotKeys.handle(id) ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, me, &handler)
        if status != noErr { NSLog("Tonearm: could not install hot key handler (%d)", status) }
    }

    private func handle(_ id: EventHotKeyID) -> Bool {
        guard id.signature == Self.signature, let action = Action(rawValue: id.id) else { return false }
        let perform = perform
        DispatchQueue.main.async { perform(action) }
        return true
    }
}
