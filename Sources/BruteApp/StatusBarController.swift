import AppKit

@MainActor
final class StatusBarController {

    struct MicrophonePresentation: Equatable {
        let symbol: String
        let accessibilityDescription: String
        let menuTitle: String
    }

    private let statusItem: NSStatusItem
    private let muteController = MicMuteController.shared
    private var preferencesWindowController: PreferencesWindowController?
    private var microphoneStateLabel: NSTextField?
    private var hotkeyStateLabel: NSTextField?
    private var delayLabel: NSTextField?


    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureMenu()
        muteController.onStateChanged = { [weak self] state in
            self?.updateMicrophoneState(state)
        }
        NotificationCenter.default.addObserver(
            forName: .bruteHotkeyRegistrationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateHotkeyState()
            }
        }
        updateMicrophoneState(muteController.state)
        updateHotkeyState()
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)

        microphoneStateLabel = addInformation("Microphone State: Checking…", to: menu)
        hotkeyStateLabel = addInformation("Hotkey: Active", to: menu)

        menu.addItem(NSMenuItem.separator())

        for title in [
            "Tap shortcut: switch mute/unmute permanently",
            "Hold shortcut: switch temporarily",
            "Release hold: restore previous state"
        ] {
            addInformation(title, to: menu)
        }

        menu.addItem(NSMenuItem.separator())

        let delayItem = NSMenuItem()
        let delayView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 66))
        let label = makeLabel("")
        label.frame = NSRect(x: 20, y: 39, width: 300, height: 20)
        delayView.addSubview(label)
        delayLabel = label

        let slider = NSSlider(
            value: MicrophoneActionController.shared.holdThreshold,
            minValue: 0.2, maxValue: 1.0,
            target: self, action: #selector(changeHoldDelay(_:))
        )
        slider.frame = NSRect(x: 20, y: 10, width: 300, height: 24)
        slider.isContinuous = true
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityLabel("Tap to hold delay in seconds")
        slider.toolTip = "0.2 to 1.0 seconds. Shorter presses toggle permanently."
        delayView.addSubview(slider)
        delayItem.view = delayView
        menu.addItem(delayItem)
        updateDelayLabel()
        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let helpItem = NSMenuItem(title: "Brute Help…", action: #selector(openHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About Brute", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Brute", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        for item in menu.items where !item.isSeparatorItem && item.view == nil {
            item.isEnabled = true
            item.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.foregroundColor: NSColor.white, .font: NSFont.menuFont(ofSize: 0)]
            )
        }

        statusItem.menu = menu
    }

    private func makeLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.textColor = .white
        label.font = .menuFont(ofSize: 0)
        return label
    }

    @discardableResult
    private func addInformation(_ title: String, to menu: NSMenu) -> NSTextField {
        let label = makeLabel(title)
        let item = NSMenuItem()
        let view = NSView()
        view.addSubview(label)
        item.view = view
        menu.addItem(item)
        updateInformation(label, title: title)
        return label
    }

    private func updateInformation(_ label: NSTextField?, title: String) {
        guard let label else { return }
        label.stringValue = title
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 20, y: 4)
        label.superview?.setFrameSize(NSSize(width: label.frame.width + 40, height: label.frame.height + 8))
    }

    @objc private func changeHoldDelay(_ slider: NSSlider) {
        MicrophoneActionController.shared.setHoldThreshold(slider.doubleValue)
        updateDelayLabel()
    }

    private func updateDelayLabel() {
        delayLabel?.stringValue = String(
            format: "Tap–hold delay: %.1f seconds (0.2–1.0)",
            MicrophoneActionController.shared.holdThreshold
        )
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.show()
    }

    @objc private func openHelp() {
        guard let url = Bundle.main.url(forResource: "BruteHelp", withExtension: "html"),
              NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "Brute Help could not be opened"
            alert.informativeText = "The bundled user guide is unavailable or no app can open HTML files."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Brute",
            .applicationVersion: version,
            .credits: NSAttributedString(string: "Mutes the current default input device for apps that use it. Apps that explicitly select another input are outside Brute's control.\n\nWritten by Joe Breu.")
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateMicrophoneState(_ state: MicrophoneState) {
        let presentation = Self.presentation(for: state)
        statusItem.button?.image = NSImage(
            systemSymbolName: presentation.symbol,
            accessibilityDescription: presentation.accessibilityDescription
        )
        updateInformation(microphoneStateLabel, title: presentation.menuTitle)
    }

    static func presentation(for state: MicrophoneState) -> MicrophonePresentation {
        switch state {
        case .muted:
            MicrophonePresentation(
                symbol: "mic.slash.fill",
                accessibilityDescription: "Microphone muted",
                menuTitle: "Microphone State: Muted"
            )
        case .unmuted:
            MicrophonePresentation(
                symbol: "mic.fill",
                accessibilityDescription: "Microphone unmuted",
                menuTitle: "Microphone State: Unmuted"
            )
        case .unavailable:
            MicrophonePresentation(
                symbol: "exclamationmark.triangle.fill",
                accessibilityDescription: "Microphone state unavailable",
                menuTitle: "Microphone State: Unavailable"
            )
        }
    }

    private func updateHotkeyState() {
        updateInformation(hotkeyStateLabel, title: Self.hotkeyTitle(
            error: HotkeyManager.shared.lastRegistrationError,
            isActive: HotkeyManager.shared.hasActiveRegistration
        ))
    }

    static func hotkeyTitle(error: HotkeyRegistrationError?, isActive: Bool) -> String {
        if let error { return "Hotkey: \(error.localizedDescription)" }
        return isActive ? "Hotkey: Active" : "Hotkey: Inactive"
    }
}
