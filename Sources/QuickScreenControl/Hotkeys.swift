import Carbon.HIToolbox
import Foundation

/// 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）
enum Hotkeys {
    private static var refs: [EventHotKeyRef] = []
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    /// 注册一个快捷键；id 需唯一
    static func register(id: UInt32, keyCode: Int, modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey), action: @escaping () -> Void) {
        installIfNeeded()
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x51534331), id: id)  // 'QSC1'
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    static func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { Hotkeys.handlers[hkID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
