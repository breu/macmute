import Carbon.HIToolbox
import Foundation
import XCTest
@testable import BruteApp

@MainActor
final class HotkeyManagerTests: XCTestCase {
    func testShortcutValidationRejectsUnmodifiedTypingKeys() {
        XCTAssertFalse(KeyboardShortcut(keyCode: 0, modifiers: 0).isValid)
        XCTAssertTrue(KeyboardShortcut.default.isValid)
        XCTAssertTrue(KeyboardShortcut.fn.isValid)
        XCTAssertTrue(
            KeyboardShortcut(
                keyCode: KeyboardShortcut.standaloneFunctionKeyCodes.first!,
                modifiers: 0
            ).isValid
        )
    }

    func testShortcutDecodingRejectsMalformedPersistedIntegersWithoutTrapping() {
        XCTAssertNil(HotkeyManager.decodeShortcut(from: ["keyCode": -1, "modifiers": 0]))
        XCTAssertNil(
            HotkeyManager.decodeShortcut(
                from: ["keyCode": Int(UInt16.max) + 1, "modifiers": Int(cmdKey)]
            )
        )
        XCTAssertNil(
            HotkeyManager.decodeShortcut(
                from: ["keyCode": Int(kVK_ANSI_M), "modifiers": Int(UInt32.max)]
            )
        )
        XCTAssertEqual(
            HotkeyManager.decodeShortcut(
                from: ["keyCode": Int(kVK_ANSI_M), "modifiers": Int(cmdKey | optionKey)]
            ),
            .default
        )
    }

