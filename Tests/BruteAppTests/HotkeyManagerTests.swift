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
                registrationAvailable ? .success(()) : .failure(.accessibilityPermissionRequired)
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
        manager.onHotkeyDown = { downs += 1 }
        manager.onHotkeyUp = { ups += 1 }
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
}
