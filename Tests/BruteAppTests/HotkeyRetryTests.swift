import Foundation
import XCTest
@testable import BruteApp

@MainActor
final class HotkeyRetryTests: XCTestCase {
    func testSuccessfulShortcutReplacementNotifiesObserversOfThisManager() throws {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            installHandlerOverride: { .success(()) },
            registrationOverride: { _ in .success(()) }
        )
        let notifications = RegistrationNotifications(manager: manager)

        try manager.updateShortcut(.fn).get()

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(manager.currentShortcut, .fn)
    }

    func testRepeatedFailureDoesNotNotifyAndShutdownPreventsRecovery() throws {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var registrationAttempts = 0
        var registrationAvailable = false
        let manager = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            installHandlerOverride: { .success(()) },
            registrationOverride: { _ in
                registrationAttempts += 1
                return registrationAvailable ? .success(()) : .failure(.shortcutUnavailable(-1))
            }
        )
        let notifications = RegistrationNotifications(manager: manager)

        manager.retryRegistrationNow()
        XCTAssertEqual(registrationAttempts, 2)
        XCTAssertEqual(notifications.count, 0)

        manager.shutdown()
        registrationAvailable = true
        manager.retryRegistrationNow()

        XCTAssertEqual(registrationAttempts, 2)
        XCTAssertFalse(manager.hasActiveRegistration)
    }
}

@MainActor
private final class RegistrationNotifications {
    private var observation: NotificationObservation?
    private(set) var count = 0

    init(manager: HotkeyManager) {
        observation = NotificationObservation(
            center: .default, name: .bruteHotkeyRegistrationDidChange, object: manager, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }
}
