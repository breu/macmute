import CoreAudio
import Foundation
import XCTest
@testable import BruteApp

@MainActor
final class MicMuteControllerTests: XCTestCase {
    func testInitializationReadsHardwareWithoutMutatingIt() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true

        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertEqual(controller.state, .muted)
        XCTAssertEqual(hardware.setMuteCalls, [])
        XCTAssertEqual(hardware.setVolumeCalls, [])
    }

    func testFailedHardwareWriteNeverPublishesRequestedMuteState() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.muteWritesSucceed = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertFalse(controller.setMuted(true))
        XCTAssertEqual(controller.state, .unmuted)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [true])
    }

    func testRepeatedFallbackMutePreservesOriginalVolumeAcrossWake() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.42
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertTrue(controller.setMuted(true))
        controller.handleWake()
        XCTAssertTrue(controller.setMuted(false))

        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(hardware.setVolumeCalls.map(\.volume), [0, 0.42])
        XCTAssertEqual(controller.state, .unmuted)
    }

    func testFallbackBaselineSurvivesControllerRestart() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstHardware = FakeAudioDeviceController(
            defaultDeviceID: 1,
            identifierPrefix: "persistent-device"
        )
        firstHardware.volumes[1] = 0.35
        let firstController = MicMuteController(
            hardware: firstHardware,
            observeSystemChanges: false,
            defaults: defaults
        )
        XCTAssertTrue(firstController.setMuted(true))

        let relaunchedHardware = FakeAudioDeviceController(
            defaultDeviceID: 1,
            identifierPrefix: "persistent-device"
        )
        relaunchedHardware.volumes[1] = 0
        let relaunchedController = MicMuteController(
            hardware: relaunchedHardware,
            observeSystemChanges: false,
            defaults: defaults
        )

        XCTAssertTrue(relaunchedController.setMuted(false))
        XCTAssertEqual(relaunchedHardware.volumes[1] ?? -1, 0.35, accuracy: 0.0001)
    }

    func testDeviceSwitchRestoresDepartingFallbackAndMutesNewDefault() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.4
        hardware.volumes[2] = 0.7
        let controller = MicMuteController(hardware: hardware)

        XCTAssertTrue(controller.setMuted(true))
        hardware.defaultDeviceID = 2
        hardware.triggerDefaultDeviceChange()

        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(hardware.volumes[2] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(controller.state, .muted)

        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(hardware.volumes[2] ?? -1, 0.7, accuracy: 0.0001)
    }

    func testDeviceSwitchReadsActualMutedStateBeforeCarryingMute() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.4
        hardware.volumes[2] = 0.7
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertEqual(controller.state, .unmuted)

        hardware.volumes[1] = 0
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()

        XCTAssertEqual(hardware.volumes[2] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(controller.state, .muted)
    }

    func testDeviceSwitchDoesNotCarryStaleMutedState() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0
        hardware.volumes[2] = 0.7
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertEqual(controller.state, .muted)

        hardware.volumes[1] = 0.4
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()

        XCTAssertEqual(hardware.volumes[2] ?? -1, 0.7, accuracy: 0.0001)
        XCTAssertEqual(controller.state, .unmuted)
    }

    func testDeviceSwitchFailsClosedWhenDepartingStateCannotBeRead() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0
        hardware.volumes[2] = 0.7
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertEqual(controller.state, .muted)

        hardware.volumes[1] = nil
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()

        XCTAssertEqual(hardware.volumes[2] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(controller.state, .muted)
    }

    func testPersistedMuteOwnershipRestoresDepartingDeviceAfterRelaunch() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstHardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        firstHardware.volumes[1] = 0.35
        let firstController = MicMuteController(
            hardware: firstHardware,
            observeSystemChanges: false,
            defaults: defaults
        )
        XCTAssertTrue(firstController.setMuted(true))

        let relaunchedHardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        relaunchedHardware.volumes[1] = 0
        relaunchedHardware.volumes[2] = 0.8
        let relaunchedController = MicMuteController(
            hardware: relaunchedHardware,
            observeSystemChanges: false,
            defaults: defaults
        )
        relaunchedHardware.defaultDeviceID = 2
        relaunchedController.handleDefaultDeviceChange()

        XCTAssertEqual(relaunchedHardware.volumes[1] ?? -1, 0.35, accuracy: 0.0001)
        XCTAssertEqual(relaunchedHardware.volumes[2] ?? -1, 0, accuracy: 0.0001)
    }

    func testFailedDepartingRestoreRemainsQueuedForRetry() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.4
        hardware.volumes[2] = 0.7
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.volumeWriteFailuresRemaining[1] = 1
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        XCTAssertEqual(hardware.volumes[1] ?? -1, 0, accuracy: 0.0001)

        controller.refreshState()
        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.4, accuracy: 0.0001)
    }

    func testDepartingRestorePreservesExternalVolumeAdjustment() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.4
        hardware.volumes[2] = 0.7
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.volumes[1] = 0.6
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()

        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(hardware.volumes[2] ?? -1, 0.7, accuracy: 0.0001)
    }

    func testExternalHardwareChangeRefreshesPublishedState() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let controller = MicMuteController(hardware: hardware)
        XCTAssertEqual(controller.state, .unmuted)

        hardware.mutes[1] = true
        hardware.triggerStateChange()

        XCTAssertEqual(controller.state, .muted)
    }

    func testFailedHoldRestoreRemainsPendingUntilVerified() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var gestureTime = 0.0
        let gestureController = MicrophoneActionController(
            micController: micController,
            feedback: nil,
            observesWake: false, now: { gestureTime }
        )

        gestureController.handleDown()
        gestureTime = 0.4
        hardware.muteWritesSucceed = false
        gestureController.handleUp()
        XCTAssertEqual(micController.state, .unmuted)

        hardware.muteWritesSucceed = true
        micController.refreshState()
        XCTAssertEqual(micController.state, .muted)
    }

    func testPendingUnmuteSurvivesSleepAndWake() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        hardware.deferMuteWrites = true
        XCTAssertTrue(controller.setMuted(false, retryOnFailure: true))
        XCTAssertEqual(controller.state, .muted)
        hardware.setMuteCalls.removeAll()

        controller.prepareForSleep()
        controller.handleWake()
        hardware.completeDeferredWrites()
        controller.refreshState()

        XCTAssertEqual(controller.state, .unmuted)
        XCTAssertTrue(hardware.setMuteCalls.allSatisfy { !$0.muted })
    }

    func testWakeFailurePreservesOwnedMuteIntentForRetry() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        controller.prepareForSleep()
        hardware.mutes[1] = false
        hardware.muteWritesSucceed = false
        controller.handleWake()
        XCTAssertEqual(controller.state, .unmuted)

        hardware.muteWritesSucceed = true
        controller.refreshState()
        XCTAssertEqual(controller.state, .muted)
    }

    func testDeviceCarryFailureRemainsPendingForRetry() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes[1] = true
        hardware.mutes[2] = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        hardware.muteWritesSucceed = false
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        XCTAssertEqual(controller.state, .unmuted)

        hardware.muteWritesSucceed = true
        controller.refreshState()
        XCTAssertEqual(controller.state, .muted)
    }

    func testReadOnlyMutePropertyFallsBackToWritableVolume() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.muteSettable = false
        hardware.mutes[1] = false
        hardware.volumes[1] = 0.5
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertTrue(controller.setMuted(true))
        XCTAssertEqual(hardware.volumes[1] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(controller.state, .muted)
    }

    func testPendingSafetyIntentSurvivesControllerRestartWithStableUID() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstHardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        firstHardware.muteProperties.insert(1)
        firstHardware.mutes[1] = false
        firstHardware.muteWritesSucceed = false
        let firstController = MicMuteController(
            hardware: firstHardware,
            observeSystemChanges: false,
            defaults: defaults
        )
        XCTAssertFalse(firstController.setMuted(true, retryOnFailure: true))

        let relaunchedHardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        relaunchedHardware.muteProperties.insert(1)
        relaunchedHardware.mutes[1] = false
        let relaunchedController = MicMuteController(
            hardware: relaunchedHardware,
            observeSystemChanges: false,
            defaults: defaults
        )
        XCTAssertEqual(relaunchedController.state, .muted)
    }

    func testExplicitUserRequestSupersedesPendingSafetyIntent() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.muteWritesSucceed = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertFalse(controller.setMuted(true, retryOnFailure: true))

        hardware.muteWritesSucceed = true
        XCTAssertTrue(controller.setMuted(false))
        controller.refreshState()

        XCTAssertEqual(controller.state, .unmuted)
        XCTAssertEqual(hardware.mutes[1], false)
    }

    func testMuteCarriesAcrossTemporaryAbsenceOfDefaultDevice() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes[1] = true
        hardware.mutes[2] = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        hardware.defaultDeviceID = nil
        controller.handleDefaultDeviceChange()
        XCTAssertEqual(controller.state, .unavailable)

        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        XCTAssertEqual(controller.state, .muted)
    }

    func testHoldRestoreStaysOnOriginalDeviceAcrossMissingDefaultInputGap() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes[1] = true
        hardware.mutes[2] = false
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var gestureTime = 0.0
        let gestureController = MicrophoneActionController(
            micController: micController,
            feedback: nil,
            observesWake: false, now: { gestureTime }
        )

        gestureController.handleDown()
        gestureTime = 0.4
        hardware.defaultDeviceID = nil
        gestureController.handleUp()
        XCTAssertEqual(micController.state, .unavailable)

        hardware.defaultDeviceID = 2
        micController.handleDefaultDeviceChange()
        micController.refreshState()
        XCTAssertEqual(micController.state, .unmuted)
        XCTAssertEqual(hardware.mutes[1], true)
        XCTAssertEqual(hardware.mutes[2], false)
    }

    func testEphemeralDeviceIdentityIsNeverPersisted() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.persistentIdentifiersAvailable = false
        hardware.volumes[1] = 0.4
        hardware.volumeWritesSucceed = false
        let controller = MicMuteController(
            hardware: hardware,
            observeSystemChanges: false,
            defaults: defaults
        )
        XCTAssertFalse(controller.setMuted(true, retryOnFailure: true))

        XCTAssertEqual(defaults.dictionary(forKey: "MacMute.savedInputVolumes")?.count ?? 0, 0)
        XCTAssertEqual(defaults.array(forKey: "MacMute.appMutedInputDevices")?.count ?? 0, 0)
        XCTAssertEqual(defaults.dictionary(forKey: "MacMute.pendingInputStates")?.count ?? 0, 0)
    }

    func testPendingHoldRestoreStaysWithOriginalInputAcrossDeviceChange() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes[1] = false
        hardware.mutes[2] = true
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var gestureTime = 0.0
        let gestureController = MicrophoneActionController(
            micController: micController,
            feedback: nil,
            observesWake: false, now: { gestureTime }
        )

        gestureController.handleDown()
        gestureTime = 0.4
        hardware.muteWritesSucceed = false
        gestureController.handleUp()
        hardware.muteWritesSucceed = true
        hardware.defaultDeviceID = 2
        micController.handleDefaultDeviceChange()
        micController.refreshState()

        XCTAssertEqual(micController.state, .muted)
        XCTAssertEqual(hardware.mutes[1], false)
        XCTAssertEqual(hardware.mutes[2], true)
    }

    func testNewVerifiedMuteSupersedesUnavailableUnmuteBeforeSwitchingInputs() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes = [1: false, 2: true]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        hardware.persistentIdentifiersAvailable = false
        XCTAssertFalse(controller.setMuted(false, retryOnFailure: true))
        hardware.persistentIdentifiersAvailable = true
        XCTAssertTrue(controller.setMuted(true))

        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()

        XCTAssertEqual(hardware.mutes[2], true)
        XCTAssertEqual(controller.state, .muted)
    }

    func testCommitKeepsTheTemporaryTargetAfterReleaseAndWake() throws {
        for originallyMuted in [false, true] {
            let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
            hardware.muteProperties = [1]
            hardware.mutes[1] = originallyMuted
            let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
            let token = try XCTUnwrap(controller.beginTemporaryToggle())

            XCTAssertTrue(controller.commitTemporaryToggle(token))
            XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [!originallyMuted])
            XCTAssertFalse(controller.endTemporaryToggle(token))
            controller.prepareForSleep()
            controller.handleWake()

            XCTAssertEqual(controller.state.mutedValue, !originallyMuted)
            XCTAssertEqual(hardware.mutes[1], !originallyMuted)
        }
    }

    func testCommitKeepsDeferredGainPendingAcrossRestart() throws {
        let suite = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        hardware.volumes[1] = 0.42
        do {
            let controller = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)
            XCTAssertTrue(controller.setMuted(true))
            hardware.deferVolumeWrites = true
            let token = try XCTUnwrap(controller.beginTemporaryToggle())
            hardware.setVolumeCalls.removeAll()

            XCTAssertTrue(controller.commitTemporaryToggle(token))
            XCTAssertEqual(hardware.setVolumeCalls, [])
            XCTAssertEqual(controller.state, .muted)
            XCTAssertTrue(controller.hasOutstandingWork)
            XCTAssertFalse(controller.endTemporaryToggle(token))
        }

        hardware.deferVolumeWrites = false
        let restarted = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)
        hardware.completeDeferredWrites()
        restarted.refreshState()
        XCTAssertEqual(hardware.volumes[1], 0.42)
        XCTAssertEqual(restarted.state, .unmuted)
        XCTAssertFalse(restarted.hasOutstandingWork)
    }

    func testSecondTemporaryPressUsesAcceptedRestorationBeforeReadback() throws {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1]
        hardware.mutes[1] = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let first = try XCTUnwrap(controller.beginTemporaryToggle())
        XCTAssertEqual(hardware.mutes[1], false)

        hardware.deferMuteWrites = true
        XCTAssertTrue(controller.endTemporaryToggle(first))
        XCTAssertEqual(hardware.deferredMuteWrites[1], true)
        XCTAssertEqual(controller.state, .unmuted)

        let second = try XCTUnwrap(controller.beginTemporaryToggle())
        XCTAssertEqual(first.deviceGeneration, second.deviceGeneration)
        XCTAssertEqual(hardware.deferredMuteWrites[1], false)
        XCTAssertTrue(controller.commitTemporaryToggle(second))
        hardware.completeDeferredWrites()
        controller.refreshState()
        XCTAssertEqual(hardware.mutes[1], false)
        XCTAssertEqual(controller.state, .unmuted)
    }

    func testSecondPressCannotReplaceARejectedRemute() throws {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1]
        hardware.mutes[1] = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let first = try XCTUnwrap(controller.beginTemporaryToggle())
        XCTAssertEqual(hardware.mutes[1], false)

        hardware.muteWritesSucceed = false
        XCTAssertFalse(controller.endTemporaryToggle(first))
        XCTAssertNil(controller.beginTemporaryToggle())

        hardware.muteWritesSucceed = true
        controller.refreshState()
        XCTAssertEqual(hardware.mutes[1], true)
        XCTAssertEqual(controller.state, .muted)
    }

    func testUncommittedSecondPressRestoresOriginalExternalMute() throws {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes = [1: true, 2: false]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let first = try XCTUnwrap(controller.beginTemporaryToggle())
        hardware.deferMuteWrites = true
        XCTAssertTrue(controller.endTemporaryToggle(first))
        let second = try XCTUnwrap(controller.beginTemporaryToggle())
        XCTAssertEqual(hardware.deferredMuteWrites[1], false)

        // The first release reached hardware while the second press's
        // unmute was still queued. The second release must supersede it.
        hardware.mutes[1] = true
        XCTAssertTrue(controller.endTemporaryToggle(second))
        XCTAssertEqual(hardware.deferredMuteWrites[1], true)
        hardware.completeDeferredWrites()
        hardware.deferMuteWrites = false
        controller.refreshState()
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        controller.refreshState()
        XCTAssertEqual(hardware.mutes[1], true)
    }

    func testCommitRejectsAnInputSwitchAndChangesGenerationOnReturn() throws {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes = [1: true, 2: false]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let first = try XCTUnwrap(controller.beginTemporaryToggle())
        hardware.defaultDeviceID = 2

        XCTAssertFalse(controller.commitTemporaryToggle(first))
        XCTAssertEqual(hardware.mutes, [1: true, 2: false])

        hardware.defaultDeviceID = 1
        controller.handleDefaultDeviceChange()
        let second = try XCTUnwrap(controller.beginTemporaryToggle())
        XCTAssertNotEqual(first.deviceGeneration, second.deviceGeneration)
        XCTAssertTrue(controller.endTemporaryToggle(second))

        hardware.persistentIdentifiers[1] = "replacement"
        controller.handleDefaultDeviceChange()
        let third = try XCTUnwrap(controller.beginTemporaryToggle())
        XCTAssertNotEqual(second.deviceGeneration, third.deviceGeneration)
        XCTAssertTrue(controller.endTemporaryToggle(third))
    }

    func testRestartReissuesRejectedReversalBeforeDelayedUnmuteCanWin() throws {
        let suite = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        hardware.volumes[1] = 0.42
        do {
            let controller = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)
            XCTAssertTrue(controller.setMuted(true))
            hardware.deferVolumeWrites = true
            XCTAssertTrue(controller.setMuted(false))
            XCTAssertEqual(hardware.deferredVolumeWrites[1], [0: 0.42])
            hardware.volumeWritesSucceed = false
            XCTAssertFalse(controller.setMuted(true, retryOnFailure: true))
        }

        hardware.volumeWritesSucceed = true
        let restarted = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)
        XCTAssertEqual(hardware.deferredVolumeWrites[1], [0: 0])
        hardware.completeDeferredWrites()
        restarted.refreshState()
        XCTAssertEqual(restarted.state, .muted)
        XCTAssertEqual(hardware.volumes[1], 0)
    }

    func testDepartureReversesAnAcceptedMuteBeforeItsReadbackArrives() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes = [1: 0.42, 2: 0.70]
        hardware.deferVolumeWrites = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        XCTAssertEqual(hardware.deferredVolumeWrites[1], [0: 0])
        XCTAssertEqual(hardware.volumes[1], 0.42)

        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        controller.refreshState()

        XCTAssertEqual(hardware.deferredVolumeWrites[1], [0: 0.42])
        hardware.completeDeferredWrites()
        controller.refreshState()
        XCTAssertEqual(hardware.volumes, [1: 0.42, 2: 0])
    }

    func testTransientUIDReadFailureDoesNotApplyCachedBaselineToUnverifiedDevice() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        hardware.volumes[1] = 0.37
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.persistentIdentifiersAvailable = false
        XCTAssertFalse(controller.setMuted(false))

        XCTAssertEqual(hardware.volumes[1] ?? -1, 0, accuracy: 0.0001)
    }

    func testTransientDepartingUIDFailureIsRetriedWhenDeviceCanBeVerified() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes = [1: 0.42, 2: 0.70]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        hardware.defaultDeviceID = 2
        hardware.persistentIdentifiersAvailable = false
        controller.handleDefaultDeviceChange()
        XCTAssertEqual(hardware.volumes[1], 0)

        hardware.persistentIdentifiersAvailable = true
        controller.refreshState()
        XCTAssertEqual(hardware.volumes[1], 0.42)
    }

    func testReplacementUsingSameDefaultObjectIDGetsItsOwnGainBaseline() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.persistentIdentifiers[1] = "original"
        hardware.volumes[1] = 0.42
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.persistentIdentifiers[1] = "replacement"
        hardware.volumes[1] = 0.70
        controller.handleDefaultDeviceChange()

        XCTAssertEqual(controller.state, .muted)
        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(hardware.volumes[1], 0.70)
    }

    func testReusedAudioObjectIDWithUnavailableUIDNeverReceivesFormerBaseline() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.persistentIdentifiers[1] = "former-device"
        hardware.persistentIdentifiers[2] = "new-default"
        hardware.volumes[1] = 0.37
        hardware.volumes[2] = 0.8
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.persistentIdentifiersAvailable = false
        hardware.volumes[1] = 0
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()

        XCTAssertEqual(hardware.volumes[1] ?? -1, 0, accuracy: 0.0001)
        XCTAssertFalse(hardware.setVolumeCalls.contains { $0.deviceID == 1 && $0.volume == 0.37 })
    }

    func testSessionIdentityUpgradesToUIDWithoutLosingVolumeBaseline() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "later-stable")
        hardware.persistentIdentifiersAvailable = false
        hardware.volumes[1] = 0.31
        let controller = MicMuteController(
            hardware: hardware,
            observeSystemChanges: false,
            defaults: defaults
        )
        XCTAssertTrue(controller.setMuted(true))

        hardware.persistentIdentifiersAvailable = true
        controller.refreshState()
        XCTAssertTrue(controller.setMuted(false))

        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.31, accuracy: 0.0001)
        XCTAssertEqual(defaults.dictionary(forKey: "MacMute.savedInputVolumes")?.count, 1)
    }

    func testReusedAudioObjectIDCannotRestoreAFormerDeviceOntoANewDevice() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.persistentIdentifiers[1] = "old-device"
        hardware.persistentIdentifiers[2] = "current-device"
        hardware.volumes[1] = 0.4
        hardware.volumes[2] = 0.8
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.volumeWriteFailuresRemaining[1] = 1
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        hardware.persistentIdentifiers[1] = "replacement-device"
        hardware.volumes[1] = 0
        controller.refreshState()

        XCTAssertEqual(hardware.volumes[1] ?? -1, 0, accuracy: 0.0001)
    }

    func testReadOnlyNativeMuteCannotBeReportedAsUnmutedByVolumeFallback() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.muteSettable = false
        hardware.mutes[1] = true
        hardware.volumes[1] = 0.5
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertEqual(controller.state, .muted)
        XCTAssertFalse(controller.setMuted(false))
        XCTAssertEqual(controller.state, .muted)
    }

    func testTransientNativeMuteReadFailureDoesNotCreateSplitMuteAuthorities() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.volumes[1] = 0.6
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        hardware.muteReadsSucceed = false
        XCTAssertFalse(controller.setMuted(true))
        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.6, accuracy: 0.0001)

        hardware.muteReadsSucceed = true
        controller.refreshState()
        XCTAssertEqual(controller.state, .unmuted)
    }

    func testChannelVolumeFallbackRestoresEveryOriginalChannel() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumeSnapshots[1] = [1: 0.25, 2: 0.75]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertTrue(controller.setMuted(true))
        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 0, 2: 0])
        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 0.25, 2: 0.75])
    }

    func testChannelVolumeSnapshotWithSilentChannelSurvivesRestart() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstHardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "channels")
        firstHardware.volumeSnapshots[1] = [1: 0, 2: 0.65]
        let firstController = MicMuteController(
            hardware: firstHardware,
            observeSystemChanges: false,
            defaults: defaults
        )
        XCTAssertTrue(firstController.setMuted(true))

        let relaunchedHardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "channels")
        relaunchedHardware.volumeSnapshots[1] = [1: 0, 2: 0]
        let relaunchedController = MicMuteController(
            hardware: relaunchedHardware,
            observeSystemChanges: false,
            defaults: defaults
        )

        XCTAssertTrue(relaunchedController.setMuted(false))
        XCTAssertEqual(relaunchedHardware.volumeSnapshots[1], [1: 0, 2: 0.65])
    }

    func testAddedVolumeChannelUsesSafeDefaultDuringRestore() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumeSnapshots[1] = [1: 0.25, 2: 0.75]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.volumeSnapshots[1] = [1: 0, 2: 0, 3: 0]
        XCTAssertTrue(controller.setMuted(false))

        // A channel with no recorded baseline must not be restored to full input
        // gain; a device that gains a channel mid-call should not jump to 100%.
        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 0.25, 2: 0.75, 3: 0.5])
    }

    func testRemovedVolumeChannelDoesNotBlockRestore() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumeSnapshots[1] = [1: 0.25, 2: 0.75]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.volumeSnapshots[1] = [2: 0]
        XCTAssertTrue(controller.setMuted(false))

        XCTAssertEqual(hardware.volumeSnapshots[1], [2: 0.75])
    }

    func testReadOnlyUnmutedNativeControlUsesVolumeRoundTrip() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.muteSettable = false
        hardware.mutes[1] = false
        hardware.volumes[1] = 0.44
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertTrue(controller.setMuted(true))
        XCTAssertEqual(controller.state, .muted)
        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.44, accuracy: 0.0001)
        XCTAssertEqual(controller.state, .unmuted)
    }

    func testReadOnlyNativeMuteUsesOneCoherentSamplePerStateRead() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.muteSettable = false
        hardware.muteReadResults = [false, true]
        hardware.volumes[1] = 0.5

        let state = MicMuteController.readState(on: 1, using: hardware)

        XCTAssertEqual(state, .unmuted)
        XCTAssertEqual(hardware.muteReadResults.count, 1)
    }

    func testAudioObjectIDReusedBeforeDefaultChangeDoesNotTouchReplacement() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.persistentIdentifiers[1] = "departing-device"
        hardware.persistentIdentifiers[2] = "new-default"
        hardware.volumes[1] = 0.4
        hardware.volumes[2] = 0.8
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.persistentIdentifiers[1] = "replacement-device"
        hardware.volumes[1] = 0
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()

        XCTAssertEqual(hardware.volumes[1] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(controller.state, .muted)
    }

    func testWritableNativeUnmutedAndZeroVolumeIsStillMuted() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.volumes[1] = 0

        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertEqual(controller.state, .muted)
    }

    func testNativeMuteCapabilityAppearingAfterFallbackDoesNotStrandZeroVolume() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.35
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))

        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        XCTAssertTrue(controller.setMuted(false))

        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.35, accuracy: 0.0001)
        XCTAssertEqual(controller.state, .unmuted)
    }

    func testAcceptedAsynchronousMuteRemainsOwnedUntilObservedAndRestored() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.deferMuteWrites = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertTrue(controller.setMuted(true))
        XCTAssertEqual(controller.state, .unmuted)
        hardware.completeDeferredWrites()
        hardware.deferMuteWrites = false
        controller.refreshState()
        XCTAssertEqual(controller.state, .muted)

        hardware.defaultDeviceID = 2
        hardware.muteProperties.insert(2)
        hardware.mutes[2] = false
        controller.handleDefaultDeviceChange()
        XCTAssertEqual(hardware.mutes[1], false)
    }

    func testAcceptedAsynchronousVolumeRoundTripWaitsForObservation() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.42
        hardware.deferVolumeWrites = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertTrue(controller.setMuted(true))
        XCTAssertEqual(controller.state, .unmuted)
        hardware.completeDeferredWrites()
        controller.refreshState()
        XCTAssertEqual(controller.state, .muted)

        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(controller.state, .muted)
        hardware.completeDeferredWrites()
        hardware.deferVolumeWrites = false
        controller.refreshState()
        XCTAssertEqual(controller.state, .unmuted)
        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.42, accuracy: 0.0001)
    }

    func testPartialFallbackRestoreStaysPendingUntilEachChannelMatches() throws {
        let suite = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        let baseline: InputVolumeSnapshot = [1: 0.30, 2: 0.60]
        hardware.volumeSnapshots[1] = baseline
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)
        XCTAssertTrue(controller.setMuted(true))
        hardware.deferVolumeWrites = true
        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(hardware.deferredVolumeWrites[1], baseline)

        // The driver accepted both writes but applied only the first channel.
        hardware.deferredVolumeWrites[1] = [1: 0.30, 2: 0]
        hardware.completeDeferredWrites()
        hardware.volumeSnapshots[1]?[3] = 0.10
        controller.refreshState()
        XCTAssertEqual(controller.state, .unmuted)
        XCTAssertTrue(controller.hasOutstandingWork)
        XCTAssertEqual(hardware.deferredVolumeWrites[1], [1: 0.30, 2: 0.60, 3: 0.10])
        XCTAssertEqual(defaults.stringArray(forKey: BruteDefaults.appMutedInputDevices), ["uid:stable-1"])

        // The driver can quantize the restored gain by a small amount.
        hardware.deferredVolumeWrites[1] = [1: 0.304, 2: 0.597, 3: 0.13]
        hardware.completeDeferredWrites()
        hardware.setVolumeCalls.removeAll()
        controller.refreshState()
        XCTAssertFalse(controller.hasOutstandingWork)
        XCTAssertEqual(hardware.setVolumeCalls, [])
        XCTAssertEqual(defaults.stringArray(forKey: BruteDefaults.appMutedInputDevices), [])
    }

    func testPartialFallbackRestoreResumesAfterRestart() throws {
        let suite = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        let baseline: InputVolumeSnapshot = [1: 0.30, 2: 0.60]
        hardware.volumeSnapshots[1] = baseline
        var controller: MicMuteController? = MicMuteController(
            hardware: hardware, observeSystemChanges: false, defaults: defaults
        )
        XCTAssertTrue(controller?.setMuted(true) == true)
        hardware.deferVolumeWrites = true
        XCTAssertTrue(controller?.setMuted(false) == true)
        hardware.deferredVolumeWrites[1] = [1: 0.30, 2: 0]
        hardware.completeDeferredWrites()
        controller = nil

        hardware.deferVolumeWrites = false
        let restarted = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)
        XCTAssertEqual(hardware.volumeSnapshots[1], baseline)
        XCTAssertEqual(restarted.state, .unmuted)
        XCTAssertFalse(restarted.hasOutstandingWork)
    }

    func testPartialFallbackRestoreContinuesAfterDeviceSwitchWithNativeMute() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        let baseline: InputVolumeSnapshot = [1: 0.30, 2: 0.60]
        hardware.volumeSnapshots[1] = baseline
        hardware.volumes[2] = 0.80
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        hardware.deferVolumeWrites = true
        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(hardware.mutes[1], false)
        hardware.deferredVolumeWrites[1] = [1: 0.30, 2: 0]
        hardware.completeDeferredWrites()

        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        XCTAssertEqual(hardware.deferredVolumeWrites[1], baseline)
        XCTAssertTrue(controller.hasOutstandingWork)
        XCTAssertEqual(hardware.volumes[2], 0.80)

        hardware.completeDeferredWrites()
        controller.refreshState()
        XCTAssertEqual(hardware.volumeSnapshots[1], baseline)
        XCTAssertFalse(controller.hasOutstandingWork)
    }

    func testSupersedingPartialRestorePreservesBaselineAndRequiresAcceptedMute() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        let baseline: InputVolumeSnapshot = [1: 0.30, 2: 0.60]
        hardware.volumeSnapshots[1] = baseline
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        hardware.deferVolumeWrites = true
        XCTAssertTrue(controller.setMuted(false))
        hardware.deferredVolumeWrites[1] = [1: 0.30, 2: 0]
        hardware.completeDeferredWrites()
        hardware.deferVolumeWrites = false

        hardware.volumeWritesSucceed = false
        XCTAssertFalse(controller.setMuted(true))
        XCTAssertTrue(controller.hasOutstandingWork)
        hardware.volumeWritesSucceed = true
        XCTAssertTrue(controller.setMuted(true))
        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 0, 2: 0])
        XCTAssertFalse(controller.hasOutstandingWork)
        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(hardware.volumeSnapshots[1], baseline)
    }

    func testGainOnlyRestoreDoesNotTransferAnUnmuteOrChangeNativeMute() throws {
        let suite = "BruteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["uid:stable-1": ["1": 0.30, "2": 0.60]], forKey: BruteDefaults.pendingInputVolumeRestorations)
        defaults.set(["uid:stable-1"], forKey: BruteDefaults.appMutedInputDevices)
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        hardware.volumeSnapshots[1] = [1: 0.30, 2: 0]
        hardware.muteProperties = [1, 2]
        hardware.mutes = [1: false, 2: true]
        hardware.deferVolumeWrites = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)

        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        XCTAssertEqual(hardware.mutes[2], true)

        hardware.mutes[1] = true
        hardware.completeDeferredWrites()
        controller.refreshState()
        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 0.30, 2: 0.60])
        XCTAssertEqual(hardware.mutes[1], true)
        XCTAssertEqual(hardware.setMuteCalls, [])
        XCTAssertFalse(controller.hasOutstandingWork)
    }

    func testRestoreConfirmsIfOnlyAnIntentionallySilentChannelRemains() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumeSnapshots[1] = [1: 0, 2: 0.65]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        hardware.volumeSnapshots[1] = [1: 0]

        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(controller.state, .muted)
        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 0])
        XCTAssertFalse(controller.hasOutstandingWork)
    }

    func testWakeRefusesCachedIdentityWhenLiveUIDCannotBeRead() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        controller.prepareForSleep()
        hardware.setMuteCalls.removeAll()
        hardware.persistentIdentifiersAvailable = false
        hardware.mutes[1] = false

        controller.handleWake()

        XCTAssertEqual(hardware.setMuteCalls, [])
        XCTAssertEqual(controller.state, .unmuted)
    }

    func testDefaultDeviceChangingDuringWriteFailsClosedWithoutTouchingNewDefault() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes = [1: false, 2: false]
        hardware.onSetMute = { hardware.defaultDeviceID = 2 }
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertFalse(controller.setMuted(true))

        XCTAssertEqual(hardware.mutes[2], false)
        XCTAssertEqual(hardware.setMuteCalls.map(\.deviceID), [1])
        XCTAssertEqual(controller.state, .unavailable)
    }

    func testMalformedPersistedVolumeSnapshotIsRejectedAsAWhole() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["uid:stable-1": ["1": 0.2, "2": true]], forKey: "MacMute.savedInputVolumes")
        defaults.set(["uid:stable-1"], forKey: "MacMute.appMutedInputDevices")
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        hardware.volumeSnapshots[1] = [1: 0, 2: 0]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)

        XCTAssertTrue(controller.setMuted(false))

        // The corrupt snapshot is discarded wholesale, so no channel has a baseline
        // and each falls back to the conservative restore level rather than full gain.
        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 0.5, 2: 0.5])
    }

    func testNonBooleanPersistedPendingIntentIsRejected() {
        let suiteName = "BruteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["uid:stable-1": 2], forKey: "MacMute.pendingInputStates")
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false

        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)

        XCTAssertEqual(controller.state, .unmuted)
        XCTAssertEqual(hardware.setMuteCalls, [])
    }

    func testDeferredUnmuteHoldMustRestoreMuteAfterRelease() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        hardware.deferMuteWrites = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var gestureTime = 0.0
        let gesture = MicrophoneActionController(
            micController: controller, feedback: nil,
            observesWake: false, now: { gestureTime }
        )
        gesture.handleDown()
        gestureTime = 0.4
        gesture.handleUp()
        hardware.completeDeferredWrites()
        hardware.deferMuteWrites = false
        controller.refreshState()
        XCTAssertEqual(controller.state, .muted)
    }

    func testCapabilityChangeMustRestoreDepartingFallbackVolume() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.35
        hardware.volumes[2] = 0.6
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        controller.refreshState()
        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.35, accuracy: 0.0001)
    }

    func testPartialVolumeProgressMustPreserveOriginalBaseline() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumeSnapshots[1] = [1: 0.3, 2: 0.6]
        hardware.deferVolumeWrites = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        hardware.volumeSnapshots[1] = [1: 0, 2: 0.6]
        controller.refreshState()
        hardware.completeDeferredWrites()
        hardware.deferVolumeWrites = false
        controller.refreshState()
        XCTAssertTrue(controller.setMuted(false))
        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 0.3, 2: 0.6])
    }

    func testRejectedReversalOfDeferredHoldIsRetriedEvenBeforeReadbackChanges() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        hardware.deferMuteWrites = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var gestureTime = 0.0
        let gesture = MicrophoneActionController(
            micController: controller, feedback: nil,
            observesWake: false, now: { gestureTime }
        )
        gesture.handleDown()
        gestureTime = 0.4
        hardware.muteWritesSucceed = false
        gesture.handleUp()
        controller.refreshState()
        hardware.muteWritesSucceed = true
        controller.refreshState()
        hardware.completeDeferredWrites()
        hardware.deferMuteWrites = false
        controller.refreshState()
        XCTAssertEqual(controller.state, .muted)
        XCTAssertEqual(hardware.setMuteCalls.last?.muted, true)
    }

    func testDeferredFallbackMuteIsSupersededByHoldRelease() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.42
        hardware.deferVolumeWrites = true
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var gestureTime = 0.0
        let gesture = MicrophoneActionController(
            micController: controller, feedback: nil,
            observesWake: false, now: { gestureTime }
        )
        gesture.handleDown()
        gestureTime = 0.4
        gesture.handleUp()
        hardware.completeDeferredWrites()
        hardware.deferVolumeWrites = false
        controller.refreshState()
        XCTAssertEqual(controller.state, .unmuted)
        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.42, accuracy: 0.0001)
    }

    func testDepartingRestoreClearsNativeMuteAndFallbackVolumeTogether() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.35
        hardware.volumes[2] = 0.6
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertTrue(controller.setMuted(true))
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        hardware.defaultDeviceID = 2
        controller.handleDefaultDeviceChange()
        XCTAssertEqual(hardware.mutes[1], false)
        XCTAssertEqual(hardware.volumes[1] ?? -1, 0.35, accuracy: 0.0001)
    }

    func testPendingWriteReschedulesPollingUntilConfirmed() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.deferMuteWrites = true
        hardware.volumes[1] = 0.5
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: true)
        defer { controller.shutdown() }
        XCTAssertEqual(controller.scheduledPollInterval, MicMuteController.idlePollInterval)

        XCTAssertTrue(controller.setMuted(true))
        XCTAssertEqual(controller.scheduledPollInterval, MicMuteController.activePollInterval)

        hardware.completeDeferredWrites()
        controller.refreshState()
        XCTAssertEqual(controller.state, .muted)
        XCTAssertEqual(controller.scheduledPollInterval, MicMuteController.idlePollInterval)
    }

    func testUnhealthyObservationNeverDropsToIdleCadence() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.5
        hardware.stateObservationSucceeds = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: true)
        defer { controller.shutdown() }

        XCTAssertEqual(controller.scheduledPollInterval, MicMuteController.fallbackPollInterval)

        hardware.defaultDeviceID = 2
        hardware.volumes[2] = 0.7
        hardware.stateObservationSucceeds = true
        hardware.triggerDefaultDeviceChange()

        XCTAssertEqual(controller.scheduledPollInterval, MicMuteController.idlePollInterval)
    }

    func testDefaultDeviceChangeInvalidatesControlCaches() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.5
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        hardware.defaultDeviceID = 2
        hardware.volumes[2] = 0.8
        controller.handleDefaultDeviceChange()

        XCTAssertTrue(
            hardware.invalidateControlCachesCalls.contains(1),
            "The device being left behind must have its cached capabilities dropped"
        )
    }

    func testNoInputDeviceExplainsUnavailableState() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: nil)
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertEqual(controller.lastError, .noInputDevice)
        XCTAssertTrue(
            StatusBarController.presentation(for: controller.state, error: controller.lastError)
                .menuTitle
                .contains("No input device")
        )
    }

    func testUnavailableReasonChangesNotifyMenuWithoutStateChange() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: nil)
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var notifiedStates: [MicrophoneState] = []
        controller.onStateChanged = { notifiedStates.append($0) }

        hardware.defaultDeviceID = 1
        controller.refreshState()

        XCTAssertEqual(controller.state, .unavailable)
        XCTAssertEqual(controller.lastError, .deviceControlsUnreadable)
        XCTAssertEqual(notifiedStates, [.unavailable])
    }

    func testErrorClearsWhenMicrophoneBecomesAvailable() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: nil)
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)
        XCTAssertEqual(controller.lastError, .noInputDevice)

        hardware.defaultDeviceID = 1
        hardware.volumes[1] = 0.5
        controller.refreshState()

        XCTAssertEqual(controller.state, .unmuted)
        XCTAssertNil(controller.lastError)
    }

    func testShutdownReleasesHardwareObservation() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.5
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: true)

        controller.shutdown()

        XCTAssertTrue(hardware.shutdownCalled)
    }

    func testShutdownDoesNotTouchHardwareItDidNotOwn() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.5
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        controller.shutdown()

        XCTAssertFalse(hardware.shutdownCalled, "A controller that never started observation must not stop it")
    }
}
