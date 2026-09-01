import CoreAudio
import Carbon.HIToolbox
import AVFoundation
import Foundation
import XCTest
@testable import MacMuteApp

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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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

    func testWakeDuringPushToUnmuteRestoresPriorMutedState() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gestureController = PushToTalkController(
            micController: micController,
            playsFeedback: false,
            observesWake: false,
            initialMode: .pushToUnmute
        )

        gestureController.beginHold()
        XCTAssertEqual(micController.state, .unmuted)

        gestureController.handleWake()
        XCTAssertEqual(micController.state, .muted)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [false, true])
    }

    func testCancellingActiveHotkeyGestureRestoresPriorStateWithoutApplyingTap() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gestureController = PushToTalkController(
            micController: micController,
            playsFeedback: false,
            observesWake: false,
            initialMode: .pushToMute
        )

        gestureController.beginHold()
        XCTAssertEqual(micController.state, .muted)
        gestureController.cancelActiveGesture()

        XCTAssertEqual(micController.state, .unmuted)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [true, false])
    }

    func testFailedHoldRestoreRemainsPendingUntilVerified() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gestureController = PushToTalkController(
            micController: micController,
            playsFeedback: false,
            observesWake: false,
            initialMode: .pushToUnmute
        )

        gestureController.beginHold()
        hardware.muteWritesSucceed = false
        gestureController.handleUp()
        XCTAssertEqual(micController.state, .unmuted)

        hardware.muteWritesSucceed = true
        micController.refreshState()
        XCTAssertEqual(micController.state, .muted)
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

    func testToggleReadsHardwareBeforeChoosingDirection() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        hardware.mutes[1] = true
        XCTAssertTrue(controller.toggle())
        XCTAssertEqual(controller.state, .unmuted)
    }

    func testModeChangeRollsBackWhenRestingStateCannotBeApplied() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.muteWritesSucceed = false
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gestureController = PushToTalkController(
            micController: micController,
            playsFeedback: false,
            observesWake: false,
            initialMode: .pushToMute
        )

        XCTAssertFalse(gestureController.setMode(.pushToUnmute))
        XCTAssertEqual(gestureController.mode, .pushToMute)
        XCTAssertEqual(micController.state, .unmuted)
    }

    func testPendingSafetyIntentSurvivesControllerRestartWithStableUID() {
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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

    func testFailedHoldRestoreCarriesAcrossMissingDeviceGap() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes[1] = true
        hardware.mutes[2] = false
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gestureController = PushToTalkController(
            micController: micController,
            playsFeedback: false,
            observesWake: false,
            initialMode: .pushToUnmute
        )

        gestureController.beginHold()
        hardware.defaultDeviceID = nil
        gestureController.handleUp()
        XCTAssertEqual(micController.state, .unavailable)

        hardware.defaultDeviceID = 2
        micController.handleDefaultDeviceChange()
        XCTAssertEqual(micController.state, .muted)
    }

    func testHoldRefreshesPriorStateBeforeRestoration() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gestureController = PushToTalkController(
            micController: micController,
            playsFeedback: false,
            observesWake: false,
            initialMode: .pushToUnmute
        )

        hardware.mutes[1] = true
        gestureController.beginHold()
        XCTAssertEqual(micController.state, .unmuted)
        gestureController.handleUp()

        XCTAssertEqual(micController.state, .muted)
    }

    func testEphemeralDeviceIdentityIsNeverPersisted() {
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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

    func testPendingUnmuteTransfersAcrossDeviceChange() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties = [1, 2]
        hardware.mutes[1] = false
        hardware.mutes[2] = false
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gestureController = PushToTalkController(
            micController: micController,
            playsFeedback: false,
            observesWake: false,
            initialMode: .pushToMute
        )

        gestureController.beginHold()
        hardware.muteWritesSucceed = false
        gestureController.handleUp()
        hardware.muteWritesSucceed = true
        hardware.defaultDeviceID = 2
        micController.handleDefaultDeviceChange()

        XCTAssertEqual(micController.state, .unmuted)
        XCTAssertEqual(hardware.mutes[2], false)
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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

        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 0.25, 2: 0.75, 3: 1])
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

    func testControlResolutionRejectsPartialChannelCoverage() {
        XCTAssertEqual(
            CoreAudioDeviceController.resolveWritableControlElements(
                mainAvailable: false,
                mainSettable: false,
                inputElements: [1, 2],
                availableChannelElements: [1],
                settableChannelElements: [1]
            ),
            []
        )
        XCTAssertEqual(
            CoreAudioDeviceController.resolveWritableControlElements(
                mainAvailable: false,
                mainSettable: false,
                inputElements: [1, 2],
                availableChannelElements: [1, 2],
                settableChannelElements: [1]
            ),
            []
        )
    }

    func testControlResolutionUsesCompleteChannelsOrAggregateMain() {
        XCTAssertEqual(
            CoreAudioDeviceController.resolveWritableControlElements(
                mainAvailable: false,
                mainSettable: false,
                inputElements: [1, 2],
                availableChannelElements: [1, 2],
                settableChannelElements: [1, 2]
            ),
            [1, 2]
        )
        XCTAssertEqual(
            CoreAudioDeviceController.resolveWritableControlElements(
                mainAvailable: true,
                mainSettable: true,
                inputElements: [1, 2],
                availableChannelElements: [],
                settableChannelElements: []
            ),
            [kAudioObjectPropertyElementMain]
        )
    }

    func testAtomicElementWriteRollsBackChangedElementsInReverseOrder() {
        var values: [UInt32: Int] = [1: 10, 2: 20, 3: 30]
        var writes: [(UInt32, Int)] = []
        let succeeded = CoreAudioDeviceController.performAtomicWrite(
            elements: [1, 2, 3],
            priorValues: values,
            desiredValues: [1: 0, 2: 0, 3: 0]
        ) { element, value in
            writes.append((element, value))
            if element == 3 && value == 0 { return false }
            values[element] = value
            return true
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(values, [1: 10, 2: 20, 3: 30])
        XCTAssertEqual(writes.map(\.0), [1, 2, 3, 2, 1])
    }

    func testAtomicElementWriteRejectsMismatchedElementSetsWithoutWriting() {
        var writeCount = 0
        XCTAssertFalse(
            CoreAudioDeviceController.performAtomicWrite(
                elements: [1, 2],
                priorValues: [1: 1, 2: 1],
                desiredValues: [1: 0]
            ) { _, _ in
                writeCount += 1
                return true
            }
        )
        XCTAssertEqual(writeCount, 0)
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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

        manager.handleCarbonHotkeyEdge(isDown: true)
        manager.handleWake()
        manager.handleCarbonHotkeyEdge(isDown: true)
        manager.handleCarbonHotkeyEdge(isDown: false)

        XCTAssertEqual(downs, 2)
        XCTAssertEqual(ups, 1)
        XCTAssertEqual(cancellations, 1)
    }

    func testSingleTapRunsModeActionAfterDoubleClickWindow() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gesture = PushToTalkController(
            micController: mic,
            playsFeedback: false,
            observesWake: false,
            initialMode: .pushToMute,
            doubleClickWindow: 0.01
        )

        gesture.handleDown()
        gesture.handleUp()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        XCTAssertEqual(mic.state, .muted)
    }

    func testDoubleTapChangesModeWithoutRunningFirstTap() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gesture = PushToTalkController(
            micController: mic,
            playsFeedback: false,
            observesWake: false,
            initialMode: .pushToMute,
            doubleClickWindow: 1
        )
        var reportedMode: HotkeyMode?
        gesture.onModeChanged = { reportedMode = $0 }

        gesture.handleDown()
        gesture.handleUp()
        gesture.handleDown()
        gesture.handleUp()

        XCTAssertEqual(gesture.mode, .pushToUnmute)
        XCTAssertEqual(reportedMode, .pushToUnmute)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [true])
    }

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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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

    func testStatusPresentationsCoverEveryMicrophoneStateAndInactiveHotkey() {
        XCTAssertEqual(
            StatusBarController.presentation(for: .muted).menuTitle,
            "Microphone State: Muted"
        )
        XCTAssertEqual(
            StatusBarController.presentation(for: .unmuted).accessibilityDescription,
            "Microphone unmuted"
        )
        XCTAssertEqual(
            StatusBarController.presentation(for: .unavailable).symbol,
            "exclamationmark.triangle.fill"
        )
        XCTAssertEqual(StatusBarController.hotkeyTitle(error: nil, isActive: true), "Hotkey: Active")
        XCTAssertEqual(StatusBarController.hotkeyTitle(error: nil, isActive: false), "Hotkey: Inactive")
        XCTAssertTrue(
            StatusBarController.hotkeyTitle(error: .monitorUnavailable, isActive: false)
                .contains("fn-key monitor")
        )
        XCTAssertEqual(
            StatusBarController.modePresentation(for: .pushToMute).symbol,
            "mic.slash.circle.fill"
        )
        XCTAssertEqual(
            StatusBarController.modePresentation(for: .pushToUnmute).symbol,
            "mic.circle.fill"
        )
        XCTAssertNotEqual(
            StatusBarController.modePresentation(for: .pushToMute),
            StatusBarController.modePresentation(for: .pushToUnmute)
        )
    }

    func testSynthesizedFeedbackBuffersAreFiniteAndSized() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let click = ClickSoundPlayer.makeClickBuffer(format: format, sampleRate: 44_100)
        let mode = ClickSoundPlayer.makeModeChangeBuffer(format: format, sampleRate: 44_100)

        XCTAssertEqual(click.frameLength, AVAudioFrameCount(44_100 * 0.03))
        XCTAssertEqual(mode.frameLength, AVAudioFrameCount(44_100 * 0.12))
        XCTAssertTrue((0..<Int(click.frameLength)).allSatisfy { click.floatChannelData![0][$0].isFinite })
        XCTAssertTrue((0..<Int(mode.frameLength)).allSatisfy { mode.floatChannelData![0][$0].isFinite })
    }

    func testReadableControlResolutionPrefersReadOnlyAggregateMain() {
        XCTAssertEqual(
            CoreAudioDeviceController.resolveReadableControlElements(
                mainAvailable: true,
                inputElements: [1, 2],
                availableChannelElements: [1, 2]
            ),
            [kAudioObjectPropertyElementMain]
        )
        XCTAssertEqual(
            CoreAudioDeviceController.resolveWritableControlElements(
                mainAvailable: true,
                mainSettable: false,
                inputElements: [1, 2],
                availableChannelElements: [1, 2],
                settableChannelElements: [1, 2]
            ),
            [1, 2]
        )
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
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["uid:stable-1": ["1": 0.2, "2": true]], forKey: "MacMute.savedInputVolumes")
        defaults.set(["uid:stable-1"], forKey: "MacMute.appMutedInputDevices")
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1, identifierPrefix: "stable")
        hardware.volumeSnapshots[1] = [1: 0, 2: 0]
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false, defaults: defaults)

        XCTAssertTrue(controller.setMuted(false))

        XCTAssertEqual(hardware.volumeSnapshots[1], [1: 1, 2: 1])
    }

    func testNonBooleanPersistedPendingIntentIsRejected() {
        let suiteName = "MacMuteTests.\(UUID().uuidString)"
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

    func testLaunchAtLoginAcceptsNotFoundAfterUnregister() {
        let service = FakeLaunchService(status: .enabled)
        service.statusAfterUnregister = .notFound
        let manager = LaunchAtLoginManager(service: service)

        XCTAssertEqual(try? manager.setEnabled(false).get(), false)
        XCTAssertEqual(service.unregisterCalls, 1)
    }
}

