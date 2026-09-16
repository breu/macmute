import Foundation

/// Whether the menu bar icon is tinted green/red for mute state, or left as a
/// black-and-white template icon that adapts to the menu bar's light/dark theme.
final class IconPreferences {

    static let shared = IconPreferences()

    private static let defaultsKey = "MacMute.useColoredIcon"

    var onChange: (() -> Void)?

    private(set) var useColoredIcon: Bool

    private init() {
        // Absent key means first launch, which should default to colored — not
        // UserDefaults.bool(forKey:)'s false default for a missing key.
        useColoredIcon = (UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool) ?? true
    }

    func setUseColoredIcon(_ value: Bool) {
        guard value != useColoredIcon else { return }
        useColoredIcon = value
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
        onChange?()
    }
}
