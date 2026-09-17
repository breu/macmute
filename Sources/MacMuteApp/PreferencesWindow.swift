import AppKit
import Carbon.HIToolbox
import SwiftUI

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    private var recorder: ShortcutRecorder?

    convenience init() {
        let recorder = ShortcutRecorder()
        let view = PreferencesView(recorder: recorder)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "MacMute Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 320, height: 220))
        self.init(window: window)
        self.recorder = recorder
        window.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Abandons an in-progress recording rather than leaving its monitors
    /// installed app-wide after the window that started it is gone.
    func windowWillClose(_ notification: Notification) {
        recorder?.cancel()
    }
}

private struct PreferencesView: View {
    @State private var shortcutDisplay = HotkeyManager.shared.currentShortcut.displayString
    @State private var isRecording = false
    @State private var launchAtLoginEnabled = LaunchAtLoginManager.shared.isEnabled
    @State private var useColoredIcon = IconPreferences.shared.useColoredIcon

    let recorder: ShortcutRecorder

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
                    if !LaunchAtLoginManager.shared.setEnabled(newValue) {
                        // Registration/unregistration failed — resync the toggle
                        // to the actual system state rather than leaving it
                        // showing a change that never took effect.
                        launchAtLoginEnabled = LaunchAtLoginManager.shared.isEnabled
                    }
                }

            Toggle("Use Colored Icon", isOn: $useColoredIcon)
                .onChange(of: useColoredIcon) { newValue in
                    IconPreferences.shared.setUseColoredIcon(newValue)
                }

            Spacer()
        }
        .padding(20)
        .frame(width: 320, height: 220)
    }

    private func startRecording() {
        isRecording = true
        recorder.record { shortcut in
            if HotkeyManager.shared.updateShortcut(shortcut) {
                shortcutDisplay = shortcut.displayString
            } else {
                // Registration failed (conflict, or fn without Accessibility
                // trust) — the prior working shortcut is still active, so
                // leave the displayed label matching it rather than the
                // shortcut that didn't take effect.
                shortcutDisplay = HotkeyManager.shared.currentShortcut.displayString
            }
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
        // A still-active session from a prior click (or an unclosed one left
        // behind) would otherwise have its monitor references overwritten
        // here and leaked — installed forever, able to change the shortcut
        // out from under a later recording.
        cancel()
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
        cancel()
        completion(shortcut)
    }

    /// Removes any installed monitors without firing the completion — used both
    /// to guard against a leaked prior session and to abandon an in-progress
    /// recording (e.g. the preferences window closing) without applying it.
    func cancel() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
    }
}
