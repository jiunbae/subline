import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon (no Accessibility permission required).
@MainActor
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private static var shared: HotKeys?

    init() {
        HotKeys.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            MainActor.assumeIsolated { HotKeys.shared?.handlers[id.id]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Registers ⌃⌥⌘ + key.
    func register(keyCode: Int, _ action: @escaping () -> Void) {
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4E504C59), id: id) // 'NPLY'
        let mods = UInt32(controlKey | optionKey | cmdKey)
        if RegisterEventHotKey(UInt32(keyCode), mods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }
}
