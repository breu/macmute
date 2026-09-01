import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusBarController = StatusBarController()

        _ = PushToTalkController.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        PushToTalkController.shared.prepareForTermination()
    }
}
