/// English copy for the menu, About panel and Preferences controls.
enum BruteStrings {
    static let appName = "Brute"

    static let microphoneStatePrefix = "Microphone State"
    static let hotkeyPrefix = "Hotkey"

    static let pressShortcutHelp = "Hold for 0.2 seconds to switch temporarily"
    static let releaseShortcutHelp = "Release a hold to restore the previous state"
    static let doubleTapShortcutHelp = "Tap twice quickly to switch permanently"
    static let doublePressWindowLabelFormat = "Double-press window: %.1f seconds"
    static let doublePressWindowAccessibilityLabel = "Double-press window in seconds"
    static let doublePressWindowHelp = "Maximum time between the releases of two short taps."

    static let preferences = "Preferences…"
    static let help = "Brute Help…"
    static let privacyPolicy = "Privacy Policy…"
    static let about = "About Brute"
    static let quit = "Quit Brute"

    static let hotkeyActive = "Active"
    static let hotkeyInactive = "Inactive"

    static let microphoneMuted = "Muted"
    static let microphoneUnmuted = "Unmuted"
    static let microphoneUnavailable = "Unavailable"
    static let microphoneChecking = "Checking…"
    static let microphoneMutedAccessibilityLabel = "Microphone muted"
    static let microphoneUnmutedAccessibilityLabel = "Microphone unmuted"
    static let microphoneUnavailableAccessibilityLabel = "Microphone state unavailable"
    static let developmentVersion = "Development"

    static let aboutCredits = """
    Mutes the current default input device for apps that use it. Apps that explicitly \
    select another input are outside Brute's control.

    Written by Joe Breu.
    """

    static let helpUnavailableTitle = "Brute Help could not be opened"
    static let helpUnavailableBody =
        "The bundled user guide is unavailable or no app can open HTML files."
    static let privacyPolicyUnavailableTitle = "The privacy policy could not be opened"
    static let privacyPolicyUnavailableBody =
        "The bundled privacy policy is unavailable or no app can open HTML files."

    static func microphoneState(_ value: String, detail: String? = nil) -> String {
        let title = "\(microphoneStatePrefix): \(value)"
        return detail.map { "\(title) — \($0)" } ?? title
    }

    static func hotkey(_ value: String) -> String {
        "\(hotkeyPrefix): \(value)"
    }
    static let preferencesWindowTitle = "Brute Preferences"
    static let recordingShortcut = "Press keys…"
    static let hotkeyShortcutLabel = "Hotkey Shortcut:"
    static let launchAtLoginLabel = "Launch at Login"
    static let useColoredIconLabel = "Use Colored Icon"
}
