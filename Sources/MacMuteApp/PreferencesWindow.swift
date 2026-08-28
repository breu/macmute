import AppKit
import Carbon.HIToolbox
import SwiftUI

final class PreferencesWindowController: NSWindowController {

    convenience init() {
        let view = PreferencesView()
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "MacMute Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 320, height: 190))
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct PreferencesView: View {
    @State private var shortcutDisplay = HotkeyManager.shared.currentShortcut.displayString
    @State private var isRecording = false
    @State private var launchAtLoginEnabled = LaunchAtLoginManager.shared.isEnabled

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
                    LaunchAtLoginManager.shared.setEnabled(newValue)
                }

            Spacer()
        }
        .padding(20)
        .frame(width: 320, height: 190)
    }

    private func startRecording() {
        isRecording = true
        recorder.record { shortcut in
            HotkeyManager.shared.updateShortcut(shortcut)
            shortcutDisplay = shortcut.displayString
            isRecording = false
        }
    }
}

/// Captures the next keyDown + modifier combination (or a standalone fn press)
/// within the app and converts it into a `KeyboardShortcut`.
private final class ShortcutRecorder {
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var fnKeyIsDown = false

    func record(completion: @escaping (KeyboardShortcut) -> Void) {
        fnKeyIsDown = false

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
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

    private func finish(with shortcut: KeyboardShortcut, completion: @escaping (KeyboardShortcut) -> Void) {
        completion(shortcut)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
    }
}
