import Foundation

/// Every `UserDefaults` key Brute reads or writes, in one place.
///
/// ## The `MacMute.` prefix is load-bearing — do not "modernize" it
///
/// These keys hold safety state:
///
/// - `savedInputVolumes` — the per-device input-volume baseline Brute restores
///   after muting a device that has no native mute control.
/// - `appMutedInputDevices` — the record that Brute, not the user, muted a device.
/// - `pendingInputStates` — device changes and restores still awaiting confirmation.
/// - `pendingInputVolumeRestorations` — the gain targets for active fallback restores.
///
/// If Brute is killed or crashes while it owns a mute, the next launch reads these
/// keys to recover ownership and finish pending restores. Deleting or renaming them orphans that record, and
/// a microphone can stay silent with nothing in the UI explaining why.
///
/// They also live in the container belonging to the `com.breu.macmute` bundle
/// identifier (kept so macOS and App Store Connect treat Brute as the same app as
/// MacMute). If that identifier is ever migrated to a Brute-domain identifier,
/// these keys must be copied into the new container as part of the migration —
/// reading them from a fresh container reads as "Brute owns nothing", which is the
/// worst possible default for a muting app.
enum BruteDefaults {
    static let savedInputVolumes = "MacMute.savedInputVolumes"
    static let appMutedInputDevices = "MacMute.appMutedInputDevices"
    static let pendingInputStates = "MacMute.pendingInputStates"
    static let pendingInputVolumeRestorations = "MacMute.pendingInputVolumeRestorations"
    static let shortcut = "MacMute.shortcut"
    static let tapHoldDelay = "MacMute.tapHoldDelay"
    static let useColoredIcon = "MacMute.useColoredIcon"
}
