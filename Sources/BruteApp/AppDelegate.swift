import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = MicrophoneActionController.shared

        statusBarController = StatusBarController(
            statusItem: NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength),
            muteController: .shared,
            hotkeyManager: .shared,
            launchManager: LaunchAtLoginManager.shared,
            iconPreferences: IconPreferences(defaults: .standard)
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        MicrophoneActionController.shared.prepareForTermination()
        statusBarController?.shutdown()
        statusBarController = nil
        HotkeyManager.shared.shutdown()
        MicMuteController.shared.shutdown()
        ClickSoundPlayer.shared.shutdown()
    }
}
