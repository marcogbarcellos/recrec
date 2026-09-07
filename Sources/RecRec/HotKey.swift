import Carbon.HIToolbox
import Foundation
import os

/// Global ⌃⌥⌘R hotkey through Carbon; works without the Accessibility permission.
final class HotKey {
    static let displayString = "⌃⌥⌘R"

    /// False when another app already owns the shortcut; the menu then shows a note instead of the key.
    private(set) var isRegistered = false
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private let log = Logger(subsystem: "com.barsmike.RecRec", category: "hotkey")

    init(handler: @escaping () -> Void) {
        self.handler = handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.handler() }
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x5252_4543), id: 1) // 'RREC'
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = status == noErr && hotKeyRef != nil
        if !isRegistered {
            log.warning("could not register \(Self.displayString, privacy: .public) (OSStatus \(status)); another app probably owns it")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
