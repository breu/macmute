import Carbon.HIToolbox
import Foundation
import XCTest
@testable import BruteApp

@MainActor
final class PreferencesTests: XCTestCase {
    func testLaunchAtLoginApprovalRequestRemainsRegistered() {
        let service = FakeLaunchService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let manager = LaunchAtLoginManager(service: service)

        guard case .failure(.requiresApproval) = manager.setEnabled(true) else {
            return XCTFail("Expected approval requirement")
        }
        XCTAssertTrue(manager.isRequested)
        XCTAssertEqual(service.registerCalls, 1)

        guard case .failure(.requiresApproval) = manager.setEnabled(true) else {
            return XCTFail("Expected approval requirement without re-registering")
        }
        XCTAssertEqual(service.registerCalls, 1)
    }

    func testLaunchAtLoginCanCancelPendingApproval() {
        let service = FakeLaunchService(status: .requiresApproval)
        let manager = LaunchAtLoginManager(service: service)

        XCTAssertEqual(try? manager.setEnabled(false).get(), false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(manager.isRequested)
    }

    func testLaunchAtLoginUnknownStatusFailsWithoutMutation() {
        let service = FakeLaunchService(status: .unknown)
        let manager = LaunchAtLoginManager(service: service)

        guard case .failure(.stateDidNotChange) = manager.setEnabled(true) else {
            return XCTFail("Expected unknown status to fail closed")
        }
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testLaunchAtLoginUnknownStatusAlsoFailsClosedWhenDisabling() {
        let service = FakeLaunchService(status: .unknown)
        let manager = LaunchAtLoginManager(service: service)

        guard case .failure(.stateDidNotChange) = manager.setEnabled(false) else {
            return XCTFail("Expected unknown status to fail closed")
        }
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testLaunchAtLoginNotFoundIsAlreadyDisabled() {
        let service = FakeLaunchService(status: .notFound)
        let manager = LaunchAtLoginManager(service: service)

        XCTAssertEqual(try? manager.setEnabled(false).get(), false)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testPreferencesRefreshesLaunchAtLoginAfterExternalChange() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hotkey = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            installHandlerOverride: { .success(()) },
            registrationOverride: { _ in .success(()) }
        )
        let service = FakeLaunchService(status: .requiresApproval)
        let launchManager = LaunchAtLoginManager(service: service)
        let model = PreferencesModel(launchManager: launchManager, hotkeyManager: hotkey)

        model.refreshExternalState()
        XCTAssertTrue(model.launchAtLoginEnabled)
        XCTAssertNotNil(model.launchErrorMessage)

        service.status = .enabled
        model.refreshExternalState()
        XCTAssertTrue(model.launchAtLoginEnabled)
        XCTAssertNil(model.launchErrorMessage)

        service.status = .notRegistered
        model.refreshExternalState()
        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertNil(model.launchErrorMessage)
    }

    func testPreferencesPreservesShortcutDisplayWhenReplacementRegistrationFails() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var registrationCalls = 0
        let hotkey = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            installHandlerOverride: { .success(()) },
            registrationOverride: { _ in
                registrationCalls += 1
                return registrationCalls == 1 ? .success(()) : .failure(.shortcutUnavailable(-1))
            }
        )
        let model = PreferencesModel(
            launchManager: LaunchAtLoginManager(service: FakeLaunchService(status: .notRegistered)),
            hotkeyManager: hotkey
        )

        model.updateShortcut(
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))
        )

        XCTAssertEqual(model.shortcutDisplay, KeyboardShortcut.default.displayString)
        XCTAssertNotNil(model.hotkeyErrorMessage)
        XCTAssertEqual(hotkey.currentShortcut, .default)
        XCTAssertTrue(hotkey.hasActiveRegistration)
    }

    func testPreferencesReflectsLaunchAtLoginRequestFailure() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hotkey = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            installHandlerOverride: { .success(()) },
            registrationOverride: { _ in .success(()) }
        )
        let service = FakeLaunchService(status: .notRegistered)
        service.error = NSError(domain: "tests", code: 1)
        let model = PreferencesModel(
            launchManager: LaunchAtLoginManager(service: service),
            hotkeyManager: hotkey
        )

        model.updateLaunchAtLogin(true)

        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertNotNil(model.launchErrorMessage)
    }

    func testLaunchAtLoginAcceptsNotFoundAfterUnregister() {
        let service = FakeLaunchService(status: .enabled)
        service.statusAfterUnregister = .notFound
        let manager = LaunchAtLoginManager(service: service)

        XCTAssertEqual(try? manager.setEnabled(false).get(), false)
        XCTAssertEqual(service.unregisterCalls, 1)
    }
}

@MainActor
private final class FakeLaunchService: LaunchServiceControlling {
    var status: LaunchServiceStatus
    var statusAfterRegister: LaunchServiceStatus = .enabled
    var statusAfterUnregister: LaunchServiceStatus = .notRegistered
    var registerCalls = 0
    var unregisterCalls = 0
    var error: Error?

    init(status: LaunchServiceStatus) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let error { throw error }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let error { throw error }
        status = statusAfterUnregister
    }
}
