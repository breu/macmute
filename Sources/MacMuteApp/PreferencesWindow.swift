import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {

    convenience init() {
        let view = PreferencesView()
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "MacMute Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 360, height: 240))
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private struct PreferencesView: View {
    @StateObject private var model = PreferencesModel()
    @State private var isRecording = false

    @State private var recorder = ShortcutRecorder()

    private static let raptorIcon: NSImage? = {
        guard let path = Bundle.main.path(forResource: "RaptorIcon", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = Self.raptorIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text("MacMute").font(.headline)
                Spacer()
            }

            HStack {
                Text("Toggle Mute Shortcut:")
                Spacer()
                Button(isRecording ? "Press keys…" : model.shortcutDisplay) {
                    startRecording()
                }
                .frame(minWidth: 100)
            }

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.updateLaunchAtLogin($0) }
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
        .frame(width: 360, height: 240)
        .onDisappear {
            recorder.cancel()
            isRecording = false
        }
        .onAppear {
            model.refreshExternalState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macMuteHotkeyRegistrationDidChange)) { _ in
            model.refreshHotkeyState()
        }
    }

    private func startRecording() {
        isRecording = true
        model.hotkeyErrorMessage = nil
        recorder.record(
            completion: { shortcut in
                model.updateShortcut(shortcut)
                isRecording = false
            },
            onCancel: {
                isRecording = false
            }
        )
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

    init(
        launchManager: LaunchAtLoginManaging = LaunchAtLoginManager.shared,
        hotkeyManager: HotkeyManager = HotkeyManager.shared
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
final class ShortcutRecorder {
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var fnKeyIsDown = false

    func record(
        completion: @escaping (KeyboardShortcut) -> Void,
        onCancel: @escaping () -> Void
    ) {
        cancel()
        fnKeyIsDown = false

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.cancel()
                onCancel()
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
    }

    func cancel() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        fnKeyIsDown = false
    }

    private func finish(with shortcut: KeyboardShortcut, completion: @escaping (KeyboardShortcut) -> Void) {
        cancel()
        completion(shortcut)
    }
}
