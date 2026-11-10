import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusBarController = StatusBarController(
            statusItem: NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength),
            muteController: .shared,
            hotkeyManager: .shared,
            actionController: .shared,
            launchManager: LaunchAtLoginManager.shared
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
