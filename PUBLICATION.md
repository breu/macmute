# Brute publication checks

This document separates completed implementation from checks that still require a signed distribution build, a live microphone, or Apple’s services. It is not a release approval.

## Implemented

- One microphone gesture controller and user state-write boundary.
- Immediate temporary toggle on press, restoration on release, and permanent toggle after two quick taps.
- Saved double-press window from 0.2 to 1.0 seconds in 0.2-second steps, with a 0.4-second default.
- Menu state and microphone diagnostics, gesture help, system appearance, Preferences/About/Quit actions, and offline Help.
- Bundled HTML help in both Xcode and shell app builds.
- Brute app name and existing `com.breu.macmute` bundle identifier in both build paths.
- macOS 13.0 deployment settings and Utilities app category.
- Xcode Debug/Release sandbox configuration with Core Audio input entitlement.
- Regression coverage for gesture timing, restoration, device handling, feedback recovery, hotkey retries, and the execution-path contract.
- A shared coverage gate for CI and Developer ID releases, and version metadata shared between Xcode and shell packaging.

No separate backlog file exists in this repository. Completed work is recorded here rather than retained as open tasks.

## Verified locally in this cut

- The shared release gate passed 154 tests with 65.18% overall line coverage. All critical-file floors passed.
- ShellCheck and all 154 Xcode tests passed. The hosted tests use simulated inputs.
- Xcode locally exported Brute 1.3.0 (1.3.1) for the Mac App Store with Breu Software LLC signing. The installer and embedded app signatures verified. The embedded app has Apple Silicon and Intel slices, App Sandbox and audio input entitlements, and the bundled help and privacy policy.
- The development DMG built, mounted, and verified its app and source revision.

These are development checks. Repeat the applicable checks against the final distribution build.

## Before either distribution route

- [ ] Run `bash Scripts/check_release.sh` against this candidate.
- [ ] In both starting states, verify that a press switches immediately, a single release restores the prior state, and two quick taps keep the new state. Check that a long hold and two separated taps each restore the prior state.
- [ ] At each slider setting, check the limit on time between releases and the duration of each tap. Verify the saved selection survives relaunch.
- [ ] Verify shortcut registration and changes. Test standalone Fn with Input Monitoring granted and revoked, including release while another app is focused.
- [ ] Verify state icons/menu text against live microphone behavior, including unavailable and reconnect states.
- [ ] Verify default-device switching while muted, sleep/wake, feedback sound, and Launch at Login.
- [ ] Check menu legibility in light and dark appearances, VoiceOver navigation, Preferences/About/Quit actions, and offline Help from the installed app.
- [ ] Confirm the versions in `Resources/Version.xcconfig` are appropriate for the intended submission.

## App Store route

- [x] Archive and locally export the Release app with App Store signing.
- [x] Inspect the exported app’s signed entitlements for sandbox and audio input access.
- [ ] Repeat live feature checks in the signed sandboxed build; unsandboxed shell builds and fake-hardware tests do not cover this gate.
- [ ] Validate and upload in Organizer; confirm the app-category and sandbox validation issues are resolved.
- [ ] Verify the App Store listing name and bundle identifier match the Brute build.
- [ ] After pushing the policy, open the [public privacy policy](https://github.com/breusoftware/brute#privacy-policy) while signed out and enter that URL and the app privacy answers in App Store Connect.
- [ ] Refresh the App Store screenshots to show the shortcut instructions and the double-press slider. Export 1440 × 900 images without an alpha channel.
- [ ] Confirm Apple processing, metadata, and review status before describing the app as published.

## Direct-distribution route

- [ ] Run the Developer ID DMG pipeline with the intended certificate and Keychain notarization profile.
- [ ] Confirm actual Apple notarization acceptance, stapling, and Gatekeeper results.
- [ ] Install from the resulting DMG and repeat the live checks.
- [ ] Publish the verified download only when explicitly authorized.

No successful App Store upload/review or production notarization was verified in this documentation sweep.
