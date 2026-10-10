import Carbon.HIToolbox

/// System-wide shortcut via Carbon `RegisterEventHotKey`.
/// Needs no Accessibility permission and does not intercept other keys.
/// Reports both press and release, so callers can tell a tap from a hold.
@MainActor
final class HotKey {
    private struct Handlers {
        let onPress: () -> Void
        let onRelease: () -> Void
    }

    private static var handlers: [UInt32: Handlers] = [:]
    private static var handlerInstalled = false
    private static let signature: OSType = 0x4255_4652 // "BUFR"

    private var ref: EventHotKeyRef?
    private let id: UInt32
    /// Registration fails when another app already owns the same shortcut.
    private(set) var isRegistered = false

    /// `keyCode` is a `kVK_*` constant, `modifiers` a mask of `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    init(keyCode: Int, modifiers: Int, id: UInt32,
         onPress: @escaping () -> Void, onRelease: @escaping () -> Void = {}) {
        self.id = id
        Self.handlers[id] = Handlers(onPress: onPress, onRelease: onRelease)
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr
        if !isRegistered {
            Log.info("failed to register hotkey \(id), status \(status)")
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, specs.count, &specs, nil, nil)
    }

    fileprivate static func dispatch(_ id: UInt32, pressed: Bool) {
        guard let h = handlers[id] else { return }
        pressed ? h.onPress() : h.onRelease()
    }
}

/// Carbon needs a plain C function, so it lives outside the actor-isolated class.
private func hotKeyEventHandler(_ call: EventHandlerCallRef?, _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    let id = hotKeyID.id
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    Task { @MainActor in HotKey.dispatch(id, pressed: pressed) }
    return noErr
}
