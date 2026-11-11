import AppKit
import XCTest
@testable import BruteApp

@MainActor
final class StatusBarPresentationTests: XCTestCase {
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
    }

    func testGenericUnavailableKeepsShortTitleWhenNoReasonKnown() {
        let title = StatusBarController.presentation(for: .unavailable).menuTitle
        XCTAssertEqual(title, "Microphone State: Unavailable")
    }

    func testWriteFailurePreservesActualMicrophoneStateInMenu() {
        let presentation = StatusBarController.presentation(for: .unmuted, error: .writeFailed)

        XCTAssertEqual(presentation.symbol, "mic.fill")
        XCTAssertTrue(presentation.menuTitle.hasPrefix("Microphone State: Unmuted"))
        XCTAssertTrue(presentation.menuTitle.contains(MicControlError.writeFailed.localizedDescription))
    }

    func testStatusIconUsesMutedAndUnmutedColors() {
        XCTAssertEqual(StatusBarController.presentation(for: .muted).tint, .systemRed)
        XCTAssertEqual(StatusBarController.presentation(for: .unmuted).tint, .systemGreen)
    }

    func testIconPreferenceUpdatesStatusButtonAndSurvivesRelaunch() throws {
        _ = NSApplication.shared
        let suiteName = "BruteIconTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let iconPreferences = IconPreferences(defaults: defaults)
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.5
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = false
        let (statusBar, _) = makeStatusBar(hardware: hardware, statusItem: item, iconPreferences: iconPreferences)
        defer { statusBar.shutdown() }
        let button = try XCTUnwrap(item.button)

        XCTAssertTrue(iconPreferences.useColoredIcon)
        XCTAssertEqual(button.image?.isTemplate, false)

        iconPreferences.setUseColoredIcon(false)

        XCTAssertEqual(button.image?.isTemplate, true)
        XCTAssertEqual(defaults.object(forKey: "MacMute.useColoredIcon") as? Bool, false)
        XCTAssertFalse(IconPreferences(defaults: defaults).useColoredIcon)

        iconPreferences.setUseColoredIcon(true)
        XCTAssertEqual(button.image?.isTemplate, false)

        hardware.defaultDeviceID = nil
        hardware.triggerDefaultDeviceChange()
        XCTAssertEqual(button.image?.isTemplate, true, "Unavailable input should keep the warning symbol monochrome")
        XCTAssertEqual(button.accessibilityLabel(), "Microphone state unavailable")
    }

    func testMenuStateRowUpdatesWhenAnInputDeviceConnects() throws {
        let hardware = FakeAudioDeviceController(defaultDeviceID: nil)
        let (statusBar, _) = makeStatusBar(hardware: hardware)
        defer { statusBar.shutdown() }
        let stateRow = try XCTUnwrap(statusBar.menu.items.first?.view)
        XCTAssertEqual(stateRow.accessibilityRole(), .staticText)
        XCTAssertTrue(stateRow.accessibilityLabel()?.contains("No input device") == true)

        hardware.defaultDeviceID = 1
        hardware.volumes[1] = 0.5
        hardware.triggerDefaultDeviceChange()

        XCTAssertEqual(stateRow.accessibilityLabel(), "Microphone State: Unmuted")
        XCTAssertEqual((stateRow.subviews.first as? NSTextField)?.stringValue, stateRow.accessibilityLabel())
        XCTAssertGreaterThan(stateRow.frame.width, 0)
    }

    func testMenuSliderUpdatesFutureGesturesWithoutWritingMicrophoneState() throws {
        let hardware = FakeAudioDeviceController(defaultDeviceID: 1)
        hardware.volumes[1] = 0.5
        let (statusBar, actions) = makeStatusBar(hardware: hardware)
        defer { statusBar.shutdown() }
        let stack = try XCTUnwrap(
            statusBar.menu.items.compactMap { $0.view?.subviews.first as? NSStackView }.first
        )
        let slider = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSSlider }.first)
        let label = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(slider.accessibilityLabel(), "Tap to hold delay in seconds")
        XCTAssertEqual(slider.doubleValue, 0.4)

        slider.doubleValue = 0.8
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))

        XCTAssertEqual(actions.holdThreshold, 0.8)
        XCTAssertTrue(label.stringValue.contains("0.8 seconds"))
        XCTAssertTrue(hardware.setMuteCalls.isEmpty)
        XCTAssertTrue(hardware.setVolumeCalls.isEmpty)
    }

    private func makeStatusBar(
        hardware: FakeAudioDeviceController,
        statusItem: NSStatusItem? = nil,
        iconPreferences: IconPreferences? = nil
    ) -> (StatusBarController, MicrophoneActionController) {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "BruteStatusBarTests.\(UUID().uuidString)")!
        let mic = MicMuteController(hardware: hardware, defaults: defaults)
        let hotkey = HotkeyManager(
            defaults: defaults,
            observesWake: false,
            installHandlerOverride: { .success(()) },
            registrationOverride: { _ in .success(()) }
        )
        let actions = MicrophoneActionController(micController: mic, feedback: nil, observesWake: false)
        let statusBar = StatusBarController(
            statusItem: statusItem,
            muteController: mic,
            hotkeyManager: hotkey,
            actionController: actions,
            launchManager: LaunchAtLoginManager(),
            iconPreferences: iconPreferences ?? IconPreferences(defaults: defaults)
        )
        return (statusBar, actions)
    }
}
