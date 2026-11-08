import Carbon
import Foundation

/// A system-wide shortcut via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var registry: [UInt32: HotKey] = [:]
    private static var nextId: UInt32 = 1
    private let id: UInt32

    /// Default: ⌃⌥P
    init?(keyCode: UInt32 = UInt32(kVK_ANSI_P), modifiers: UInt32 = UInt32(controlKey | optionKey), action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextId
        HotKey.nextId += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKey.registry[hk.id]?.action()
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else { NSLog("T3 Mini: InstallEventHandler failed (%d)", status); return nil }
        let hkID = EventHotKeyID(signature: OSType(0x5433_4D4E), id: id)  // 'T3MN'
        let rc = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard rc == noErr else { NSLog("T3 Mini: RegisterEventHotKey failed (%d)", rc); return nil }
        HotKey.registry[id] = self
        NSLog("T3 Mini: global shortcut registered")
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.registry[id] = nil
    }
}