@MainActor
private final class FakeAudioDeviceController: AudioDeviceControlling {
    struct MuteCall: Equatable {
        let muted: Bool
        let deviceID: AudioDeviceID
    }

    struct VolumeCall: Equatable {
        let volume: Float32
        let deviceID: AudioDeviceID
    }

    var defaultDeviceID: AudioDeviceID?
    var muteProperties: Set<AudioDeviceID> = []
    var muteSettable = true
    var volumeSettable = true
    var muteWritesSucceed = true
    var volumeWritesSucceed = true
    var volumeWriteFailuresRemaining: [AudioDeviceID: Int] = [:]
    var mutes: [AudioDeviceID: Bool] = [:]
    var volumes: [AudioDeviceID: Float32] = [:]
    var volumeSnapshots: [AudioDeviceID: InputVolumeSnapshot] = [:]
    var setMuteCalls: [MuteCall] = []
    var setVolumeCalls: [VolumeCall] = []
    private let identifierPrefix: String
    var persistentIdentifiersAvailable = true
    var persistentIdentifiers: [AudioDeviceID: String] = [:]
    var muteReadsSucceed = true
    var muteReadResults: [Bool?] = []
    var deferMuteWrites = false
    var deferredMuteWrites: [AudioDeviceID: Bool] = [:]
    var onSetMute: (() -> Void)?
    var deferVolumeWrites = false
    var deferredVolumeWrites: [AudioDeviceID: InputVolumeSnapshot] = [:]

