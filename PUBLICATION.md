# Brute publication checks

This document separates completed implementation from checks that still require a signed distribution build, a live microphone, or Apple’s services. It is not a release approval.

## Implemented

- One microphone gesture controller and user state-write boundary; no alternate modes or double-click behavior.
- Permanent tap toggle and temporary hold toggle with restoration on release.
- Saved tap/hold delay from 0.2 to 1.0 seconds in 0.2-second increments.
- Menu state/status, gesture help, white text, active Preferences/About/Quit actions, and an offline Help item.
- Bundled HTML help in both Xcode and shell app builds.
- Brute app name and existing `com.breu.macmute` bundle identifier in both build paths.
- macOS 13.0 deployment settings and Utilities app category.
- Xcode Debug/Release sandbox configuration with Core Audio input entitlement.
- Regression coverage for gesture timing, restoration, device handling, and the execution-path contract.

No separate backlog file exists in this repository. Completed work is recorded here rather than retained as open tasks.

## Verified locally in this cut

- The 100-test suite passed during gesture consolidation.
- The 82-test controller suite passed after the delay slider changes.
- Subsequent menu and help changes compiled successfully.
- Xcode Debug build succeeded with ad-hoc signing; its bundled help matched the source HTML.
- The built Debug app’s signed sandbox and audio input entitlements were checked. This does not validate runtime functionality or App Store acceptance.

These are development checks. Repeat the applicable checks against the final distribution build.

## Before either distribution route

- [ ] Run the strict test and coverage commands in README against the final source.
- [ ] Test taps in both starting states and holds at every delay stop; release must restore the prior state.
- [ ] Verify shortcut registration, shortcut changes, and standalone fn permission behavior.
- [ ] Verify state icons/menu text against live microphone behavior, including unavailable and reconnect states.
- [ ] Verify default-device switching while muted, sleep/wake, feedback sound, and Launch at Login.
- [ ] Check menu legibility, slider interaction, Preferences/About/Quit actions, and offline Help from the installed app.
- [ ] Confirm version/build metadata in `Resources/Info.plist` is appropriate for the intended submission.

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
