import AppKit
import Combine

/// The menu bar item and its live status menu.
@MainActor
final class StatusBarController {

    struct MicrophonePresentation: Equatable {
        let symbol: String
        let accessibilityDescription: String
        let menuTitle: String
        let tint: NSColor?

        func icon(useColoredIcon: Bool) -> NSImage? {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
            else { return nil }
            if useColoredIcon, let tint,
               let coloredImage = image.withSymbolConfiguration(.init(paletteColors: [tint])) {
                coloredImage.isTemplate = false
                return coloredImage
            }
            image.isTemplate = true
            return image
        }
    }

    let menu = NSMenu()
    private let statusItem: NSStatusItem?
    private let muteController: MicMuteController
    private let hotkeyManager: HotkeyManager
    private let actionController: MicrophoneActionController
    private let launchManager: LaunchAtLoginManaging
    private let iconPreferences: IconPreferences
    private var preferencesWindowController: PreferencesWindowController?
    private var hotkeyObserver: NotificationObservation?
    private var iconObservation: AnyCancellable?
    private var microphoneStateLabel: NSTextField?
    private var hotkeyStateLabel: NSTextField?
    private var doublePressWindowLabel: NSTextField?

    init(
        statusItem: NSStatusItem?,
        muteController: MicMuteController,
        hotkeyManager: HotkeyManager,
        actionController: MicrophoneActionController,
        launchManager: LaunchAtLoginManaging,
        iconPreferences: IconPreferences
    ) {
        self.statusItem = statusItem
        self.muteController = muteController
        self.hotkeyManager = hotkeyManager
        self.actionController = actionController
        self.launchManager = launchManager
        self.iconPreferences = iconPreferences
        configureMenu()
        muteController.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.updateMicrophoneState(state, useColoredIcon: self.iconPreferences.useColoredIcon)
        }
        iconObservation = iconPreferences.$useColoredIcon.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.updateMicrophoneState(self.muteController.state, useColoredIcon: enabled)
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
        updateMicrophoneState(muteController.state, useColoredIcon: iconPreferences.useColoredIcon)
        updateHotkeyState()
    }

    func shutdown() {
        guard hotkeyObserver != nil else { return }
        hotkeyObserver = nil
        iconObservation = nil
        muteController.onStateChanged = nil
        preferencesWindowController?.close()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func configureMenu() {
        menu.autoenablesItems = false

        microphoneStateLabel = addInformation(BruteStrings.microphoneState(BruteStrings.microphoneChecking), to: menu)
        hotkeyStateLabel = addInformation(BruteStrings.hotkey(BruteStrings.hotkeyInactive), to: menu)

        menu.addItem(NSMenuItem.separator())

        for title in [BruteStrings.pressShortcutHelp, BruteStrings.releaseShortcutHelp, BruteStrings.doubleTapShortcutHelp] {
            addInformation(title, to: menu)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeDoublePressWindowItem())
        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: BruteStrings.preferences, action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let helpItem = NSMenuItem(title: BruteStrings.help, action: #selector(openHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        let privacyItem = NSMenuItem(title: BruteStrings.privacyPolicy, action: #selector(openPrivacyPolicy), keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)

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

    private func makeDoublePressWindowItem() -> NSMenuItem {
        let item = NSMenuItem()
        let label = makeLabel(doublePressWindowTitle)
        label.setAccessibilityElement(false) // The slider announces the setting and its value.
        doublePressWindowLabel = label

        let slider = NSSlider(
            value: actionController.doublePressInterval,
            minValue: MicrophoneActionController.minimumDoublePressInterval,
            maxValue: MicrophoneActionController.maximumDoublePressInterval,
            target: self, action: #selector(changeDoublePressWindow(_:))
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityLabel(BruteStrings.doublePressWindowAccessibilityLabel)
        slider.setAccessibilityHelp(BruteStrings.doublePressWindowHelp)
        slider.toolTip = BruteStrings.doublePressWindowHelp
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let content = NSStackView(views: [label, slider])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        let row = makeMenuRow(content, verticalPadding: 6)
        slider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        row.setFrameSize(row.fittingSize)
        item.view = row
        return item
    }

    private var doublePressWindowTitle: String {
        String(format: BruteStrings.doublePressWindowLabelFormat, actionController.doublePressInterval)
    }

    @objc private func changeDoublePressWindow(_ slider: NSSlider) {
        actionController.setDoublePressInterval(slider.doubleValue)
        // AppKit does not support resizing a custom menu item while tracking.
        doublePressWindowLabel?.stringValue = doublePressWindowTitle
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

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                hotkeyManager: hotkeyManager,
                launchManager: launchManager,
                iconPreferences: iconPreferences
            )
        }
        preferencesWindowController?.show()
    }

    @objc private func openHelp() {
        openBundledDocument("BruteHelp", errorTitle: BruteStrings.helpUnavailableTitle, errorBody: BruteStrings.helpUnavailableBody)
    }

    @objc private func openPrivacyPolicy() {
        openBundledDocument(
            "BrutePrivacy",
            errorTitle: BruteStrings.privacyPolicyUnavailableTitle,
            errorBody: BruteStrings.privacyPolicyUnavailableBody
        )
    }

    private func openBundledDocument(_ name: String, errorTitle: String, errorBody: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "html"),
              NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = errorTitle
            alert.informativeText = errorBody
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

    private func updateMicrophoneState(_ state: MicrophoneState, useColoredIcon: Bool) {
        let presentation = Self.presentation(for: state, error: muteController.lastError)
        statusItem?.button?.image = presentation.icon(useColoredIcon: useColoredIcon)
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
                menuTitle: BruteStrings.microphoneState(BruteStrings.microphoneMuted, detail: reason),
                tint: .systemRed
            )
        case .unmuted:
            return MicrophonePresentation(
                symbol: "mic.fill",
                accessibilityDescription: BruteStrings.microphoneUnmutedAccessibilityLabel,
                menuTitle: BruteStrings.microphoneState(BruteStrings.microphoneUnmuted, detail: reason),
                tint: .systemGreen
            )
        case .unavailable:
            return MicrophonePresentation(
                symbol: "exclamationmark.triangle.fill",
                accessibilityDescription: BruteStrings.microphoneUnavailableAccessibilityLabel,
                menuTitle: BruteStrings.microphoneState(reason ?? BruteStrings.microphoneUnavailable),
                tint: nil
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
