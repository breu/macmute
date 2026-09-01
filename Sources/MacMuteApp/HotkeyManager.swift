import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct KeyboardShortcut: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(cmdKey | optionKey)
    )
    static let fn = KeyboardShortcut(keyCode: UInt32(kVK_Function), modifiers: 0)

    var isFn: Bool { keyCode == UInt32(kVK_Function) }

    static let standaloneFunctionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20)
    ]

    private static let allowedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    var isValid: Bool {
        guard keyCode <= UInt32(UInt16.max), modifiers & ~Self.allowedModifiers == 0 else { return false }
        if isFn { return modifiers == 0 }
        return modifiers != 0 || Self.standaloneFunctionKeyCodes.contains(keyCode)
    }

    var displayString: String {
        if isFn { return "fn" }
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        parts += Self.keyName(for: keyCode)
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

enum HotkeyRegistrationError: LocalizedError, Equatable {
    case invalidShortcut
    case eventHandlerUnavailable(OSStatus)
    case shortcutUnavailable(OSStatus)
    case accessibilityPermissionRequired
    case monitorUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidShortcut:
            "Use at least one modifier, fn alone, or F13–F20 alone."
        case .eventHandlerUnavailable(let status):
            "The system hotkey handler could not start (OSStatus \(status))."
        case .shortcutUnavailable:
            "That shortcut is already in use by macOS or another app."
        case .accessibilityPermissionRequired:
            "Grant Accessibility access, then choose fn again."
        case .monitorUnavailable:
            "The fn-key monitor could not start."
        }
    }
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    var onHotkeyCancelled: (() -> Void)?
    var onRegistrationError: ((HotkeyRegistrationError) -> Void)?
    private(set) var lastRegistrationError: HotkeyRegistrationError?

    private enum Registration {
        case carbon(reference: EventHotKeyRef, id: UInt32)
        case functionKey(global: Any, local: Any)
    }

    private var activeRegistration: Registration?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeySignature = OSType(0x4D4D5554) // 'MMUT'
    private var nextHotKeyID: UInt32 = 1
    private var activeCarbonHotKeyID: UInt32?
    private var fnKeyIsDown = false
    private var hotkeyIsDown = false

    private static let defaultsKey = "MacMute.shortcut"
    private(set) var currentShortcut: KeyboardShortcut

    private init() {
        let saved = Self.loadShortcut()
        if let saved, saved.isValid {
            currentShortcut = saved
        } else {
            currentShortcut = .default
        }

        switch installHandler() {
        case .success:
            switch registerInitialShortcut(currentShortcut) {
            case .success:
                break
            case .failure(let initialError):
                if currentShortcut != .default {
                    currentShortcut = .default
                    switch registerInitialShortcut(.default) {
                    case .success:
                        Self.saveShortcut(.default)
                    case .failure(let fallbackError):
                        recordRegistrationError(fallbackError)
                    }
                } else {
                    recordRegistrationError(initialError)
                }
            }
        case .failure(let error):
            recordRegistrationError(error)
        }
        observeWake()
    }

    @discardableResult
    func updateShortcut(_ shortcut: KeyboardShortcut) -> Result<Void, HotkeyRegistrationError> {
        guard shortcut.isValid else { return .failure(.invalidShortcut) }
        guard shortcut != currentShortcut else { return .success(()) }

        switch makeRegistration(for: shortcut) {
        case .success(let replacement):
            if let activeRegistration {
                cancelActivePress()
                unregister(activeRegistration)
            }
            activate(replacement)
            currentShortcut = shortcut
            Self.saveShortcut(shortcut)
            lastRegistrationError = nil
            return .success(())
        case .failure(let error):
            recordRegistrationError(error)
            return .failure(error)
        }
    }

    private func installHandler() -> Result<Void, HotkeyRegistrationError> {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var receivedID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    eventRef,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard parameterStatus == noErr,
                      receivedID.id == manager.activeCarbonHotKeyID,
                      receivedID.signature == manager.hotKeySignature
                else { return OSStatus(eventNotHandledErr) }

                MainActor.assumeIsolated {
                    if GetEventKind(eventRef) == UInt32(kEventHotKeyPressed) {
                        guard !manager.hotkeyIsDown else { return }
                        manager.hotkeyIsDown = true
                        manager.onHotkeyDown?()
                    } else {
                        guard manager.hotkeyIsDown else { return }
                        manager.hotkeyIsDown = false
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
        return status == noErr ? .success(()) : .failure(.eventHandlerUnavailable(status))
    }

    private func registerInitialShortcut(
        _ shortcut: KeyboardShortcut
    ) -> Result<Void, HotkeyRegistrationError> {
        switch makeRegistration(for: shortcut) {
        case .success(let registration):
            activate(registration)
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private func makeRegistration(
        for shortcut: KeyboardShortcut
    ) -> Result<Registration, HotkeyRegistrationError> {
        if shortcut.isFn {
            return makeFunctionKeyRegistration()
        }

        let numericID = nextHotKeyID
        nextHotKeyID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: hotKeySignature, id: numericID),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            return .failure(.shortcutUnavailable(status))
        }
        return .success(.carbon(reference: reference, id: numericID))
    }

    private func makeFunctionKeyRegistration() -> Result<Registration, HotkeyRegistrationError> {
        guard Self.requestAccessibilityPermissionIfNeeded() else {
            return .failure(.accessibilityPermissionRequired)
        }
        fnKeyIsDown = false
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { event in
            Task { @MainActor in
                HotkeyManager.shared.handleFnFlagsChanged(event)
            }
        }) else {
            return .failure(.monitorUnavailable)
        }
        guard let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated {
                HotkeyManager.shared.handleFnFlagsChanged(event)
            }
            return event
        }) else {
            NSEvent.removeMonitor(global)
            return .failure(.monitorUnavailable)
        }
        return .success(.functionKey(global: global, local: local))
    }

    private func unregister(_ registration: Registration) {
        switch registration {
        case .carbon(let reference, _):
            let status = UnregisterEventHotKey(reference)
            if status != noErr {
                NSLog("MacMute: failed to unregister hotkey (OSStatus %d)", status)
            }
        case .functionKey(let global, let local):
            NSEvent.removeMonitor(global)
            NSEvent.removeMonitor(local)
        }
    }

    private func activate(_ registration: Registration) {
        activeRegistration = registration
        switch registration {
        case .carbon(_, let id):
            activeCarbonHotKeyID = id
        case .functionKey:
            activeCarbonHotKeyID = nil
        }
    }

    private func handleFnFlagsChanged(_ event: NSEvent) {
        let isDown = event.modifierFlags.contains(.function)
        guard isDown != fnKeyIsDown else { return }
        fnKeyIsDown = isDown
        hotkeyIsDown = isDown
        if isDown {
            onHotkeyDown?()
        } else {
            onHotkeyUp?()
        }
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                HotkeyManager.shared.reinstallFunctionKeyMonitorAfterWake()
            }
        }
    }

    private func reinstallFunctionKeyMonitorAfterWake() {
        guard currentShortcut.isFn else { return }
        if let activeRegistration {
            cancelActivePress()
            unregister(activeRegistration)
            self.activeRegistration = nil
            activeCarbonHotKeyID = nil
        }
        switch makeFunctionKeyRegistration() {
        case .success(let registration):
            activate(registration)
            lastRegistrationError = nil
        case .failure(let error):
            recordRegistrationError(error)
        }
    }

    private func cancelActivePress() {
        guard hotkeyIsDown || fnKeyIsDown else { return }
        hotkeyIsDown = false
        fnKeyIsDown = false
        onHotkeyCancelled?()
    }

    private func recordRegistrationError(_ error: HotkeyRegistrationError) {
        lastRegistrationError = error
        NSLog("MacMute: %@", error.localizedDescription)
        onRegistrationError?(error)
    }

    static func requestAccessibilityPermissionIfNeeded() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    private static func loadShortcut() -> KeyboardShortcut? {
        let defaults = UserDefaults.standard
        guard let dict = defaults.dictionary(forKey: defaultsKey) else { return nil }
        return decodeShortcut(from: dict)
    }

    static func decodeShortcut(from dictionary: [String: Any]) -> KeyboardShortcut? {
        guard let keyCode = exactUInt32(dictionary["keyCode"]),
              let modifiers = exactUInt32(dictionary["modifiers"])
        else { return nil }
        let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        return shortcut.isValid ? shortcut : nil
    }

    private static func exactUInt32(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let value = value as? Int { return UInt32(exactly: value) }
        if let value = value as? NSNumber { return UInt32(value.stringValue) }
        return nil
    }

    private static func saveShortcut(_ shortcut: KeyboardShortcut) {
        UserDefaults.standard.set(
            ["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers)],
            forKey: defaultsKey
        )
    }
}
