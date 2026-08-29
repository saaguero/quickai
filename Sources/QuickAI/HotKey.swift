import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey: no accessibility permission needed.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (@MainActor () -> Void)?
    private var eventHandlerInstalled = false

    private init() {}

    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, handler: @escaping @MainActor () -> Void) {
        unregister()
        self.handler = handler
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x514B_4149), id: 1) // 'QKAI'
        RegisterEventHotKey(keyCode, modifiers.carbonFlags, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in center.handler?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        eventHandlerInstalled = true
    }
}

extension NSEvent.ModifierFlags {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