    private var defaultDeviceChangeHandler: (@MainActor () -> Void)?
    private var stateChangeHandler: (@MainActor () -> Void)?

    init(defaultDeviceID: AudioDeviceID?, identifierPrefix: String = UUID().uuidString) {
        self.defaultDeviceID = defaultDeviceID
        self.identifierPrefix = identifierPrefix
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID
    }

    func persistentIdentifier(for deviceID: AudioDeviceID) -> String? {
        guard persistentIdentifiersAvailable else { return nil }
        return persistentIdentifiers[deviceID] ?? "\(identifierPrefix)-\(deviceID)"
    }

    func hasMuteProperty(on deviceID: AudioDeviceID) -> Bool {
        muteProperties.contains(deviceID)
    }

    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool {
        muteSettable
    }

    func readMute(on deviceID: AudioDeviceID) -> Bool? {
        if !muteReadResults.isEmpty {
            return muteReadResults.removeFirst()
        }
        return muteReadsSucceed ? mutes[deviceID] : nil
    }

    func setMute(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        setMuteCalls.append(MuteCall(muted: muted, deviceID: deviceID))
        guard muteWritesSucceed else { return false }
        if deferMuteWrites {
            deferredMuteWrites[deviceID] = muted
        } else {
            mutes[deviceID] = muted
        }
        onSetMute?()
        return true
    }

    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool {
        volumeSettable && (volumes[deviceID] != nil || volumeSnapshots[deviceID] != nil)
    }

