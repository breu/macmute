import AppKit
import Carbon.HIToolbox
import Foundation

extension Notification.Name {
    static let bruteHotkeyRegistrationDidChange = Notification.Name(
        "Brute.hotkeyRegistrationDidChange"
    )
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

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
    case inputMonitoringPermissionRequired
    case monitorUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidShortcut:
            "Use at least one modifier, fn alone, or F13–F20 alone."
        case .eventHandlerUnavailable(let status):
            "The system hotkey handler could not start (OSStatus \(status))."
        case .shortcutUnavailable:
            "That shortcut is already in use by macOS or another app."
        case .inputMonitoringPermissionRequired:
            "Allow Brute in System Settings → Privacy & Security → Input Monitoring to use fn."
        case .monitorUnavailable:
            "The fn-key monitor could not start."
        }
    }
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onHotkeyDown: ((TimeInterval?) -> Void)?
    var onHotkeyUp: ((TimeInterval?) -> Void)?
    var onHotkeyCancelled: (() -> Void)?
    private(set) var lastRegistrationError: HotkeyRegistrationError?

    private enum Registration {
        case carbon(reference: EventHotKeyRef, id: UInt32)
        case functionKey(monitor: any FunctionKeyMonitor, id: UUID)
        case simulated
    }

    private final class CarbonCallbackContext {
        weak var manager: HotkeyManager?

        init(manager: HotkeyManager) {
            self.manager = manager
        }
    }

    /// Retains the native handles long enough to remove them on the main actor
    /// when a manager is released from another thread.
    @MainActor
    private final class SystemRegistration {
        var active: Registration?
        var handler: (reference: EventHandlerRef, context: Unmanaged<CarbonCallbackContext>)?

        func unregisterShortcut() {
            let registration = active
            active = nil
            switch registration {
            case .carbon(let reference, _):
                let status = UnregisterEventHotKey(reference)
                if status != noErr {
                    BruteLog.hotkey.error("Failed to unregister hotkey (OSStatus \(status))")
                }
            case .functionKey(let monitor, _):
                monitor.stop()
            case .simulated, nil:
                break
            }
        }

        func shutdown() {
            unregisterShortcut()
            guard let handler else { return }
            self.handler = nil
            handler.context.takeUnretainedValue().manager = nil
            let status = RemoveEventHandler(handler.reference)
            if status == noErr {
                handler.context.release()
            } else {
                // Carbon can still call the handler. Keep its disabled context alive.
                BruteLog.hotkey.error("Failed to remove hotkey event handler (OSStatus \(status))")
            }
        }
    }

    private static let hotKeySignature = OSType(0x4D4D5554) // 'MMUT'
    private static var nextHotKeyID: UInt32 = 1
    private let systemRegistration = SystemRegistration()
    private var hotkeyIsDown = false
    private var functionKeyPress = FunctionKeyPress()
    private var isRecordingShortcut = false
    private var ignorePressesBefore: TimeInterval?
    private var pressWatchdog: Task<Void, Never>?
    private var monitorHealthTask: Task<Void, Never>?
    private var registrationRetryTask: Task<Void, Never>?
    private var eventHandlerAvailable = false
    private var isShutDown = false
    private let defaults: UserDefaults
    private let retryDelay: TimeInterval
    private let input: any HotkeyInputSystem
    private let installHandlerOverride: (() -> Result<Void, HotkeyRegistrationError>)?
    private let registrationOverride: ((KeyboardShortcut) -> Result<Void, HotkeyRegistrationError>)?
    private var workspaceObservations: [NotificationObservation] = []
    private var nextRetryDelay: TimeInterval
    private static let maximumRetryDelay: TimeInterval = 60

    /// Legacy key retained deliberately: `BruteDefaults` documents why the
    /// `MacMute.` prefix stays even though the app is Brute.
    private static let defaultsKey = BruteDefaults.shortcut
    private(set) var currentShortcut: KeyboardShortcut

    init(
        defaults: UserDefaults = .standard,
        observesWake: Bool = true,
        retryDelay: TimeInterval = 5,
        input: (any HotkeyInputSystem)? = nil,
        installHandlerOverride: (() -> Result<Void, HotkeyRegistrationError>)? = nil,
        registrationOverride: ((KeyboardShortcut) -> Result<Void, HotkeyRegistrationError>)? = nil
    ) {
        self.defaults = defaults
        self.input = input ?? SystemHotkeyInput()
        let initialRetryDelay = retryDelay.isFinite && retryDelay > 0 ? retryDelay : 5
        self.retryDelay = min(initialRetryDelay, Self.maximumRetryDelay)
        nextRetryDelay = self.retryDelay
        self.installHandlerOverride = installHandlerOverride
        self.registrationOverride = registrationOverride
        let saved = Self.loadShortcut(from: defaults)
        if let saved, saved.isValid {
            currentShortcut = saved
        } else {
            currentShortcut = .default
        }

        let handlerResult = installHandler()
        if currentShortcut.isFn || handlerResult.isSuccess {
            switch registerInitialShortcut(currentShortcut) {
            case .success:
                recordRegistrationSuccess()
            case .failure(let error):
                recordRegistrationError(error)
                scheduleRegistrationRetry()
            }
        } else if case .failure(let error) = handlerResult {
            recordRegistrationError(error)
            scheduleRegistrationRetry()
        }
        if observesWake {
            observeWorkspace()
        }
    }

    deinit {
        registrationRetryTask?.cancel()
        pressWatchdog?.cancel()
        monitorHealthTask?.cancel()
        Task { @MainActor [systemRegistration] in systemRegistration.shutdown() }
    }

    /// Cancel the active press and remove native callbacks before termination.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        cancelActivePress()
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        stopMonitorHealthChecks()
        systemRegistration.shutdown()
        eventHandlerAvailable = false
        workspaceObservations.removeAll()
        onHotkeyDown = nil
        onHotkeyUp = nil
        onHotkeyCancelled = nil
    }

    var hasActiveRegistration: Bool { systemRegistration.active != nil }

    @discardableResult
    func updateShortcut(_ shortcut: KeyboardShortcut) -> Result<Void, HotkeyRegistrationError> {
        guard !isShutDown else { return .failure(.eventHandlerUnavailable(OSStatus(eventNotHandledErr))) }
        guard shortcut.isValid else { return .failure(.invalidShortcut) }
        if shortcut == currentShortcut {
            verifyFunctionKeyMonitor()
            if hasActiveRegistration {
                recordRegistrationSuccess()
                return .success(())
            }
        }
        if !shortcut.isFn, !eventHandlerAvailable {
            switch installHandler() {
            case .success:
                break
            case .failure(let error):
                recordRegistrationError(error)
                return .failure(error)
            }
        }

        switch makeRegistration(for: shortcut) {
        case .success(let replacement):
            cancelActivePress()
            unregisterShortcut()
            currentShortcut = shortcut
            activate(replacement)
            Self.saveShortcut(shortcut, to: defaults)
            recordRegistrationSuccess(registrationChanged: true)
            return .success(())
        case .failure(let error):
            recordRegistrationError(error)
            return .failure(error)
        }
    }

    private func installHandler() -> Result<Void, HotkeyRegistrationError> {
        if eventHandlerAvailable { return .success(()) }
        if let installHandlerOverride {
            let result = installHandlerOverride()
            if result.isSuccess { eventHandlerAvailable = true }
            return result
        }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let context = Unmanaged.passRetained(CarbonCallbackContext(manager: self))
        var eventHandlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard Thread.isMainThread, let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
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
                guard parameterStatus == noErr else { return OSStatus(eventNotHandledErr) }
                let context = Unmanaged<CarbonCallbackContext>.fromOpaque(userData).takeUnretainedValue()
                let isDown = GetEventKind(eventRef) == UInt32(kEventHotKeyPressed)
                let eventTime = GetEventTime(eventRef)
                let timestamp = eventTime > 0 ? eventTime : ProcessInfo.processInfo.systemUptime
                // Carbon calls the application event target on the main event loop
                // and needs a synchronous handled/not-handled answer.
                return MainActor.assumeIsolated {
                    guard let manager = context.manager,
                          case .carbon(_, let id) = manager.systemRegistration.active,
                          receivedID.id == id,
                          receivedID.signature == HotkeyManager.hotKeySignature
                    else { return OSStatus(eventNotHandledErr) }
                    manager.handleHotkeyEdge(isDown: isDown, timestamp: timestamp)
                    return noErr
                }
            },
            eventTypes.count,
            &eventTypes,
            context.toOpaque(),
            &eventHandlerRef
        )
        guard status == noErr else {
            context.release()
            return .failure(.eventHandlerUnavailable(status))
        }
        guard let eventHandlerRef else {
            context.takeUnretainedValue().manager = nil
            return .failure(.eventHandlerUnavailable(OSStatus(eventNotHandledErr)))
        }
        systemRegistration.handler = (eventHandlerRef, context)
        eventHandlerAvailable = true
        return .success(())
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
        for shortcut: KeyboardShortcut,
        promptForPermission: Bool = true
    ) -> Result<Registration, HotkeyRegistrationError> {
        if !shortcut.isFn, !eventHandlerAvailable {
            return .failure(.eventHandlerUnavailable(OSStatus(eventNotHandledErr)))
        }
        if let registrationOverride {
            return registrationOverride(shortcut).map { .simulated }
        }
        if shortcut.isFn {
            return makeFunctionKeyRegistration(promptForPermission: promptForPermission)
        }

        let numericID = Self.nextHotKeyID
        Self.nextHotKeyID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: numericID),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            return .failure(.shortcutUnavailable(status))
        }
        return .success(.carbon(reference: reference, id: numericID))
    }

    private func makeFunctionKeyRegistration(
        promptForPermission: Bool
    ) -> Result<Registration, HotkeyRegistrationError> {
        guard input.inputMonitoringAllowed(prompt: promptForPermission) else {
            return .failure(.inputMonitoringPermissionRequired)
        }
        let id = UUID()
        guard let monitor = input.monitorFunctionKey({ [weak self] event, timestamp in
            self?.handleFunctionKeyInput(event, timestamp: timestamp, registrationID: id)
        }) else {
            return .failure(.monitorUnavailable)
        }
        return .success(.functionKey(monitor: monitor, id: id))
    }

    private func activate(_ registration: Registration) {
        systemRegistration.active = registration
        if case .functionKey = registration {
            monitorHealthTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    self.verifyFunctionKeyMonitor()
                }
            }
        }
    }

    private func stopMonitorHealthChecks() {
        monitorHealthTask?.cancel()
        monitorHealthTask = nil
    }

    private func unregisterShortcut() {
        stopMonitorHealthChecks()
        systemRegistration.unregisterShortcut()
        functionKeyPress = FunctionKeyPress()
    }

    private func handleFunctionKeyInput(_ event: FunctionKeyInput, timestamp: TimeInterval, registrationID: UUID) {
        guard case .functionKey(_, let activeID) = systemRegistration.active,
              activeID == registrationID else { return }
        if case .monitorDisabled = event {
            loseFunctionKeyMonitor(
                input.inputMonitoringAllowed(prompt: false) ? .monitorUnavailable : .inputMonitoringPermissionRequired
            )
            return
        }
        guard acceptsInput(at: timestamp) else { return }
        switch functionKeyPress.consume(event) {
        case .pressed: handleHotkeyEdge(isDown: true, timestamp: timestamp)
        case .released: handleHotkeyEdge(isDown: false, timestamp: timestamp)
        case .cancelled: cancelActivePress()
        case nil: break
        }
    }

    func verifyFunctionKeyMonitor() {
        guard case .functionKey(let monitor, _) = systemRegistration.active else { return }
        if !input.inputMonitoringAllowed(prompt: false) {
            loseFunctionKeyMonitor(.inputMonitoringPermissionRequired)
        } else if !monitor.isEnabled {
            loseFunctionKeyMonitor(.monitorUnavailable)
        }
    }

    private func loseFunctionKeyMonitor(_ error: HotkeyRegistrationError) {
        cancelActivePress()
        unregisterShortcut()
        recordRegistrationError(error, registrationChanged: true)
        scheduleRegistrationRetry()
    }

    func setShortcutRecording(_ isRecording: Bool) {
        guard isRecording != isRecordingShortcut else { return }
        isRecordingShortcut = isRecording
        discardInput()
    }

    private func acceptsInput(at timestamp: TimeInterval?) -> Bool {
        guard !isShutDown, !isRecordingShortcut else { return false }
        if let timestamp, let ignorePressesBefore, timestamp < ignorePressesBefore { return false }
        return true
    }

    func handleHotkeyEdge(isDown: Bool, timestamp: TimeInterval? = nil) {
        guard acceptsInput(at: timestamp), isDown != hotkeyIsDown else { return }
        hotkeyIsDown = isDown
        if isDown {
            pressWatchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    self.verifyPressedKey()
                }
            }
            onHotkeyDown?(timestamp)
        } else {
            stopPressWatchdog()
            onHotkeyUp?(timestamp)
        }
    }

    func verifyPressedKey() {
        guard hotkeyIsDown else { return }
        verifyFunctionKeyMonitor()
        if hotkeyIsDown, !input.isPressed(currentShortcut) {
            discardInput()
        }
    }

    private func stopPressWatchdog() {
        pressWatchdog?.cancel()
        pressWatchdog = nil
    }

    private func observeWorkspace() {
        let names = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservations = names.map { name in
            NotificationObservation(center: center, name: name, queue: .main) { [weak self] _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didWakeNotification {
                        self?.handleWake()
                    } else {
                        self?.discardInput()
                    }
                }
            }
        }
    }

    func handleWake() {
        guard !isShutDown else { return }
        discardInput()
        guard currentShortcut.isFn else { return }
        let wasActive = hasActiveRegistration
        unregisterShortcut()
        switch makeRegistration(for: currentShortcut, promptForPermission: false) {
        case .success(let registration):
            activate(registration)
            recordRegistrationSuccess(registrationChanged: !wasActive)
        case .failure(let error):
            recordRegistrationError(error, registrationChanged: wasActive)
            scheduleRegistrationRetry()
        }
    }

    private func discardInput() {
        ignorePressesBefore = ProcessInfo.processInfo.systemUptime
        functionKeyPress = FunctionKeyPress()
        cancelActivePress()
    }

    private func cancelActivePress() {
        stopPressWatchdog()
        guard hotkeyIsDown else { return }
        hotkeyIsDown = false
        onHotkeyCancelled?()
    }

    private func recordRegistrationError(_ error: HotkeyRegistrationError, registrationChanged: Bool = false) {
        // Repeating the same failure is noise in Console and a pointless menu repaint;
        // the status line already shows it.
        let errorChanged = error != lastRegistrationError
        if errorChanged {
            lastRegistrationError = error
            BruteLog.hotkey.error("Hotkey registration failed: \(error.localizedDescription, privacy: .public)")
        }
        if errorChanged || registrationChanged {
            NotificationCenter.default.post(name: .bruteHotkeyRegistrationDidChange, object: self)
        }
    }

    private func recordRegistrationSuccess(registrationChanged: Bool = false) {
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        nextRetryDelay = retryDelay
        let errorCleared = lastRegistrationError != nil
        lastRegistrationError = nil
        if errorCleared || registrationChanged {
            NotificationCenter.default.post(name: .bruteHotkeyRegistrationDidChange, object: self)
        }
    }

    private func scheduleRegistrationRetry() {
        guard !isShutDown, !hasActiveRegistration, registrationRetryTask == nil else { return }
        let delay = nextRetryDelay
        nextRetryDelay = min(delay * 2, Self.maximumRetryDelay)
        registrationRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.registrationRetryTask = nil
            self.retryRegistrationNow()
        }
    }

    func retryRegistrationNow() {
        guard !isShutDown, !hasActiveRegistration else { return }
        if !currentShortcut.isFn {
            switch installHandler() {
            case .success:
                break
            case .failure(let error):
                recordRegistrationError(error)
                scheduleRegistrationRetry()
                return
            }
        }
        switch makeRegistration(for: currentShortcut, promptForPermission: false) {
        case .success(let registration):
            activate(registration)
            recordRegistrationSuccess(registrationChanged: true)
        case .failure(let error):
            recordRegistrationError(error)
            scheduleRegistrationRetry()
        }
    }

    private static func loadShortcut(from defaults: UserDefaults) -> KeyboardShortcut? {
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

    private static func saveShortcut(_ shortcut: KeyboardShortcut, to defaults: UserDefaults) {
        defaults.set(
            ["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers)],
            forKey: defaultsKey
        )
    }
}
