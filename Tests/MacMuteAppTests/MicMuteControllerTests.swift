import CoreAudio
import Carbon.HIToolbox
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
    var setMuteCalls: [MuteCall] = []
    var setVolumeCalls: [VolumeCall] = []
    private let identifierPrefix: String

    private var defaultDeviceChangeHandler: (@MainActor () -> Void)?
    private var stateChangeHandler: (@MainActor () -> Void)?

    init(defaultDeviceID: AudioDeviceID?, identifierPrefix: String = UUID().uuidString) {
        self.defaultDeviceID = defaultDeviceID
        self.identifierPrefix = identifierPrefix
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID
    }

    func persistentIdentifier(for deviceID: AudioDeviceID) -> String {
        "\(identifierPrefix)-\(deviceID)"
    }

    func hasMuteProperty(on deviceID: AudioDeviceID) -> Bool {
        muteProperties.contains(deviceID)
    }

    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool {
        muteSettable
    }

    func readMute(on deviceID: AudioDeviceID) -> Bool? {
        mutes[deviceID]
    }

    func setMute(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        setMuteCalls.append(MuteCall(muted: muted, deviceID: deviceID))
        guard muteWritesSucceed else { return false }
        mutes[deviceID] = muted
        return true
    }

    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool {
        volumeSettable && volumes[deviceID] != nil
    }

    func readVolume(on deviceID: AudioDeviceID) -> Float32? {
        volumes[deviceID]
    }

    func setVolume(_ volume: Float32, on deviceID: AudioDeviceID) -> Bool {
        setVolumeCalls.append(VolumeCall(volume: volume, deviceID: deviceID))
        if let failures = volumeWriteFailuresRemaining[deviceID], failures > 0 {
            volumeWriteFailuresRemaining[deviceID] = failures - 1
            return false
        }
        guard volumeWritesSucceed else { return false }
        volumes[deviceID] = volume
        return true
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
