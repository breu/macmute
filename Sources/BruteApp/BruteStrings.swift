/// English copy for the menu, About panel and Preferences controls.
enum BruteStrings {
    static let appName = "Brute"

    static let microphoneStatePrefix = "Microphone State"
    static let hotkeyPrefix = "Hotkey"

    static let tapHelp = "Tap shortcut: switch mute/unmute permanently"
    static let holdHelp = "Hold shortcut: switch temporarily"
    static let releaseHelp = "Release hold: restore previous state"

    static let delaySliderLabelFormat = "Tap–hold delay: %.1f seconds (0.2–1.0)"
    static let delaySliderAccessibilityLabel = "Tap to hold delay in seconds"
    static let delaySliderToolTip = "0.2 to 1.0 seconds. Shorter presses toggle permanently."

    static let preferences = "Preferences…"
    static let help = "Brute Help…"
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
