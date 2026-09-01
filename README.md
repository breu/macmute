# MacMute

A lightweight menu bar utility that mutes your Mac's system microphone. It mutes at the CoreAudio hardware level on the default input device, so the mute applies across every app system-wide — not just one app's own mute button.

## Features

- Menu bar icon (🎙 / 🔇) reflecting mute state
- Explicit unavailable-state icon when CoreAudio cannot verify the microphone state
- Global hotkey (default: ⌥⌘M, or bind the standalone `fn` key), configurable in Preferences, with three interactions:
  - **Tap**: performs the current mode's action and leaves it
  - **Hold**: performs the action while held, reverts to the prior state on release
  - **Double-click**: switches between "Push to Mute" and "Push to Unmute" mode
- Mode can also be set directly from the menu bar dropdown
- Launch at Login (in Preferences)
- Tracks the default input device — if you switch microphones while muted, the new device is muted too
- Preserves the microphone's existing state when MacMute launches

## How it works

MacMute never records or transmits audio. It only flips the input device's writable `Mute` property (or, on devices without one, zeroes the writable master input volume and restores the verified per-device baseline) through CoreAudio. Every requested state change is read back before the menu bar reports success.

## Build (no Xcode required)

Requires Xcode Command Line Tools (`xcode-select --install`) and macOS 13+.

```sh
./Scripts/build_app.sh
```

This runs `swift build -c release`, assembles `MacMute.app`, ad-hoc signs it for local development, and verifies the resulting bundle. It does not modify the microphone merely by building or launching the app.

Run the regression suite with:

```sh
swift test
```

## Install

```sh
./Scripts/build_dmg.sh
```

Builds the app and packages it into `MacMute-<version>.dmg` — a disk image containing `MacMute.app` and an `Applications` shortcut, so you open it and drag the app in like any other Mac app. Installing to `/Applications` this way (rather than running the app from wherever it was built) matters for Launch at Login: macOS's `SMAppService` registers login items by the app's installed location, so it works most reliably once the app lives somewhere stable like `/Applications`.

## Run

```sh
open MacMute.app
```

The app has no Dock icon or main window — look for the mic icon in the menu bar.

- **Click** the menu bar icon: opens the dropdown (Hotkey Mode, Toggle Mute, Preferences…, About, Quit)
- **Preferences…**: change the global hotkey or enable Launch at Login
- **About**: version and credits

## BreuSoftware LLC Release Signing

Local builds intentionally use ad-hoc signing. Public releases must use BreuSoftware LLC's Apple-issued **Developer ID Application** certificate plus Apple's notarization service. The release scripts refuse to create a release DMG with an ad-hoc, self-signed, or differently named identity.

First save App Store Connect notarization credentials in Keychain using `xcrun notarytool store-credentials`. Then supply the exact Keychain identity and saved profile:

```sh
export MACMUTE_RELEASE=1
export MACMUTE_SIGNING_IDENTITY='Developer ID Application: BreuSoftware LLC (TEAMID)'
export MACMUTE_TEAM_ID='TEAMID1234'
export MACMUTE_NOTARY_PROFILE='breusoftware-notary'
./Scripts/build_dmg.sh
```

Replace the example identity, 10-character team ID, and profile name with BreuSoftware LLC's actual values. Release mode runs the strict test suite, applies the hardened runtime and secure timestamp, verifies the signed app's exact TeamIdentifier and Apple trust assessment, signs the DMG, submits it to Apple, staples the notarization ticket, and only then publishes the app and DMG together. Never create or globally trust a self-signed certificate for a public release.

## Notes

- On first launch, macOS may prompt for microphone-related permission when CoreAudio enumerates input devices. MacMute never opens an audio input stream.
- To change the hotkey: open Preferences, click the shortcut button, then press your desired key combination (must include a modifier, or press `fn` alone).
- Binding `fn` requires granting MacMute Accessibility permission (System Settings → Privacy & Security → Accessibility) — macOS will prompt for this the first time.
- If your menu bar already has other mic/audio-related icons (system input indicator, call-app mute buttons, etc.), MacMute's plain mic icon can be easy to miss at a glance — check for it near other third-party menu bar icons, not just the system clock cluster.
