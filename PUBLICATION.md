# Brute publication checks

This document separates completed implementation from checks that still require a signed distribution build, a live microphone, or Apple’s services. It is not a release approval.

## Implemented

- One microphone gesture controller and user state-write boundary; no alternate modes or double-click behavior.
- Permanent tap toggle and temporary hold toggle with restoration on release.
- Saved tap/hold delay from 0.2 to 1.0 seconds in 0.2-second increments.
- Menu state and microphone diagnostics, gesture help, system appearance, an accessible delay slider, Preferences/About/Quit actions, and offline Help.
- Bundled HTML help in both Xcode and shell app builds.
- Brute app name and existing `com.breu.macmute` bundle identifier in both build paths.
- macOS 13.0 deployment settings and Utilities app category.
- Xcode Debug/Release sandbox configuration with Core Audio input entitlement.
- Regression coverage for gesture timing, restoration, device handling, feedback recovery, hotkey retries, and the execution-path contract.
- A shared coverage gate for CI and Developer ID releases, and version metadata shared between Xcode and shell packaging.

No separate backlog file exists in this repository. Completed work is recorded here rather than retained as open tasks.

## Verified locally in this cut

- The shared release gate passed 127 tests with 55.26% overall line coverage. All critical-file floors passed, including click feedback at 49.09%.
- The strict SwiftPM release build and ShellCheck passed. Xcode built the Release app with sandbox and audio input entitlements, and all 127 tests passed in its test host.
- An ad-hoc shell build produced and verified Apple Silicon and Intel slices. The shell and Xcode bundles reported version and build 1.3.

These are development checks. Repeat the applicable checks against the final distribution build.

## Before either distribution route

- [ ] Run `bash Scripts/check_release.sh` against the final source.
- [ ] Test taps in both starting states and holds at every delay stop; release must restore the prior state.
- [ ] Verify shortcut registration, shortcut changes, and standalone fn permission behavior.
- [ ] Verify state icons/menu text against live microphone behavior, including unavailable and reconnect states.
- [ ] Verify default-device switching while muted, sleep/wake, feedback sound, and Launch at Login.
- [ ] Check menu legibility in light and dark appearances, VoiceOver navigation, slider interaction, Preferences/About/Quit actions, and offline Help from the installed app.
- [ ] Confirm the versions in `Resources/Version.xcconfig` are appropriate for the intended submission.

## App Store route

- [ ] Archive the Release app with the intended App Store signing configuration.
- [ ] Inspect the archive’s signed entitlements for sandbox and audio input access.
- [ ] Repeat live feature checks in the signed sandboxed build; unsandboxed shell builds and fake-hardware tests do not cover this gate.
- [ ] Validate and upload in Organizer; confirm the app-category and sandbox validation issues are resolved.
- [ ] Verify the App Store listing name and bundle identifier match the Brute build.
- [ ] Refresh the App Store screenshots from the Brute build before submitting.
- [ ] Confirm Apple processing, metadata, and review status before describing the app as published.

## Direct-distribution route

- [ ] Run the Developer ID DMG pipeline with the intended certificate and Keychain notarization profile.
- [ ] Confirm actual Apple notarization acceptance, stapling, and Gatekeeper results.
- [ ] Install from the resulting DMG and repeat the live checks.
- [ ] Publish the verified download only when explicitly authorized.

No successful App Store upload/review or production notarization was verified in this documentation sweep.
