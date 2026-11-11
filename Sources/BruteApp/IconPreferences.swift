import Combine
import Foundation

@MainActor
final class IconPreferences: ObservableObject {
    @Published private(set) var useColoredIcon: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        useColoredIcon = (defaults.object(forKey: BruteDefaults.useColoredIcon) as? Bool) ?? true
    }

    func setUseColoredIcon(_ enabled: Bool) {
        guard enabled != useColoredIcon else { return }
        defaults.set(enabled, forKey: BruteDefaults.useColoredIcon)
        useColoredIcon = enabled
    }
}
