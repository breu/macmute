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
    @State private var shortcutDisplay = HotkeyManager.shared.currentShortcut.displayString
    @State private var isRecording = false
    @State private var launchAtLoginEnabled = LaunchAtLoginManager.shared.isEnabled
    @State private var errorMessage: String?

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
                Button(isRecording ? "Press keys…" : shortcutDisplay) {
                    startRecording()
                }
                .frame(minWidth: 100)
            }

            Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { newValue in
                    switch LaunchAtLoginManager.shared.setEnabled(newValue) {
                    case .success(let actual):
                        errorMessage = nil
                        launchAtLoginEnabled = actual
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                        launchAtLoginEnabled = LaunchAtLoginManager.shared.isEnabled
                    }
                }

            if let errorMessage {
                Text(errorMessage)
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
            if let error = HotkeyManager.shared.lastRegistrationError {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startRecording() {
        isRecording = true
        errorMessage = nil
        recorder.record(
            completion: { shortcut in
                switch HotkeyManager.shared.updateShortcut(shortcut) {
                case .success:
                    shortcutDisplay = shortcut.displayString
                    errorMessage = nil
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
                isRecording = false
            },
            onCancel: {
                isRecording = false
            }
        )
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
