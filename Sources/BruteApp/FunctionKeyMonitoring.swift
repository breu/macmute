import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum FunctionKeyInput: Sendable {
    case flagsChanged(isFunctionKey: Bool, functionIsDown: Bool, chordModifiersAreDown: Bool)
    case otherKeyDown
    case monitorDisabled
}

/// A standalone Fn gesture ends only if no other key joined it.
struct FunctionKeyPress {
    enum Edge {
        case pressed
        case released
        case cancelled
    }

    private enum State { case idle, pressed, chord }
    private var state = State.idle

    mutating func consume(_ input: FunctionKeyInput) -> Edge? {
        switch input {
        case .flagsChanged(isFunctionKey: true, functionIsDown: true, let chordModifiersAreDown):
            guard state == .idle else { return nil }
            if chordModifiersAreDown {
                state = .chord
                return nil
            }
            state = .pressed
            return .pressed
        case .flagsChanged(isFunctionKey: true, functionIsDown: false, _):
            let wasPressed = state == .pressed
            state = .idle
            return wasPressed ? .released : nil
        case .flagsChanged(isFunctionKey: false, let functionIsDown, _):
            let wasPressed = state == .pressed
            state = functionIsDown ? .chord : .idle
            return wasPressed ? .cancelled : nil
        case .otherKeyDown:
            guard state == .pressed else { return nil }
            state = .chord
            return .cancelled
        case .monitorDisabled:
            let wasPressed = state == .pressed
            state = .idle
            return wasPressed ? .cancelled : nil
        }
    }
}

@MainActor
protocol FunctionKeyMonitor: AnyObject {
    var isEnabled: Bool { get }
    func stop()
}

@MainActor
protocol HotkeyInputSystem {
    func inputMonitoringAllowed(prompt: Bool) -> Bool
    func monitorFunctionKey(
        _ handle: @escaping @MainActor (FunctionKeyInput, TimeInterval) -> Void
    ) -> (any FunctionKeyMonitor)?
    func isPressed(_ shortcut: KeyboardShortcut) -> Bool
}

@MainActor
struct SystemHotkeyInput: HotkeyInputSystem {
    func inputMonitoringAllowed(prompt: Bool) -> Bool {
        prompt ? CGRequestListenEventAccess() : CGPreflightListenEventAccess()
    }

    func monitorFunctionKey(
        _ handle: @escaping @MainActor (FunctionKeyInput, TimeInterval) -> Void
    ) -> (any FunctionKeyMonitor)? {
        SessionFunctionKeyMonitor(handle: handle)
    }

    func isPressed(_ shortcut: KeyboardShortcut) -> Bool {
        if shortcut.isFn {
            return CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
        }
        return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(shortcut.keyCode))
    }
}

/// A passive session tap observes Fn whether Brute or another app has focus.
/// Regular key-down events supply only the fact that a chord was used.
@MainActor
private final class SessionFunctionKeyMonitor: FunctionKeyMonitor {
    private final class Context {
        let handle: @MainActor (FunctionKeyInput, TimeInterval) -> Void

        init(handle: @escaping @MainActor (FunctionKeyInput, TimeInterval) -> Void) {
            self.handle = handle
        }
    }

    private let context: Context
    private let port: CFMachPort
    private let source: CFRunLoopSource
    private var stopped = false

    init?(handle: @escaping @MainActor (FunctionKeyInput, TimeInterval) -> Void) {
        let context = Context(handle: handle)
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if Thread.isMainThread, let userInfo {
                    let input: FunctionKeyInput
                    switch type {
                    case .flagsChanged:
                        let flags = event.flags
                        input = .flagsChanged(
                            isFunctionKey: event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Function),
                            functionIsDown: flags.contains(.maskSecondaryFn),
                            chordModifiersAreDown: !flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
                        )
                    case .keyDown:
                        input = .otherKeyDown
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        input = .monitorDisabled
                    default:
                        return Unmanaged.passUnretained(event)
                    }
                    let timestamp: TimeInterval
                    if case .monitorDisabled = input {
                        timestamp = 0
                    } else {
                        let eventTime = event.timestamp
                        timestamp = eventTime > 0
                            ? TimeInterval(eventTime) / 1_000_000_000
                            : ProcessInfo.processInfo.systemUptime
                    }
                    let handle = Unmanaged<Context>.fromOpaque(userInfo).takeUnretainedValue().handle
                    // Keep CoreAudio work out of the event-tap callback. Every
                    // edge uses this same serial queue and preserves tap order.
                    DispatchQueue.main.async {
                        handle(input, timestamp)
                    }
                }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return nil }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        self.context = context
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    var isEnabled: Bool { !stopped && CGEvent.tapIsEnabled(tap: port) }

    func stop() {
        guard !stopped else { return }
        stopped = true
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(port)
    }
}
