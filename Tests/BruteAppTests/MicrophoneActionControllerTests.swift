import Carbon.HIToolbox
import Foundation
import XCTest
@testable import BruteApp

@MainActor
final class MicrophoneActionControllerTests: XCTestCase {
    func testSinglePressFlipsImmediatelyAndReleaseRestoresInBothDirections() {
        for prior in [false, true] {
            let (hardware, mic) = makeMicrophone(muted: !prior)
            let actions = makeActions(for: mic)
            // The key-down must use the actual input state, including an external change.
            hardware.mutes[1] = prior

            actions.handleUp(at: 0.5) // Orphan release.
            actions.handleDown(at: 1)
            actions.handleDown(at: 1.1) // Auto-repeat.
            XCTAssertEqual(mic.state.mutedValue, !prior)
            XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [!prior])

            actions.handleUp(at: 3)
            actions.handleUp(at: 3.1)
            XCTAssertEqual(mic.state.mutedValue, prior)
            XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [!prior, prior])
        }
    }

    func testDoublePressSticksInBothDirectionsAtTheWindowBoundary() {
        for prior in [false, true] {
            let (hardware, mic) = makeMicrophone(muted: prior)
            let actions = makeActions(for: mic)

            actions.handleDown(at: 1)
            XCTAssertEqual(mic.state.mutedValue, !prior)
            actions.handleUp(at: 1.125)
            XCTAssertEqual(mic.state.mutedValue, prior)
            actions.handleDown(at: 1.25)
            XCTAssertEqual(mic.state.mutedValue, !prior)
            actions.handleUp(at: 1.125 + actions.doublePressInterval)
            XCTAssertEqual(mic.state.mutedValue, !prior)
            XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [!prior, prior, !prior])
        }
    }

    func testBothPressesAndTheGapBetweenReleasesMustBeQuick() {
        let sequences: [(firstUp: TimeInterval, secondDown: TimeInterval, secondUp: TimeInterval)] = [
            (1.125, 1.75, 1.875), // Paused before pressing again.
            (1.125, 1.25, 1.75), // Second release falls outside the pair window.
            (1.625, 1.75, 1.875), // Held the first press.
            (1.125, 1.25, 1.875), // Held the second press.
        ]
        for sequence in sequences {
            let (hardware, mic) = makeMicrophone(muted: true)
            let actions = makeActions(for: mic)

            actions.handleDown(at: 1)
            actions.handleUp(at: sequence.firstUp)
            actions.handleDown(at: sequence.secondDown)
            XCTAssertEqual(mic.state, .unmuted)
            actions.handleUp(at: sequence.secondUp)
            XCTAssertEqual(mic.state, .muted)
            XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [false, true, false, true], "\(sequence)")
        }
    }

    func testTimingUsesTheSavedSliderValueAndPersistsChanges() throws {
        let (_, mic) = makeMicrophone(muted: false)
        let suiteName = "BruteTimingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.8, forKey: "MacMute.tapHoldDelay")
        let actions = MicrophoneActionController(
            micController: mic, feedback: nil, observesWake: false, defaults: defaults
        )
        XCTAssertEqual(actions.doublePressInterval, 0.8)

        actions.setDoublePressInterval(0.53)
        XCTAssertEqual(actions.doublePressInterval, 0.6)
        let reloaded = MicrophoneActionController(
            micController: mic, feedback: nil, observesWake: false, defaults: defaults
        )
        XCTAssertEqual(reloaded.doublePressInterval, 0.6)

        reloaded.setDoublePressInterval(0.1)
        XCTAssertEqual(reloaded.doublePressInterval, 0.2)
        reloaded.setDoublePressInterval(2)
        XCTAssertEqual(reloaded.doublePressInterval, 1.0)
        reloaded.setDoublePressInterval(.nan)
        XCTAssertEqual(reloaded.doublePressInterval, 0.4)
    }

    func testTimingChangeAppliesToTheNextPair() {
        let (hardware, mic) = makeMicrophone(muted: true)
        let actions = makeActions(for: mic)
        actions.setDoublePressInterval(0.8)

        actions.handleDown(at: 1)
        XCTAssertEqual(mic.state, .unmuted)
        actions.setDoublePressInterval(0.2)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [false])
        actions.handleUp(at: 1.5)
        XCTAssertEqual(mic.state, .muted)
        actions.handleDown(at: 1.625)
        actions.handleUp(at: 1.9375)
        XCTAssertEqual(mic.state, .unmuted)

        actions.handleDown(at: 3)
        actions.handleUp(at: 3.0625)
        actions.handleDown(at: 3.25)
        XCTAssertEqual(mic.state, .muted)
        actions.handleUp(at: 3.3125)
        XCTAssertEqual(mic.state, .unmuted)
    }

    func testConsecutiveDoublePressesDoNotOverlap() {
        let (hardware, mic) = makeMicrophone(muted: true)
        let actions = makeActions(for: mic)

        for start in [1.0, 1.125, 1.25, 1.375] {
            actions.handleDown(at: start)
            actions.handleUp(at: start + 0.0625)
            XCTAssertEqual(mic.state, start == 1.125 || start == 1.25 ? .unmuted : .muted)
        }
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [false, true, false, true, false, true])
    }

    func testWakeDuringSecondPressRestoresWithoutCommitting() {
        let (hardware, mic) = makeMicrophone(muted: true)
        let actions = makeActions(for: mic)

        actions.handleDown(at: 1)
        actions.handleUp(at: 1.125)
        actions.handleDown(at: 1.25)
        XCTAssertEqual(mic.state, .unmuted)

        actions.handleWake()
        actions.handleUp(at: 1.375)
        XCTAssertEqual(mic.state, .muted)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [false, true, false, true])
    }

    func testShortcutReplacementDiscardsFirstTapWhileKeyIsUp() throws {
        let (hardware, mic) = makeMicrophone(muted: true)
        let suiteName = "BruteShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hotkey = HotkeyManager(
            defaults: defaults, observesWake: false,
            installHandlerOverride: { .success(()) }, registrationOverride: { _ in .success(()) }
        )
        defer { hotkey.shutdown() }
        var time = 1.0
        let actions = MicrophoneActionController(
            micController: mic, hotkeyManager: hotkey, feedback: nil,
            observesWake: false, now: { time }
        )
        try withExtendedLifetime(actions) {
            hotkey.handleHotkeyEdge(isDown: true)
            time = 1.125
            hotkey.handleHotkeyEdge(isDown: false)
            var replacement = KeyboardShortcut.default
            replacement.modifiers |= UInt32(controlKey)
            try hotkey.updateShortcut(replacement).get()
            time = 1.25
            hotkey.handleHotkeyEdge(isDown: true)
            XCTAssertEqual(mic.state, .unmuted)
            time = 1.375
            hotkey.handleHotkeyEdge(isDown: false)
            XCTAssertEqual(mic.state, .muted)
        }
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [false, true, false, true])
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
            for call in [".beginTemporaryToggle(", ".endTemporaryToggle(", ".commitTemporaryToggle("] {
                let expected = file.lastPathComponent == "MicrophoneActionController.swift" ? 1 : 0
                XCTAssertEqual(source.components(separatedBy: call).count - 1, expected, file.lastPathComponent)
            }
        }
        let menu = try String(contentsOf: sources.appendingPathComponent("StatusBarController.swift"), encoding: .utf8)
        XCTAssertFalse(menu.contains(".handleDown("))
        XCTAssertFalse(menu.contains(".handleUp("))
    }

    func testFailedPressDoesNotRepeatOrArmTheDoublePress() {
        let (hardware, mic) = makeMicrophone(muted: false)
        let actions = makeActions(for: mic)
        hardware.muteWritesSucceed = false
        actions.handleDown(at: 1)
        hardware.muteWritesSucceed = true
        actions.handleDown(at: 1.0625)
        actions.handleUp(at: 1.125)
        XCTAssertEqual(mic.state, .unmuted)
        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [true])

        actions.handleDown(at: 1.25)
        XCTAssertEqual(mic.state, .muted)
        actions.handleUp(at: 1.375)
        XCTAssertEqual(mic.state, .unmuted)
    }

    func testDoublePressKeepsItsTargetWhenReadbackIsDeferred() {
        let (hardware, mic) = makeMicrophone(muted: true)
        let actions = makeActions(for: mic)
        hardware.deferMuteWrites = true

        actions.handleDown(at: 1)
        actions.handleUp(at: 1.125)
        XCTAssertEqual(hardware.deferredMuteWrites[1], true)
        actions.handleDown(at: 1.25)
        actions.handleUp(at: 1.375)
        XCTAssertEqual(hardware.deferredMuteWrites[1], false)
        hardware.completeDeferredWrites()
        mic.refreshState()

        XCTAssertEqual(mic.state, .unmuted)
    }

    func testInputChangeEndsPressOnItsOriginalDevice() {
        for prior in [false, true] {
            let (hardware, mic) = makeMicrophone(muted: prior)
            hardware.muteProperties.insert(2)
            hardware.mutes[2] = !prior
            let actions = makeActions(for: mic)

            actions.handleDown(at: 1)
            XCTAssertEqual(hardware.mutes[1], !prior)
            hardware.defaultDeviceID = 2
            mic.handleDefaultDeviceChange()
            actions.handleUp(at: 1.125)

            XCTAssertEqual(hardware.mutes[1], prior)
            XCTAssertEqual(hardware.mutes[2], !prior)
            XCTAssertFalse(hardware.setMuteCalls.contains { $0.deviceID == 2 })
        }
    }

    func testPressesAcrossAnInputChangeDoNotFormAPair() {
        let (hardware, mic) = makeMicrophone(muted: true)
        hardware.muteProperties.insert(2)
        hardware.mutes[2] = true
        let actions = makeActions(for: mic)

        actions.handleDown(at: 1)
        actions.handleUp(at: 1.125)
        hardware.defaultDeviceID = 2
        actions.handleDown(at: 1.25)
        XCTAssertEqual(hardware.mutes[2], false)
        actions.handleUp(at: 1.375)

        XCTAssertEqual(hardware.mutes[1], true)
        XCTAssertEqual(hardware.mutes[2], true)
    }

    func testRejectedTemporaryMuteDoesNotUndoAnExternalMuteOnRelease() {
        let (hardware, mic) = makeMicrophone(muted: false)
        let actions = makeActions(for: mic)
        hardware.muteWritesSucceed = false

        actions.handleDown(at: 1)
        hardware.muteWritesSucceed = true
        hardware.mutes[1] = true
        actions.handleUp(at: 1.125)

        XCTAssertEqual(hardware.setMuteCalls.map(\.muted), [true])
        XCTAssertEqual(hardware.mutes[1], true)
    }

    private func makeMicrophone(muted: Bool) -> (FakeAudioDeviceController, MicMuteController) {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.muteProperties.insert(1)
        hardware.mutes[1] = muted
        return (hardware, MicMuteController(hardware: hardware, observeSystemChanges: false))
    }

    private func makeActions(for mic: MicMuteController) -> MicrophoneActionController {
        // Simulate queued native events so classification must use their original timestamps.
        MicrophoneActionController(
            micController: mic, feedback: nil, observesWake: false,
            now: { 10 }
        )
    }
}
