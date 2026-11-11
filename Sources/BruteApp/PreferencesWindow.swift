import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let model: PreferencesModel
    let recorder = ShortcutRecorder()

    init(
        hotkeyManager: HotkeyManager,
        launchManager: LaunchAtLoginManaging,
        iconPreferences: IconPreferences
    ) {
        model = PreferencesModel(launchManager: launchManager, hotkeyManager: hotkeyManager)
        let view = PreferencesView(model: model, iconPreferences: iconPreferences, recorder: recorder)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = BruteStrings.preferencesWindowTitle
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 360, height: 276))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        model.refreshExternalState()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.cancel()
    }
}

@MainActor
private struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject var iconPreferences: IconPreferences
    @ObservedObject var recorder: ShortcutRecorder

    private let icon: NSImage? = PreferencesView.loadIcon()

    private static func loadIcon() -> NSImage? {
        guard let path = Bundle.main.path(forResource: "RaptorIcon", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(BruteStrings.appName).font(.headline)
                Spacer()
            }

            HStack {
                Text(BruteStrings.hotkeyShortcutLabel)
                Spacer()
                Button(recorder.isRecording ? BruteStrings.recordingShortcut : model.shortcutDisplay) {
                    model.hotkeyErrorMessage = nil
                    recorder.record(completion: model.updateShortcut)
                }
                .frame(minWidth: 100)
            }

            Toggle(
                BruteStrings.launchAtLoginLabel,
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.updateLaunchAtLogin($0) }
                )
            )

            Toggle(
                BruteStrings.useColoredIconLabel,
                isOn: Binding(
                    get: { iconPreferences.useColoredIcon },
                    set: { iconPreferences.setUseColoredIcon($0) }
                )
            )

            if let hotkeyErrorMessage = model.hotkeyErrorMessage {
                Text(hotkeyErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let launchErrorMessage = model.launchErrorMessage {
                Text(launchErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 360, height: 276)
        .onReceive(model.hotkeyRegistrationChanges) { _ in
            model.refreshHotkeyState()
        }
    }
}

@MainActor
final class PreferencesModel: ObservableObject {
    @Published var shortcutDisplay: String
    @Published var launchAtLoginEnabled: Bool
    @Published var hotkeyErrorMessage: String?
    @Published var launchErrorMessage: String?

    private let launchManager: LaunchAtLoginManaging
    private let hotkeyManager: HotkeyManager

    var hotkeyRegistrationChanges: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: .bruteHotkeyRegistrationDidChange, object: hotkeyManager)
    }

    init(
        launchManager: LaunchAtLoginManaging,
        hotkeyManager: HotkeyManager
    ) {
        self.launchManager = launchManager
        self.hotkeyManager = hotkeyManager
        shortcutDisplay = hotkeyManager.currentShortcut.displayString
        launchAtLoginEnabled = launchManager.isRequested
    }

    func refreshExternalState() {
        shortcutDisplay = hotkeyManager.currentShortcut.displayString
        refreshHotkeyState()
        launchAtLoginEnabled = launchManager.isRequested
        launchErrorMessage = launchManager.isRequested && !launchManager.isEnabled
            ? LaunchAtLoginError.requiresApproval.localizedDescription
            : nil
    }

    func refreshHotkeyState() {
        hotkeyErrorMessage = hotkeyManager.lastRegistrationError?.localizedDescription
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        switch hotkeyManager.updateShortcut(shortcut) {
        case .success:
            shortcutDisplay = shortcut.displayString
            hotkeyErrorMessage = nil
        case .failure(let error):
            hotkeyErrorMessage = error.localizedDescription
        }
    }

    func updateLaunchAtLogin(_ requested: Bool) {
        switch launchManager.setEnabled(requested) {
        case .success(let actual):
            launchErrorMessage = nil
            launchAtLoginEnabled = actual
        case .failure(let error):
            launchErrorMessage = error.localizedDescription
            launchAtLoginEnabled = launchManager.isRequested
        }
    }
}

/// Captures the next keyDown + modifier combination (or a standalone fn press)
/// within the app and converts it into a `KeyboardShortcut`.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var fnKeyIsDown = false

    func record(completion: @escaping (KeyboardShortcut) -> Void) {
        cancel()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.cancel()
                return nil
            }
            var carbonModifiers: UInt32 = 0
            if event.modifierFlags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
            if event.modifierFlags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

            let keyCode = UInt32(event.keyCode)
            guard carbonModifiers != 0 || KeyboardShortcut.standaloneFunctionKeyCodes.contains(keyCode) else {
                return event
            }

            let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: carbonModifiers)
            self?.finish(with: shortcut, completion: completion)
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let isFnDown = event.modifierFlags.contains(.function)
            if isFnDown && !self.fnKeyIsDown {
                self.finish(with: .fn, completion: completion)
            }
            self.fnKeyIsDown = isFnDown
            return event
        }

        guard keyMonitor != nil, flagsMonitor != nil else {
            cancel()
            return
        }
        isRecording = true
    }

    func cancel() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        fnKeyIsDown = false
        if isRecording { isRecording = false }
    }

    private func finish(with shortcut: KeyboardShortcut, completion: @escaping (KeyboardShortcut) -> Void) {
        cancel()
        completion(shortcut)
    }
}
