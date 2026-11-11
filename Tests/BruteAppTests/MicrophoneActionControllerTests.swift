import Foundation
import XCTest
@testable import BruteApp

@MainActor
final class MicrophoneActionControllerTests: XCTestCase {
    func testWakeDuringHoldRestoresPriorMutedState() {
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
        gestureController.advanceHold()
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
        var gestureTime = 0.0
        let gestureController = MicrophoneActionController(
            micController: micController,
            feedback: nil,
            observesWake: false, now: { gestureTime }
        )

        gestureController.handleDown()
        gestureTime = 0.4
        gestureController.advanceHold()
        XCTAssertEqual(micController.state, .muted)
        gestureController.cancelActiveGesture()

        XCTAssertEqual(micController.state, .unmuted)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [true, false])
    }

    func testToggleReadsHardwareBeforeChoosingDirection() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        hardware.mutes[1] = true
        let actions = MicrophoneActionController(
            micController: controller, feedback: nil, observesWake: false
        )
        actions.handleDown()
        actions.handleUp()
        XCTAssertEqual(controller.state, .unmuted)
    }

    func testHoldRefreshesPriorStateBeforeRestoration() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let micController = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var gestureTime = 0.0
        let gestureController = MicrophoneActionController(
            micController: micController,
            feedback: nil,
            observesWake: false, now: { gestureTime }
        )

        hardware.mutes[1] = true
        gestureController.handleDown()
        gestureTime = 0.4
        gestureController.advanceHold()
        XCTAssertEqual(micController.state, .unmuted)
        gestureController.handleUp()

        XCTAssertEqual(micController.state, .muted)
    }

    func testTapAndHoldUseOneTimedGestureInBothDirections() {
        for prior in [false, true] {
            for duration in [0.399, 0.4, 0.8] {
                let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
                hardware.muteProperties.insert(1)
                hardware.mutes[1] = prior
                let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
                var time = 0.0
                let gesture = MicrophoneActionController(
                    micController: mic, feedback: nil, observesWake: false,
                    now: { time }
                )
                gesture.handleUp() // Orphan release must do nothing.
                gesture.handleDown()
                gesture.handleDown() // Repeat must neither write nor restart the clock.
                XCTAssertTrue(hardware.setMuteCalls.isEmpty)
                time = duration
                gesture.advanceHold()
                gesture.advanceHold()
                if duration >= 0.4 { XCTAssertEqual(mic.state.mutedValue, !prior) }
                gesture.handleUp()
                gesture.handleUp()
                XCTAssertEqual(mic.state.mutedValue, duration >= 0.4 ? prior : !prior)
                XCTAssertEqual(hardware.setMuteCalls.map(\.muted), duration >= 0.4 ? [!prior, prior] : [!prior])
            }
        }
    }

    // Lightweight source guard; keep the matched call spellings out of source comments.
    func testUserStateChangeExecutionContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/BruteApp")
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent != "MicMuteController.swift" {
                XCTAssertFalse(source.contains("hardware.setMute("), file.lastPathComponent)
                XCTAssertFalse(source.contains("hardware.setVolumes("), file.lastPathComponent)
            }
            XCTAssertFalse(source.contains(".setMuted("), file.lastPathComponent)
            for call in [".toggleMute(", ".beginTemporaryToggle(", ".endTemporaryToggle("] {
                let expected = file.lastPathComponent == "MicrophoneActionController.swift" ? 1 : 0
                XCTAssertEqual(source.components(separatedBy: call).count - 1, expected, file.lastPathComponent)
            }
        }
        let menu = try String(contentsOf: sources.appendingPathComponent("StatusBarController.swift"), encoding: .utf8)
        XCTAssertFalse(menu.contains(".handleDown("))
        XCTAssertFalse(menu.contains(".handleUp("))
    }

    func testFailedTapDoesNotRepeatAndNextGestureCanRetry() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let actions = MicrophoneActionController(micController: mic, feedback: nil, observesWake: false)
        hardware.muteWritesSucceed = false
        actions.handleDown()
        actions.handleUp()
        XCTAssertEqual(mic.state, .unmuted)
        hardware.muteWritesSucceed = true
        actions.handleUp()
        actions.advanceHold()
        XCTAssertEqual(mic.state, .unmuted)
        actions.handleDown()
        actions.handleUp()
        XCTAssertEqual(mic.state, .muted)
    }

    func testDelayPersistsAndChangesOnlyFutureGestures() {
        let defaults = UserDefaults(suiteName: "BruteDelayTests.\(UUID().uuidString)")!
        defer { defaults.removeObject(forKey: "MacMute.tapHoldDelay") }
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var time = 0.0
        let actions = MicrophoneActionController(
            micController: mic, feedback: nil, observesWake: false,
            defaults: defaults, now: { time }
        )
        XCTAssertEqual(actions.holdThreshold, 0.4)
        actions.handleDown()
        actions.setHoldThreshold(1.0)
        time = 0.4
        actions.advanceHold()
        XCTAssertEqual(mic.state, .muted)
        actions.handleUp()
        XCTAssertEqual(mic.state, .unmuted)
        actions.handleDown()
        time = 0.8
        actions.advanceHold()
        XCTAssertEqual(mic.state, .unmuted)
        actions.handleUp()
        XCTAssertEqual(mic.state, .muted)
        let reloaded = MicrophoneActionController(
            micController: mic, feedback: nil, observesWake: false, defaults: defaults
        )
        XCTAssertEqual(reloaded.holdThreshold, 1.0)
        reloaded.setHoldThreshold(0.1)
        XCTAssertEqual(reloaded.holdThreshold, 0.2)
        reloaded.setHoldThreshold(2.0)
        XCTAssertEqual(reloaded.holdThreshold, 1.0)
        reloaded.setHoldThreshold(0.53)
        XCTAssertEqual(reloaded.holdThreshold, 0.6)
        reloaded.setHoldThreshold(.nan)
        XCTAssertEqual(reloaded.holdThreshold, 0.4)
    }

    func testTwoQuickTapsToggleTwiceWithoutDelay() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gesture = MicrophoneActionController(micController: mic, feedback: nil, observesWake: false)
        gesture.handleDown()
        gesture.handleUp()
        XCTAssertEqual(mic.state, .muted)
        gesture.handleDown()
        gesture.handleUp()
        XCTAssertEqual(mic.state, .unmuted)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [true, false])
    }

    func testSecondTapReversesAcceptedUnmuteBeforeReadbackChanges() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        hardware.deferMuteWrites = true
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gesture = MicrophoneActionController(micController: mic, feedback: nil, observesWake: false)

        gesture.handleDown()
        gesture.handleUp()
        XCTAssertEqual(hardware.deferredMuteWrites[1], false)
        gesture.handleDown()
        gesture.handleUp()
        hardware.completeDeferredWrites()
        mic.refreshState()

        XCTAssertEqual(hardware.setMuteCalls.last?.muted, true)
        XCTAssertEqual(mic.state, .muted)
    }

    func testInputChangeEndsHoldOnItsOriginalDevice() {
        for prior in [true, false] {
            let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
            hardware.muteProperties = [1, 2]
            hardware.mutes = [1: prior, 2: !prior]
            let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
            var time = 0.0
            let gesture = MicrophoneActionController(
                micController: mic, feedback: nil, observesWake: false, now: { time }
            )

            gesture.handleDown()
            time = 0.5
            gesture.advanceHold()
            XCTAssertEqual(hardware.mutes[1], !prior)
            hardware.defaultDeviceID = 2
            mic.handleDefaultDeviceChange()
            gesture.handleUp()

            XCTAssertEqual(hardware.mutes[1], prior)
            XCTAssertEqual(hardware.mutes[2], !prior)
            XCTAssertFalse(hardware.setMuteCalls.contains { $0.deviceID == 2 })
        }
    }

    func testRejectedTemporaryMuteDoesNotUndoAnExternalMuteOnRelease() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.muteWritesSucceed = false
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var time = 0.0
        let gesture = MicrophoneActionController(
            micController: mic, feedback: nil, observesWake: false, now: { time }
        )

        gesture.handleDown()
        time = 0.5
        gesture.advanceHold()
        hardware.muteWritesSucceed = true
        hardware.mutes[1] = true
        gesture.handleUp()

        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [true])
        XCTAssertEqual(hardware.mutes[1], true)
    }

    func testLateReleaseClassifiesHoldEvenBeforeTimerRuns() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        var time = 0.0
        let gesture = MicrophoneActionController(
            micController: mic, feedback: nil, observesWake: false, now: { time }
        )
        gesture.handleDown()
        time = 0.4
        gesture.handleUp()
        XCTAssertEqual(mic.state, .muted)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [false, true])
    }

    func testQueuedEdgesUseTheirOriginalEventTimes() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = true
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gesture = MicrophoneActionController(
            micController: mic, feedback: nil, observesWake: false, now: { 1 }
        )

        gesture.handleDown(at: 0.1)
        gesture.handleUp(at: 0.6)

        XCTAssertEqual(mic.state, .muted)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [false, true])
    }

    func testCancelledShortPressDoesNotToggleAndNextTapWorks() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        let mic = MicMuteController(hardware: hardware, observeSystemChanges: false)
        let gesture = MicrophoneActionController(micController: mic, feedback: nil, observesWake: false)
        gesture.handleDown()
        gesture.cancelActiveGesture()
        gesture.handleUp()
        XCTAssertTrue(hardware.setMuteCalls.isEmpty)
        gesture.handleDown()
        gesture.handleUp()
        XCTAssertEqual(mic.state, .muted)
    }

    func testSyncBeforeGestureReadsCurrentDeviceState() {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = false
        hardware.volumes[1] = 0.5
        let controller = MicMuteController(hardware: hardware, observeSystemChanges: false)

        hardware.mutes[1] = true
        controller.syncBeforeGesture()

        XCTAssertEqual(controller.state, .muted)
    }
}
