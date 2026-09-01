import AppKit

@MainActor
final class StatusBarController {

    struct MicrophonePresentation: Equatable {
        let symbol: String
        let accessibilityDescription: String
        let menuTitle: String
    }

    struct ModePresentation: Equatable {
        let symbol: String
        let accessibilityDescription: String
    }

    private let statusItem: NSStatusItem
    private let muteController = MicMuteController.shared
    private let pushToTalk = PushToTalkController.shared
    private var preferencesWindowController: PreferencesWindowController?
    private var pushToMuteItem: NSMenuItem?
    private var pushToUnmuteItem: NSMenuItem?
    private var statusMenu: NSMenu?
    private var microphoneStateItem: NSMenuItem?
    private var hotkeyStateItem: NSMenuItem?
    private var modeIndicatorTimer: Timer?

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
        pushToTalk.onModeChanged = { [weak self] mode in
            self?.updateModeMenuItemStates()
            self?.showModeChange(mode)
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

    private func showModeChange(_ mode: HotkeyMode) {
        modeIndicatorTimer?.invalidate()
        let presentation = Self.modePresentation(for: mode)
        statusItem.button?.image = NSImage(
            systemSymbolName: presentation.symbol,
            accessibilityDescription: presentation.accessibilityDescription
        )

        let timer = Timer(timeInterval: 1.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.modeIndicatorTimer = nil
                self.updateMicrophoneState(self.muteController.state)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modeIndicatorTimer = timer
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
            .credits: NSAttributedString(string: "Mutes the current default input device for apps that use it. Apps that explicitly select another input are outside MacMute's control.\n\nWritten by Joe Breu.")
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateMicrophoneState(_ state: MicrophoneState) {
        let presentation = Self.presentation(for: state)
        if modeIndicatorTimer == nil {
            statusItem.button?.image = NSImage(
                systemSymbolName: presentation.symbol,
                accessibilityDescription: presentation.accessibilityDescription
            )
        }
        microphoneStateItem?.title = presentation.menuTitle
    }

    static func modePresentation(for mode: HotkeyMode) -> ModePresentation {
        switch mode {
        case .pushToMute:
            ModePresentation(
                symbol: "mic.slash.circle.fill",
                accessibilityDescription: "Hotkey mode changed to Push to Mute"
            )
        case .pushToUnmute:
            ModePresentation(
                symbol: "mic.circle.fill",
                accessibilityDescription: "Hotkey mode changed to Push to Unmute"
            )
        }
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
        hotkeyStateItem?.title = Self.hotkeyTitle(
            error: HotkeyManager.shared.lastRegistrationError,
            isActive: HotkeyManager.shared.hasActiveRegistration
        )
    }

    static func hotkeyTitle(error: HotkeyRegistrationError?, isActive: Bool) -> String {
        if let error { return "Hotkey: \(error.localizedDescription)" }
        return isActive ? "Hotkey: Active" : "Hotkey: Inactive"
    }
}
