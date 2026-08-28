import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct KeyboardShortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(cmdKey | optionKey)
    )

    /// Sentinel representing the standalone fn key, which has no Carbon modifier mask of its own.
    static let fn = KeyboardShortcut(keyCode: UInt32(kVK_Function), modifiers: 0)

    var isFn: Bool { keyCode == UInt32(kVK_Function) }

    /// F13–F20 have no default system binding and aren't used for typing, so unlike
    /// ordinary letter/number keys they're safe to bind standalone (no modifier required).
    static let standaloneFunctionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20)
    ]

    var displayString: String {
        if isFn { return "fn" }
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        parts += KeyboardShortcut.keyName(for: keyCode)
        return parts
    }

    private static func keyName(for keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_Space): "Space",
            UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
            UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
            UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20"
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}

final class HotkeyManager {

    static let shared = HotkeyManager()

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x4D4D5554), id: 1) // 'MMUT'

    private var fnGlobalMonitor: Any?
    private var fnLocalMonitor: Any?
    private var fnKeyIsDown = false

    private static let defaultsKey = "MacMute.shortcut"

    private(set) var currentShortcut: KeyboardShortcut

    private init() {
        currentShortcut = Self.loadShortcut() ?? .default
        installHandler()
        register(shortcut: currentShortcut)
        observeWake()
    }

    /// The global NSEvent monitor backing the standalone fn key can silently stop
    /// delivering events after the system sleeps, so it's torn down and reinstalled
    /// on wake. Carbon's RegisterEventHotKey path isn't affected by sleep, so
    /// non-fn shortcuts are left alone.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.currentShortcut.isFn else { return }
            self.unregisterFnMonitor()
            self.registerFnMonitor()
        }
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        unregister()
        currentShortcut = shortcut
        Self.saveShortcut(shortcut)
        register(shortcut: shortcut)
    }

    private func installHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var receivedID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard receivedID.id == manager.hotKeyID.id else { return noErr }
                let isDown = GetEventKind(eventRef) == UInt32(kEventHotKeyPressed)
                DispatchQueue.main.async {
                    if isDown {
                        manager.onHotkeyDown?()
                    } else {
                        manager.onHotkeyUp?()
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &eventHandlerRef
        )
    }

    private func register(shortcut: KeyboardShortcut) {
        if shortcut.isFn {
            registerFnMonitor()
            return
        }
        RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        unregisterFnMonitor()
    }

    // MARK: - Standalone fn key

    /// fn has no Carbon modifier mask, so it can't go through RegisterEventHotKey.
    /// Instead we watch flagsChanged globally (requires Accessibility permission) and
    /// locally (so it also fires while MacMute's own windows are focused).
    private func registerFnMonitor() {
        Self.requestAccessibilityPermissionIfNeeded()
        fnKeyIsDown = false
        fnGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFnFlagsChanged(event)
        }
        fnLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFnFlagsChanged(event)
            return event
        }
    }

    private func unregisterFnMonitor() {
        if let fnGlobalMonitor { NSEvent.removeMonitor(fnGlobalMonitor) }
        if let fnLocalMonitor { NSEvent.removeMonitor(fnLocalMonitor) }
        fnGlobalMonitor = nil
        fnLocalMonitor = nil
    }

    private func handleFnFlagsChanged(_ event: NSEvent) {
        let isDown = event.modifierFlags.contains(.function)
        guard isDown != fnKeyIsDown else { return }
        fnKeyIsDown = isDown
        if isDown {
            onHotkeyDown?()
        } else {
            onHotkeyUp?()
        }
    }

    static func requestAccessibilityPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func loadShortcut() -> KeyboardShortcut? {
        let defaults = UserDefaults.standard
        guard let dict = defaults.dictionary(forKey: defaultsKey),
              let keyCode = dict["keyCode"] as? UInt32 ?? (dict["keyCode"] as? Int).map(UInt32.init),
              let modifiers = dict["modifiers"] as? UInt32 ?? (dict["modifiers"] as? Int).map(UInt32.init)
        else { return nil }
        return KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private static func saveShortcut(_ shortcut: KeyboardShortcut) {
        UserDefaults.standard.set(
            ["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers)],
            forKey: defaultsKey
        )
    }
}