    func testHotkeyHandlerFailureRetriesBeforeReportingActive() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var handlerAvailable = false
        let manager = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            retryDelay: 3_600,
            installHandlerOverride: {
                handlerAvailable ? .success(()) : .failure(.eventHandlerUnavailable(-1))
            },
            registrationOverride: { _ in .success(()) }
        )

        XCTAssertFalse(manager.hasActiveRegistration)
        XCTAssertEqual(manager.lastRegistrationError, .eventHandlerUnavailable(-1))

        handlerAvailable = true
        manager.retryRegistrationNow()

        XCTAssertTrue(manager.hasActiveRegistration)
        XCTAssertNil(manager.lastRegistrationError)
    }

    func testUnavailableSavedFnShortcutIsPreservedAndRetried() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["keyCode": Int(KeyboardShortcut.fn.keyCode), "modifiers": 0],
            forKey: "MacMute.shortcut"
        )
        var registrationAvailable = false
        let manager = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            retryDelay: 3_600,
            installHandlerOverride: { .success(()) },
            registrationOverride: { _ in
                registrationAvailable ? .success(()) : .failure(.inputMonitoringPermissionRequired)
            }
        )

        XCTAssertEqual(manager.currentShortcut, .fn)
        XCTAssertFalse(manager.hasActiveRegistration)
        XCTAssertEqual(
            HotkeyManager.decodeShortcut(from: defaults.dictionary(forKey: "MacMute.shortcut")!),
            .fn
        )

        registrationAvailable = true
        manager.retryRegistrationNow()

        XCTAssertEqual(manager.currentShortcut, .fn)
        XCTAssertTrue(manager.hasActiveRegistration)
        XCTAssertNil(manager.lastRegistrationError)
    }

    func testSwitchingFromFnRetriesPreviouslyUnavailableCarbonHandler() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["keyCode": Int(KeyboardShortcut.fn.keyCode), "modifiers": 0],
            forKey: "MacMute.shortcut"
        )
        var handlerAvailable = false
        let manager = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            installHandlerOverride: {
                handlerAvailable ? .success(()) : .failure(.eventHandlerUnavailable(-2))
            },
            registrationOverride: { _ in .success(()) }
        )
        XCTAssertTrue(manager.hasActiveRegistration)

        handlerAvailable = true
        XCTAssertNoThrow(try manager.updateShortcut(.default).get())
        XCTAssertEqual(manager.currentShortcut, .default)
        XCTAssertTrue(manager.hasActiveRegistration)
        XCTAssertNil(manager.lastRegistrationError)
    }

    func testCarbonPressIsCancelledOnWakeAndNextPressIsAccepted() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            installHandlerOverride: { .success(()) },
            registrationOverride: { _ in .success(()) }
        )
        var downs = 0
        var ups = 0
        var cancellations = 0
        manager.onHotkeyDown = { _ in downs += 1 }
        manager.onHotkeyUp = { _ in ups += 1 }
        manager.onHotkeyCancelled = { cancellations += 1 }

        manager.handleHotkeyEdge(isDown: true)
        manager.handleWake()
        manager.handleHotkeyEdge(isDown: true)
        manager.handleHotkeyEdge(isDown: false)

        XCTAssertEqual(downs, 2)
        XCTAssertEqual(ups, 1)
        XCTAssertEqual(cancellations, 1)
    }

    func testHotkeyManagerShutdownClearsRegistration() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            installHandlerOverride: { .success(()) },
            registrationOverride: { _ in .success(()) }
        )
        XCTAssertTrue(manager.hasActiveRegistration)

        manager.shutdown()

        XCTAssertFalse(manager.hasActiveRegistration)
    }

    func testFunctionKeyPermissionRevocationCancelsPressAndAllowsRecovery() throws {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["keyCode": Int(KeyboardShortcut.fn.keyCode), "modifiers": 0], forKey: BruteDefaults.shortcut)
        let input = FakeHotkeyInput()
        let manager = HotkeyManager(
            defaults: defaults, observesWake: false, input: input, installHandlerOverride: { .success(()) }
        )
        defer { manager.shutdown() }
        var edges: [String] = []
        manager.onHotkeyDown = { _ in edges.append("down") }
        manager.onHotkeyUp = { _ in edges.append("up") }
        manager.onHotkeyCancelled = { edges.append("cancel") }

        let originalMonitor = try XCTUnwrap(input.monitors.last)
        originalMonitor.functionEdge(isDown: true)
        input.hasPermission = false
        manager.verifyFunctionKeyMonitor()

        XCTAssertEqual(edges, ["down", "cancel"])
        XCTAssertFalse(originalMonitor.isEnabled)
        XCTAssertFalse(manager.hasActiveRegistration)
        XCTAssertEqual(manager.lastRegistrationError, .inputMonitoringPermissionRequired)

        input.hasPermission = true
        manager.retryRegistrationNow()
        let replacement = try XCTUnwrap(input.monitors.last)
        XCTAssertFalse(originalMonitor === replacement)
        originalMonitor.functionEdge(isDown: false)
        replacement.functionEdge(isDown: true)
        replacement.functionEdge(isDown: false)

        XCTAssertEqual(edges, ["down", "cancel", "down", "up"])
        XCTAssertTrue(manager.hasActiveRegistration)
        XCTAssertNil(manager.lastRegistrationError)
        XCTAssertEqual(input.permissionPrompts, [true, false, false])
    }

    func testFunctionChordCancelsGestureAndCaptureSuspendsHotkey() throws {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["keyCode": Int(KeyboardShortcut.fn.keyCode), "modifiers": 0], forKey: BruteDefaults.shortcut)
        let input = FakeHotkeyInput()
        let manager = HotkeyManager(
            defaults: defaults, observesWake: false, input: input, installHandlerOverride: { .success(()) }
        )
        defer { manager.shutdown() }
        var edges: [String] = []
        manager.onHotkeyDown = { _ in edges.append("down") }
        manager.onHotkeyUp = { _ in edges.append("up") }
        manager.onHotkeyCancelled = { edges.append("cancel") }
        let monitor = try XCTUnwrap(input.monitors.last)

        monitor.functionEdge(isDown: true)
        monitor.deliver(.otherKeyDown)
        monitor.functionEdge(isDown: false)
        XCTAssertEqual(edges, ["down", "cancel"])
        manager.setShortcutRecording(true)
        monitor.functionEdge(isDown: true)
        XCTAssertEqual(edges, ["down", "cancel", "cancel"])
        manager.setShortcutRecording(false)
        monitor.functionEdge(isDown: false)
        monitor.functionEdge(isDown: true)
        monitor.functionEdge(isDown: false)

        XCTAssertEqual(edges, ["down", "cancel", "cancel", "cancel", "down", "up"])
    }

    func testMissingReleaseCancelsRatherThanCommittingTap() throws {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let input = FakeHotkeyInput()
        let manager = HotkeyManager(
            defaults: defaults, observesWake: false, input: input,
            installHandlerOverride: { .success(()) }, registrationOverride: { _ in .success(()) }
        )
        defer { manager.shutdown() }
        var edges: [String] = []
        manager.onHotkeyDown = { _ in edges.append("down") }
        manager.onHotkeyUp = { _ in edges.append("up") }
        manager.onHotkeyCancelled = { edges.append("cancel") }

        manager.handleHotkeyEdge(isDown: true)
        input.keyIsPressed = false
        manager.verifyPressedKey()
        manager.handleHotkeyEdge(isDown: false)
        manager.handleHotkeyEdge(isDown: true)
        manager.handleHotkeyEdge(isDown: false)

        XCTAssertEqual(edges, ["down", "cancel", "down", "up"])
    }
}

@MainActor
private final class FakeHotkeyInput: HotkeyInputSystem {
    var hasPermission = true
    var keyIsPressed = true
    var permissionPrompts: [Bool] = []
    var monitors: [FakeFunctionKeyMonitor] = []

    func inputMonitoringAllowed(prompt: Bool) -> Bool {
        permissionPrompts.append(prompt)
        return hasPermission
    }

    func monitorFunctionKey(
        _ handle: @escaping @MainActor (FunctionKeyInput, TimeInterval) -> Void
    ) -> (any FunctionKeyMonitor)? {
        let monitor = FakeFunctionKeyMonitor(handle: handle)
        monitors.append(monitor)
        return monitor
    }

    func isPressed(_ shortcut: KeyboardShortcut) -> Bool { keyIsPressed }
}

@MainActor
private final class FakeFunctionKeyMonitor: FunctionKeyMonitor {
    private(set) var isEnabled = true
    let handle: @MainActor (FunctionKeyInput, TimeInterval) -> Void

    init(handle: @escaping @MainActor (FunctionKeyInput, TimeInterval) -> Void) {
        self.handle = handle
    }

    func stop() { isEnabled = false }

    func functionEdge(isDown: Bool) {
        deliver(.flagsChanged(isFunctionKey: true, functionIsDown: isDown, chordModifiersAreDown: false))
    }

    func deliver(_ input: FunctionKeyInput) {
        handle(input, ProcessInfo.processInfo.systemUptime)
    }
}
