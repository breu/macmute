import AppKit

@MainActor
final class StatusBarController {

    private let statusItem: NSStatusItem
    private let muteController = MicMuteController.shared
    private let pushToTalk = PushToTalkController.shared
    private var preferencesWindowController: PreferencesWindowController?
    private var pushToMuteItem: NSMenuItem?
    private var pushToUnmuteItem: NSMenuItem?
    private var statusMenu: NSMenu?
    private var microphoneStateItem: NSMenuItem?
    private var hotkeyStateItem: NSMenuItem?

    private let unmutedSymbol = "mic.fill"
    private let mutedSymbol = "mic.slash.fill"
    private let unavailableSymbol = "exclamationmark.triangle.fill"

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureButton()
        configureMenu()
        muteController.onStateChanged = { [weak self] state in
            self?.updateMicrophoneState(state)
        }
        pushToTalk.onModeChanged = { [weak self] _ in
            self?.updateModeMenuItemStates()
        }
        NotificationCenter.default.addObserver(
            forName: .macMuteHotkeyRegistrationDidChange,
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

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: unmutedSymbol, accessibilityDescription: "Microphone")
    }

    private func configureMenu() {
        let menu = NSMenu()

        let microphoneStateItem = NSMenuItem(title: "Microphone State: Checking…", action: nil, keyEquivalent: "")
        microphoneStateItem.isEnabled = false
        menu.addItem(microphoneStateItem)
        self.microphoneStateItem = microphoneStateItem

        let hotkeyStateItem = NSMenuItem(title: "Hotkey: Active", action: nil, keyEquivalent: "")
        hotkeyStateItem.isEnabled = false
        menu.addItem(hotkeyStateItem)
        self.hotkeyStateItem = hotkeyStateItem

        menu.addItem(NSMenuItem.separator())

        let modeHeader = NSMenuItem(title: "Hotkey Mode", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)

        let pushToMuteItem = NSMenuItem(title: "Push to Mute", action: #selector(selectPushToMute), keyEquivalent: "")
        pushToMuteItem.target = self
        menu.addItem(pushToMuteItem)
        self.pushToMuteItem = pushToMuteItem

        let pushToUnmuteItem = NSMenuItem(title: "Push to Unmute", action: #selector(selectPushToUnmute), keyEquivalent: "")
        pushToUnmuteItem.target = self
        menu.addItem(pushToUnmuteItem)
        self.pushToUnmuteItem = pushToUnmuteItem

        updateModeMenuItemStates()

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "Toggle Mute", action: #selector(toggleMute), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About MacMute", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit MacMute", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusMenu = menu
    }

    @objc private func toggleMute() {
        muteController.toggle()
    }

    @objc private func selectPushToMute() {
        pushToTalk.setMode(.pushToMute)
    }

    @objc private func selectPushToUnmute() {
        pushToTalk.setMode(.pushToUnmute)
    }

    private func updateModeMenuItemStates() {
        pushToMuteItem?.state = pushToTalk.mode == .pushToMute ? .on : .off
        pushToUnmuteItem?.state = pushToTalk.mode == .pushToUnmute ? .on : .off
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.show()
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacMute",
            .applicationVersion: version,
            .credits: NSAttributedString(string: "Mutes your Mac's system microphone system-wide, at the hardware level.\n\nWritten by Joe Breu.")
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateMicrophoneState(_ state: MicrophoneState) {
        let symbol: String
        let description: String
        let menuTitle: String
        switch state {
        case .muted:
            symbol = mutedSymbol
            description = "Microphone muted"
            menuTitle = "Microphone State: Muted"
        case .unmuted:
            symbol = unmutedSymbol
            description = "Microphone unmuted"
            menuTitle = "Microphone State: Unmuted"
        case .unavailable:
            symbol = unavailableSymbol
            description = "Microphone state unavailable"
            menuTitle = "Microphone State: Unavailable"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: description
        )
        microphoneStateItem?.title = menuTitle
    }

    private func updateHotkeyState() {
        if let error = HotkeyManager.shared.lastRegistrationError {
            hotkeyStateItem?.title = "Hotkey: \(error.localizedDescription)"
        } else {
            hotkeyStateItem?.title = "Hotkey: Active"
        }
    }
}
