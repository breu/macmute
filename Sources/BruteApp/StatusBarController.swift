import AppKit

/// The menu bar item and its live status menu.
@MainActor
final class StatusBarController {

    struct MicrophonePresentation: Equatable {
        let symbol: String
        let accessibilityDescription: String
        let menuTitle: String
    }

    let menu = NSMenu()
    private let statusItem: NSStatusItem?
    private let muteController: MicMuteController
    private let hotkeyManager: HotkeyManager
    private let actionController: MicrophoneActionController
    private let launchManager: LaunchAtLoginManaging
    private var preferencesWindowController: PreferencesWindowController?
    private var hotkeyObserver: NotificationObservation?
    private var microphoneStateLabel: NSTextField?
    private var hotkeyStateLabel: NSTextField?
    private var delayLabel: NSTextField?
    private var delayRow: NSView?

    init(
        statusItem: NSStatusItem?,
        muteController: MicMuteController,
        hotkeyManager: HotkeyManager,
        actionController: MicrophoneActionController,
        launchManager: LaunchAtLoginManaging
    ) {
        self.statusItem = statusItem
        self.muteController = muteController
        self.hotkeyManager = hotkeyManager
        self.actionController = actionController
        self.launchManager = launchManager
        configureMenu()
        muteController.onStateChanged = { [weak self] state in
            self?.updateMicrophoneState(state)
        }
        hotkeyObserver = NotificationObservation(
            center: .default,
            name: .bruteHotkeyRegistrationDidChange,
            object: hotkeyManager,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hotkeyObserver != nil else { return }
                self.updateHotkeyState()
            }
        }
        updateMicrophoneState(muteController.state)
        updateHotkeyState()
    }

    func shutdown() {
        guard hotkeyObserver != nil else { return }
        hotkeyObserver = nil
        muteController.onStateChanged = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func configureMenu() {
        menu.autoenablesItems = false

        microphoneStateLabel = addInformation(BruteStrings.microphoneState(BruteStrings.microphoneChecking), to: menu)
        hotkeyStateLabel = addInformation(BruteStrings.hotkey(BruteStrings.hotkeyInactive), to: menu)

        menu.addItem(NSMenuItem.separator())

        for title in [BruteStrings.tapHelp, BruteStrings.holdHelp, BruteStrings.releaseHelp] {
            addInformation(title, to: menu)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeDelaySliderItem())
        updateDelayLabel()
        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: BruteStrings.preferences, action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let helpItem = NSMenuItem(title: BruteStrings.help, action: #selector(openHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: BruteStrings.about, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: BruteStrings.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func makeLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        return label
    }

    private func makeDelaySliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let label = makeLabel("")
        label.setAccessibilityElement(false) // The slider announces this setting and its value.
        delayLabel = label

        let slider = NSSlider(
            value: actionController.holdThreshold,
            minValue: MicrophoneActionController.minimumDelay,
            maxValue: MicrophoneActionController.maximumDelay,
            target: self, action: #selector(changeHoldDelay(_:))
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityLabel(BruteStrings.delaySliderAccessibilityLabel)
        slider.toolTip = BruteStrings.delaySliderToolTip
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let content = NSStackView(views: [label, slider])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        let row = makeMenuRow(content, verticalPadding: 6)
        slider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        item.view = row
        delayRow = row
        return item
    }

    @discardableResult
    private func addInformation(_ title: String, to menu: NSMenu) -> NSTextField {
        let label = makeLabel(title)
        let item = NSMenuItem()
        let view = makeMenuRow(label, verticalPadding: 4)
        item.view = view
        label.setAccessibilityElement(false)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        menu.addItem(item)
        updateInformation(label, title: title)
        return label
    }

    private func updateInformation(_ label: NSTextField?, title: String) {
        guard let label else { return }
        label.stringValue = title
        if let row = label.superview {
            row.setAccessibilityLabel(title)
            row.setFrameSize(row.fittingSize)
        }
    }

    /// AppKit sizes custom menu rows by their frame. Derive that frame from the
    /// contents so the rows follow the system font and layout direction.
    private func makeMenuRow(_ content: NSView, verticalPadding: CGFloat) -> NSView {
        let row = NSView()
        row.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: verticalPadding),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -verticalPadding)
        ])
        return row
    }

    @objc private func changeHoldDelay(_ slider: NSSlider) {
        actionController.setHoldThreshold(slider.doubleValue)
        updateDelayLabel()
    }

    private func updateDelayLabel() {
        delayLabel?.stringValue = String(
            format: BruteStrings.delaySliderLabelFormat,
            actionController.holdThreshold
        )
        if let delayRow {
            delayRow.setFrameSize(delayRow.fittingSize)
        }
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                hotkeyManager: hotkeyManager,
                launchManager: launchManager
            )
        }
        preferencesWindowController?.show()
    }

    @objc private func openHelp() {
        guard let url = Bundle.main.url(forResource: "BruteHelp", withExtension: "html"),
              NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = BruteStrings.helpUnavailableTitle
            alert.informativeText = BruteStrings.helpUnavailableBody
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? BruteStrings.developmentVersion
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: BruteStrings.appName,
            .applicationVersion: version,
            .credits: NSAttributedString(string: BruteStrings.aboutCredits)
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateMicrophoneState(_ state: MicrophoneState) {
        let presentation = Self.presentation(for: state, error: muteController.lastError)
        statusItem?.button?.image = NSImage(
            systemSymbolName: presentation.symbol,
            accessibilityDescription: presentation.accessibilityDescription
        )
        statusItem?.button?.setAccessibilityLabel(presentation.accessibilityDescription)
        statusItem?.button?.toolTip = presentation.menuTitle
        updateInformation(microphoneStateLabel, title: presentation.menuTitle)
    }

    /// A hardware utility that only says "Unavailable" leaves the user guessing.
    /// `MicMuteController.lastError` carries the reason, and it reaches the menu the
    /// same way `HotkeyManager.lastRegistrationError` already does.
    static func presentation(for state: MicrophoneState, error: MicControlError? = nil) -> MicrophonePresentation {
        let reason = error?.localizedDescription
        switch state {
        case .muted:
            return MicrophonePresentation(
                symbol: "mic.slash.fill",
                accessibilityDescription: BruteStrings.microphoneMutedAccessibilityLabel,
                menuTitle: BruteStrings.microphoneState(BruteStrings.microphoneMuted, detail: reason)
            )
        case .unmuted:
            return MicrophonePresentation(
                symbol: "mic.fill",
                accessibilityDescription: BruteStrings.microphoneUnmutedAccessibilityLabel,
                menuTitle: BruteStrings.microphoneState(BruteStrings.microphoneUnmuted, detail: reason)
            )
        case .unavailable:
            return MicrophonePresentation(
                symbol: "exclamationmark.triangle.fill",
                accessibilityDescription: BruteStrings.microphoneUnavailableAccessibilityLabel,
                menuTitle: BruteStrings.microphoneState(reason ?? BruteStrings.microphoneUnavailable)
            )
        }
    }

    private func updateHotkeyState() {
        updateInformation(hotkeyStateLabel, title: Self.hotkeyTitle(
            error: hotkeyManager.lastRegistrationError,
            isActive: hotkeyManager.hasActiveRegistration
        ))
    }

    static func hotkeyTitle(error: HotkeyRegistrationError?, isActive: Bool) -> String {
        if let error { return BruteStrings.hotkey(error.localizedDescription) }
        return BruteStrings.hotkey(isActive ? BruteStrings.hotkeyActive : BruteStrings.hotkeyInactive)
    }
}
