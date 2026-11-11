# Brute

Brute is a macOS menu bar utility that mutes the current default input device. Apps using that microphone share its mute state. An app that explicitly selects another microphone is unaffected. Brute does not record or transmit audio.

Requires macOS 13 or later. The app has no Dock icon or main window; look for the microphone icon in the menu bar.

## Using Brute

The default shortcut is **Option–Command–M (⌥⌘M)**.

- **Hold.** Keep the shortcut down for 0.2 seconds to switch the microphone temporarily. Release it to restore the previous state.
- **Tap twice.** Press and release the shortcut twice, keeping each press shorter than 0.2 seconds. The microphone switches and stays switched when the second release is within the double-press window.

Use the menu’s **Double-press window** slider to set the maximum time between the two releases. Choose **0.2, 0.4, 0.6, 0.8, or 1.0 seconds**. The default is **0.4 seconds**. A single short tap leaves the microphone in its current state.

The menu bar icon shows the microphone’s current state, including temporary changes during a hold. The menu shows microphone state, hotkey status, gesture help, and shortcuts to Preferences, Brute Help, the privacy policy, and About Brute. The menu follows the system appearance. Preferences lets you change the shortcut and enable Launch at Login. The standalone **fn** shortcut requires permission in **System Settings → Privacy & Security → Input Monitoring**.

**Brute Help…** opens the bundled [user guide](Resources/BruteHelp.html) offline in the system’s HTML viewer, normally a browser. This HTML file is the single source of user documentation and is included in Xcode builds and shell-built app bundles. Xcode’s generated Swift documentation is developer documentation and is separate from the user guide.

On launch, Brute reads the current microphone state and may finish a pending change or restore an interrupted hold. When the default input changes, Brute restores a hold on its original device. Outside a hold, Brute carries an active mute to the new default. When Brute cannot verify or change the microphone state, the menu explains what happened.

## State-change contract

`MicrophoneActionController` handles shortcut presses, releases, and double taps. `MicMuteController` applies the toggle and keeps temporary restoration tied to the original input.

`MicMuteController` owns device transfers, pending state changes, and restoration retries. Hardware writes converge on its `applyMute` implementation. It uses a writable native mute property or, where necessary, zeroes input volume and restores the per-device baseline. Readback determines the displayed microphone state. An accepted write whose effect is delayed remains pending for confirmation.

Regression coverage includes the single-write-boundary source contract, double-tap timing, duplicate events, cancellation, delayed readback, restoration, and device identity handling.

## Build and run with Xcode

Building from source requires Swift 6 or later, included in Xcode 16 and later.

Open `Brute.xcodeproj` and select the shared **Brute** scheme.

- **Product → Run** builds and launches the app.
- **Product → Test** runs the native test target.
- **Product → Archive** creates an archive for distribution.

Brute retains the `com.breu.macmute` bundle identifier so macOS and App Store Connect recognize it as the same app. The app target uses macOS 13.0, automatic signing with Breu Software LLC’s team (`6Q66ZYGK4J`), hardened runtime, and the Utilities category. Debug and Release use `Resources/Brute.entitlements`, enabling App Sandbox and Core Audio input access. Xcode bundles the help and privacy policy and generates the icon from `Resources/RaptorIcon.png`.

Update the marketing and build versions in `Resources/Version.xcconfig`. Xcode and the shell packaging scripts read both values from this file. Brute also retains the legacy `MacMute.*` defaults keys to preserve saved shortcuts and microphone restoration data across upgrades.

For App Store distribution, use the App Store distribution workflow in Organizer. An entitlement configuration or successful local build does not establish upload acceptance or sandboxed runtime behavior. See [publication checks](PUBLICATION.md).

## Shell builds and direct distribution

Install Swift 6 capable Xcode Command Line Tools with `xcode-select --install` if needed.

```sh
./Scripts/build_app.sh
open Brute.app
```

The script builds the universal Apple Silicon/Intel `BruteApp` release executable, assembles the app and its resources, and signs it ad hoc for local development. This build runs outside the App Sandbox.

To create a local installation disk image:

```sh
./Scripts/build_dmg.sh
```

Open `Brute-<version>.dmg` and drag Brute into Applications. A stable installation location is recommended for Launch at Login.

Run the regression suite with:

```sh
swift test
```

For strict concurrency and release coverage validation:

```sh
bash Scripts/check_release.sh
```

The coverage script enforces an overall floor and separate floors for critical files. CI runs this same check, a strict SwiftPM release build, Xcode build and tests, and ShellCheck on the packaging scripts.

## Developer ID release packaging

The shell release pipeline is for direct distribution, using a Breu Software LLC **Developer ID Application** certificate and Apple notarization. It does not create an App Store submission.

Store notarization credentials in Keychain with `xcrun notarytool store-credentials`, then supply the exact signing identity and saved profile:

```sh
export BRUTE_RELEASE=1
export BRUTE_SIGNING_IDENTITY='Developer ID Application: Breu Software LLC (6Q66ZYGK4J)'
export BRUTE_NOTARY_PROFILE='breusoftware-notary'
./Scripts/build_dmg.sh
```

The profile name is an example; use the one saved in your Keychain. `Resources/BreuSoftwareTeamID.txt` pins the team. If supplied, `BRUTE_TEAM_ID` must match it.

The scripts accept the legacy `MACMUTE_` variables when the corresponding `BRUTE_` variables are unset or empty.

Release mode requires clean release inputs, runs strict tests and coverage checks, builds universal output, embeds the source revision, and verifies signing. The DMG pipeline submits for notarization, staples and validates the result, inspects the mounted installer, and performs Gatekeeper assessment before replacing local output artifacts. It does not upload a public download or publish an App Store listing.

See [publication checks](PUBLICATION.md) for completed implementation and remaining verification.

## Privacy policy

Breu Software LLC does not receive data from the Brute app. Brute has no accounts, ads, analytics, or tracking.

Brute reads and changes the default microphone’s mute or input gain. It does not record, store, or transmit audio. The feedback click is generated on your Mac. Brute uses keyboard events to recognize or configure shortcuts. The optional standalone Fn shortcut requires macOS Input Monitoring. Brute does not keep a keystroke history.

macOS preferences store your shortcut, double-press window, icon setting, and the device identifiers, gain values, and pending changes needed to restore your microphone. These settings persist across launches and are never sent to Breu Software. You can revoke Brute’s permissions in System Settings → Privacy & Security. To remove local settings, first set your microphone to the state you want, then quit Brute and remove its app data from your Mac.

If you email us, we use the information you send to respond. You can ask us to delete your support correspondence at [support@breusoftware.com](mailto:support@breusoftware.com).