    func readVolumes(on deviceID: AudioDeviceID) -> InputVolumeSnapshot? {
        if let snapshot = volumeSnapshots[deviceID] { return snapshot }
        return volumes[deviceID].map { [0: $0] }
    }

    func setVolumes(_ snapshot: InputVolumeSnapshot, on deviceID: AudioDeviceID) -> Bool {
        for volume in snapshot.sorted(by: { $0.key < $1.key }).map(\.value) {
            setVolumeCalls.append(VolumeCall(volume: volume, deviceID: deviceID))
        }
        if let failures = volumeWriteFailuresRemaining[deviceID], failures > 0 {
            volumeWriteFailuresRemaining[deviceID] = failures - 1
            return false
        }
        guard volumeWritesSucceed else { return false }
        if deferVolumeWrites {
            deferredVolumeWrites[deviceID] = snapshot
            return true
        }
        applyVolumes(snapshot, on: deviceID)
        return true
    }

    func completeDeferredWrites() {
        for (deviceID, muted) in deferredMuteWrites { mutes[deviceID] = muted }
        deferredMuteWrites.removeAll()
        for (deviceID, snapshot) in deferredVolumeWrites { applyVolumes(snapshot, on: deviceID) }
        deferredVolumeWrites.removeAll()
    }

    private func applyVolumes(_ snapshot: InputVolumeSnapshot, on deviceID: AudioDeviceID) {
        if volumeSnapshots[deviceID] != nil || snapshot.keys.contains(where: { $0 != 0 }) {
            volumeSnapshots[deviceID] = snapshot
        }
        if let main = snapshot[0] {
            volumes[deviceID] = main
        }
    }

    func observeDefaultDeviceChanges(_ handler: @escaping @MainActor () -> Void) -> Bool {
        defaultDeviceChangeHandler = handler
        return true
    }

    func observeStateChanges(
        on deviceID: AudioDeviceID?,
        _ handler: @escaping @MainActor () -> Void
    ) -> Bool {
        stateChangeHandler = handler
        return true
    }

    func triggerDefaultDeviceChange() {
        defaultDeviceChangeHandler?()
    }

    func triggerStateChange() {
        stateChangeHandler?()
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
