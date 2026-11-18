import Carbon.HIToolbox
import GiveMyRamBackCore

/// System-wide shortcut via Carbon `RegisterEventHotKey`. Unlike a global `NSEvent` key monitor
/// it needs no Accessibility / Input Monitoring permission, so it keeps working as an
/// emergency «unfreeze everything» even when nothing else has been granted.
@MainActor
final class GlobalHotKey {
    static let displayString = "⌃⌥⌘U"
    private static let keyCode = UInt32(kVK_ANSI_U)
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let signature: OSType = 0x474D_5242 // 'GMRB'

    // Carbon calls back through a C function pointer; route it to the single instance.
    nonisolated(unsafe) private static var handlerAction: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var isRegistered: Bool { hotKeyRef != nil }

    func register(action: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }
        Self.handlerAction = action

        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ -> OSStatus in
                    DispatchQueue.main.async {
                        GlobalHotKey.handlerAction?()
                    }
                    return noErr
                },
                1,
                &spec,
                nil,
                &handlerRef
            )
            if status != noErr {
                Log.ui.error("InstallEventHandler failed: \(status, privacy: .public)")
                return
            }
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            Log.ui.info("Hotkey \(Self.displayString, privacy: .public) registered")
        } else {
            hotKeyRef = nil
            Log.ui.error("RegisterEventHotKey failed (\(status, privacy: .public)); shortcut taken by another app?")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            Log.ui.info("Hotkey unregistered")
        }
    }
}
