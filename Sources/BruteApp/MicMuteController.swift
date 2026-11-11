import AppKit
import CoreAudio
import Foundation

/// Owns microphone state: device transfers, pending state changes, ownership of a
/// mute it applied, and restoration retries.
///
/// Every hardware write funnels through `applyMute`, so there is exactly one place
/// where the device is touched. Writes are confirmed against readback; an accepted
/// write whose effect is delayed stays pending until observed.
@MainActor
final class MicMuteController {
    static let shared = MicMuteController(hardware: CoreAudioDeviceController())

    private(set) var state: MicrophoneState
    var isMuted: Bool { state == .muted }
    var onStateChanged: ((MicrophoneState) -> Void)?

    /// Why the microphone cannot currently be controlled, for the UI. Cleared when
    /// the microphone becomes available again. Without this the menu can only say
    /// "Unavailable" and the reason reaches the log, which no user reads.
    private(set) var lastError: MicControlError?

    private let hardware: AudioDeviceControlling
    private var savedVolumes: [String: InputVolumeSnapshot]
    private var appMutedDeviceIdentifiers: Set<String>
    private var pendingDesiredStates: [String: Bool]
    private var pendingVolumeRestorations: [String: InputVolumeSnapshot]
    private var pendingForcedWrites: Set<String>
    private var pendingDeviceRestorations: [String: DeviceRestoration]
    private var acceptedPendingStates: [String: Bool] = [:]
    private var acceptedDeviceRestorations: Set<String> = []
    private var activeTemporaryMute: ActiveTemporaryMute?
    private var knownDeviceIDs: [String: AudioDeviceID] = [:]
    private var cachedDeviceIdentifiers: [AudioDeviceID: String] = [:]
    private var pendingDesiredStateAcrossUnavailableDevice: Bool?
    private(set) var currentDeviceID: AudioDeviceID?
    private let defaults: UserDefaults
    private var statePollTimer: Timer?
    private(set) var scheduledPollInterval: TimeInterval?
    private var pollGeneration = 0
    private var sleepObserver: NotificationObservation?
    private var wakeObserver: NotificationObservation?
    private var observesSystemChanges: Bool
    private var observesDefaultDevice = false
    private var currentWriteFailed = false

    /// Poll cadence while a write is waiting to be confirmed by readback.
    static let activePollInterval: TimeInterval = 0.25
    /// Poll cadence when one or more CoreAudio listeners could not be installed.
    static let fallbackPollInterval: TimeInterval = 1
    /// Poll cadence while push observation is healthy and nothing is outstanding.
    /// The poll is a safety net, not the primary signal — see `refreshInterval`.
    static let idlePollInterval: TimeInterval = 10

    private static let savedVolumesDefaultsKey = BruteDefaults.savedInputVolumes
    private static let appMutedDevicesDefaultsKey = BruteDefaults.appMutedInputDevices
    private static let pendingDesiredStatesDefaultsKey = BruteDefaults.pendingInputStates

    private struct DeviceIdentity {
        let deviceID: AudioDeviceID
        let key: String
        let mustRemainDefault: Bool
    }

    struct TemporaryMute: Equatable {
        fileprivate let id = UUID()
    }

    private struct ActiveTemporaryMute {
        let token: TemporaryMute
        let identity: DeviceIdentity
    }

    private struct DeviceRestoration: Equatable {
        let muted: Bool
        let preserveOwnership: Bool
    }

    init(
        hardware: AudioDeviceControlling,
        observeSystemChanges: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        self.hardware = hardware
        self.defaults = defaults
        self.observesSystemChanges = observeSystemChanges
        savedVolumes = Self.loadVolumeSnapshots(from: defaults, key: Self.savedVolumesDefaultsKey)
        appMutedDeviceIdentifiers = Self.loadAppMutedDeviceIdentifiers(from: defaults)
        let pending = Self.loadPendingWrites(from: defaults)
        pendingDesiredStates = pending.states
        pendingForcedWrites = pending.forced
        pendingDeviceRestorations = Self.loadDeviceRestorations(from: defaults)
        pendingVolumeRestorations = Self.loadVolumeSnapshots(from: defaults, key: BruteDefaults.pendingInputVolumeRestorations)
        currentDeviceID = hardware.defaultInputDeviceID()
        // The static form, because an instance method would capture `self` before
        // `state` below has a value.
        state = currentDeviceID.map { Self.readState(on: $0, using: hardware) } ?? .unavailable
        if let currentDeviceID {
            remember(currentDeviceID)
            retryDeviceRestorations()
            retryPendingDesiredStates()
            state = Self.readState(on: currentDeviceID, using: hardware)
        } else {
            retryDeviceRestorations()
        }
        if state == .unmuted,
           let currentDeviceID,
           let identity = validatedIdentity(for: currentDeviceID, mustRemainDefault: true),
           pendingState(for: identity.key) == nil {
            removeAppMuteOwnership(identity)
        }
        lastError = Self.availabilityError(for: state, hasDevice: currentDeviceID != nil)

        guard observeSystemChanges else { return }
        observeDefaultDeviceChanges()
        observeCurrentDeviceState()
        if !systemObservationIsHealthy {
            BruteLog.audio.warning("CoreAudio observation is incomplete; periodic verification remains active")
        }
        scheduleStatePoll()
        observeLifecycle()
    }

    // MARK: - Public surface

    @discardableResult
    func toggleMute() -> Bool {
        syncBeforeGesture()
        guard let prior = logicalMutedValue else { return false }
        return setMuted(!prior)
    }

    func beginTemporaryToggle() -> TemporaryMute? {
        guard activeTemporaryMute == nil else { return nil }
        syncBeforeGesture()
        guard let prior = logicalMutedValue,
              let deviceID = currentDeviceID,
              let identity = validatedIdentity(for: deviceID, mustRemainDefault: true)
        else { return nil }

        let token = TemporaryMute()
        let forceWrite = pendingState(for: identity.key) != nil
        setDeviceRestoration(
            DeviceRestoration(muted: prior, preserveOwnership: ownsMute(identity)),
            for: identity.key
        )
        clearPendingDesiredState(forIdentifier: identity.key)
        let accepted = applyMute(!prior, to: identity, forceWrite: forceWrite)
        let sameDevice = identityStillMatches(identity)
        let actual = sameDevice ? readState(on: deviceID) : .unavailable
        if accepted, sameDevice {
            activeTemporaryMute = ActiveTemporaryMute(token: token, identity: identity)
        } else if !forceWrite, sameDevice, actual.mutedValue == prior {
            // The rejected write did not change anything. Do not later undo a
            // mute or unmute that someone else applies.
            setDeviceRestoration(nil, for: identity.key)
        }
        publish(actual, writeFailed: !accepted)
        return accepted && sameDevice ? token : nil
    }

    @discardableResult
    func endTemporaryToggle(_ token: TemporaryMute) -> Bool {
        guard activeTemporaryMute?.token == token else { return false }
        if hardware.defaultInputDeviceID() != currentDeviceID || currentDeviceWasReplaced() {
            reconcileCurrentDeviceIfNeeded()
            return false
        }
        let restored = restoreTemporaryToggle(token)
        refreshCurrentDeviceState()
        return restored
    }

    @discardableResult
    private func restoreTemporaryToggle(_ token: TemporaryMute) -> Bool {
        guard let active = activeTemporaryMute, active.token == token else { return false }
        _ = validatedCurrentIdentity(for: active.identity.deviceID)
        let key = activeTemporaryMute?.identity.key ?? active.identity.key
        activeTemporaryMute = nil
        guard let restoration = pendingDeviceRestorations[key] else { return false }
        return restoreDeviceState(for: key, restoration: restoration)
    }

    private var logicalMutedValue: Bool? {
        guard let deviceID = currentDeviceID, state != .unavailable else { return nil }
        let key = trackedKey(for: deviceID)
        return acceptedPendingStates[key]
            ?? (acceptedDeviceRestorations.contains(key) ? pendingDeviceRestorations[key]?.muted : nil)
            ?? state.mutedValue
    }

    @discardableResult
    func setMuted(_ muted: Bool, retryOnFailure: Bool = false) -> Bool {
        reconcileCurrentDeviceIfNeeded()
        guard let deviceID = currentDeviceID,
              let identity = validatedIdentity(for: deviceID, mustRemainDefault: true)
        else {
            if retryOnFailure {
                pendingDesiredStateAcrossUnavailableDevice = muted
            }
            publish(.unavailable)
            return false
        }

        pendingDesiredStateAcrossUnavailableDevice = nil
        setPendingDesiredState(muted, for: identity)
        let accepted = applyMute(muted, to: identity, forceWrite: pendingForcedWrites.contains(identity.key))
        guard identityStillMatches(identity) else {
            publish(.unavailable)
            return false
        }
        let actual = readState(on: deviceID)
        if accepted {
            setDeviceRestoration(nil, for: identity.key)
            recordAcceptedDesiredState(muted, for: identity.key)
            confirm(actual, desired: muted, identity: identity)
        }
        if !accepted, !retryOnFailure {
            clearPendingDesiredState(forIdentifier: identity.key)
        }
        if !accepted {
            BruteLog.audio.warning("Could not change microphone mute state")
        }
        publish(actual, writeFailed: !accepted)
        return accepted
    }

    func prepareForSleep() {
        if let active = activeTemporaryMute {
            endTemporaryToggle(active.token)
        }
        guard let deviceID = currentDeviceID,
              let identity = validatedIdentity(for: deviceID, mustRemainDefault: true),
              ownsMute(identity),
              pendingState(for: identity.key) == nil
        else { return }
        setPendingDesiredState(true, for: identity)
        scheduleStatePoll()
    }

    func handleWake() {
        if let active = activeTemporaryMute {
            endTemporaryToggle(active.token)
        }
        hardware.invalidateControlCaches(for: nil)
        if observesSystemChanges {
            if !observesDefaultDevice { observeDefaultDeviceChanges() }
            observeCurrentDeviceState()
        }
        if let deviceID = currentDeviceID,
           let identity = validatedIdentity(for: deviceID, mustRemainDefault: true),
           ownsMute(identity) || pendingState(for: identity.key) == true,
           pendingState(for: identity.key) != false {
            _ = setMuted(true, retryOnFailure: true)
        }
        refreshState()
    }

    func handleDefaultDeviceChange() {
        let newDeviceID = hardware.defaultInputDeviceID()
        guard newDeviceID != currentDeviceID || currentDeviceWasReplaced() else {
            hardware.invalidateControlCaches(for: currentDeviceID)
            refreshState()
            return
        }
        transitionDefaultDevice(to: newDeviceID)
    }

    private func transitionDefaultDevice(to newDeviceID: AudioDeviceID?) {
        let oldDeviceID = currentDeviceID
        let oldKey = oldDeviceID.map { trackedKey(for: $0) }
        let restoringOriginalDevice = oldKey.flatMap { pendingDeviceRestorations[$0] } != nil
        if let active = activeTemporaryMute {
            restoreTemporaryToggle(active.token)
        }
        hardware.invalidateControlCaches(for: oldDeviceID)
        if let newDeviceID, oldDeviceID != nil {
            hardware.invalidateControlCaches(for: newDeviceID)
        }
        let oldIdentity = oldDeviceID.map { validatedCurrentIdentity(for: $0) }
        let departingState = oldDeviceID.flatMap { deviceID in
            oldIdentity?.matches == true ? readState(on: deviceID) : nil
        } ?? state
        // A gain restore is local to the device it started on.
        let departingPendingState = !restoringOriginalDevice
            ? oldIdentity.flatMap { pendingDesiredStates[$0.key] }
            : nil
        let desiredStateToCarry = restoringOriginalDevice ? nil : (
            pendingDesiredStateAcrossUnavailableDevice
                ?? departingPendingState
                ?? ((departingState == .muted || (departingState == .unavailable && state == .muted)) ? true : nil)
        )
        if let oldDeviceID {
            if let key = oldIdentity?.key {
                if departingPendingState == true, appMutedDeviceIdentifiers.contains(key) {
                    // The old mute may still be in flight even if it reads as
                    // live. Queue a forced reversal on that exact input.
                    setDeviceRestoration(DeviceRestoration(muted: false, preserveOwnership: false), for: key)
                }
                clearPendingDesiredState(forIdentifier: key)
            }
            if oldIdentity?.matches == true,
               !restoringOriginalDevice,
               departingPendingState != true,
               let identity = validatedIdentity(for: oldDeviceID, mustRemainDefault: false),
               ownsMute(identity) || pendingVolumeRestorations[identity.key] != nil,
               !restoreAppOwnedMute(identity) {
                BruteLog.audio.warning("Could not restore departing input device; restoration remains queued")
            }
        }

        currentDeviceID = newDeviceID
        currentWriteFailed = false
        if let newDeviceID {
            remember(newDeviceID)
        }
        if observesSystemChanges {
            if !observesDefaultDevice { observeDefaultDeviceChanges() }
            observeCurrentDeviceState()
        }

        guard let newDeviceID else {
            pendingDesiredStateAcrossUnavailableDevice = desiredStateToCarry
            publish(.unavailable)
            return
        }
        pendingDesiredStateAcrossUnavailableDevice = nil
        if let desiredState = desiredStateToCarry {
            if let identity = validatedIdentity(for: newDeviceID, mustRemainDefault: true) {
                setPendingDesiredState(desiredState, for: identity)
                let accepted = applyMute(
                    desiredState, to: identity, forceWrite: pendingForcedWrites.contains(identity.key)
                )
                if accepted, identityStillMatches(identity) {
                    setDeviceRestoration(nil, for: identity.key)
                    recordAcceptedDesiredState(desiredState, for: identity.key)
                    confirm(readState(on: newDeviceID), desired: desiredState, identity: identity)
                }
            }
        }
        publish(readState(on: newDeviceID))
    }

    /// Full reconciliation: retries anything outstanding and republishes. Driven by
    /// listeners and by the poll timer.
    func refreshState() {
        reconcileCurrentDeviceIfNeeded()
        retryDeviceRestorations()
        retryPendingDesiredStates()
        retryPendingRestorations(excluding: currentDeviceID)
        refreshCurrentDeviceState()
    }

    private func refreshCurrentDeviceState() {
        guard let deviceID = currentDeviceID else {
            publish(.unavailable)
            return
        }
        let actual = readState(on: deviceID)
        let trackedKey = trackedKey(for: deviceID)
        if (pendingState(for: trackedKey) != nil
            || (actual == .unmuted && appMutedDeviceIdentifiers.contains(trackedKey))),
           let identity = validatedIdentity(for: deviceID, mustRemainDefault: true) {
            if pendingDeviceRestorations[identity.key] == nil,
               let desired = pendingState(for: identity.key) {
                confirm(actual, desired: desired, identity: identity)
            }
            if actual == .unmuted, pendingState(for: identity.key) == nil {
                removeAppMuteOwnership(identity)
            }
        }
        publish(actual)
    }

    /// Cheaper read for the start of a gesture: reconcile and read the device, but
    /// skip the pending-restoration sweep across every device Brute knows about.
    ///
    /// A gesture needs an accurate *current* state to flip from; it does not need
    /// unrelated devices repaired first. Those still get retried by `refreshState`
    /// on the next listener callback or poll tick.
    func syncBeforeGesture() {
        reconcileCurrentDeviceIfNeeded()
        retryDeviceRestorations(includingOtherDevices: false)
        retryPendingDesiredStates(includingOtherDevices: false)
        refreshCurrentDeviceState()
    }

    /// Stops timers and system observers. The shared controller lives for the
    /// process; an instance that does not should call this.
    func shutdown() {
        onStateChanged = nil
        guard observesSystemChanges else { return }
        observesSystemChanges = false
        statePollTimer?.invalidate()
        statePollTimer = nil
        scheduledPollInterval = nil
        sleepObserver = nil
        wakeObserver = nil
        hardware.shutdown()
    }

    // MARK: - Polling

    /// Whether push observation can be trusted to tell us about changes.
    /// Internal so the regression suite can drive both cadences.
    var systemObservationIsHealthy = false

    /// An outstanding write must target a device we can still check. Owning a
    /// confirmed mute on the current device is steady state.
    var hasOutstandingWork: Bool {
        let currentKey = currentDeviceID.map { trackedKey(for: $0) }
        func isKnown(_ key: String) -> Bool {
            key == currentKey || knownDeviceIDs[key] != nil
        }
        return pendingDesiredStates.keys.contains(where: isKnown)
            || pendingVolumeRestorations.keys.contains(where: isKnown)
            || pendingDeviceRestorations.keys.contains(where: isKnown)
            || appMutedDeviceIdentifiers.contains { identifier in
                guard let deviceID = knownDeviceIDs[identifier] else { return false }
                return deviceID != currentDeviceID
            }
    }

    /// The poll is a safety net for missed or failed CoreAudio notifications, not
    /// the primary signal. Polling it at a fixed 1 Hz costs dozens of CoreAudio
    /// round trips a second, forever, in an app meant to run for weeks — so the
    /// cadence follows how much is actually in flight.
    ///
    /// Internal so the suite can pin the cadence contract.
    var refreshInterval: TimeInterval {
        if hasOutstandingWork { return Self.activePollInterval }
        return systemObservationIsHealthy ? Self.idlePollInterval : Self.fallbackPollInterval
    }

    private func scheduleStatePoll() {
        guard observesSystemChanges else { return }
        let interval = refreshInterval
        guard scheduledPollInterval != interval else { return }
        statePollTimer?.invalidate()
        pollGeneration += 1
        let generation = pollGeneration
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.observesSystemChanges, self.pollGeneration == generation else { return }
                self.statePollTimer = nil
                self.scheduledPollInterval = nil
                self.refreshState()
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        statePollTimer = timer
        scheduledPollInterval = interval
    }

    // MARK: - Hardware access

    /// The one place a device's controls are written.
    private func applyMute(
        _ muted: Bool,
        to identity: DeviceIdentity,
        forceWrite: Bool = false,
        gainOnly: Bool = false
    ) -> Bool {
        let accepted = writeMuteState(muted, to: identity, forceWrite: forceWrite, gainOnly: gainOnly)
        if accepted, muted, let target = pendingVolumeRestorations[identity.key] {
            if savedVolumes[identity.key] == nil {
                savedVolumes[identity.key] = target
                persistSavedVolumes()
            }
            setPendingVolumeRestoration(nil, for: identity.key)
        }
        return accepted
    }

    private func writeMuteState(
        _ muted: Bool,
        to identity: DeviceIdentity,
        forceWrite: Bool,
        gainOnly: Bool
    ) -> Bool {
        guard identityStillMatches(identity) else { return false }
        let deviceID = identity.deviceID
        let pendingRestore = pendingVolumeRestorations[identity.key]
        // A channel may have appeared before its change notification arrives.
        // Rediscover once per write so an old inventory can't omit that channel.
        hardware.invalidateControlCaches(for: deviceID)
        let hasNativeMute = !gainOnly && hardware.hasMuteProperty(on: deviceID)
        let nativeMuteIsSettable = hasNativeMute && hardware.isMuteSettable(on: deviceID)
        if nativeMuteIsSettable {
            guard let current = hardware.readMute(on: deviceID) else { return false }
            if current == muted, muted, !forceWrite {
                return true
            }
            if current != muted || forceWrite {
                let alreadyOwned = ownsMute(identity)
                if muted { addAppMuteOwnership(identity) }
                guard identityStillMatches(identity), hardware.setMute(muted, on: deviceID) else {
                    if muted, !alreadyOwned { removeAppMuteOwnership(identity) }
                    return false
                }
                guard identityStillMatches(identity) else { return false }
                // Finish the native unmute before starting a gain restore, so
                // later gain-only retries never need to touch native mute.
                if muted || hardware.readMute(on: deviceID) != false { return true }
            }
            if pendingRestore == nil {
                guard let volumes = hardware.readVolumes(on: deviceID),
                      AudioControlPolicy.volumesAreMuted(volumes) || (forceWrite && savedVolumes[identity.key] != nil)
                else { return true }
            }
        }

        if hasNativeMute, !nativeMuteIsSettable {
            guard let nativeMuted = hardware.readMute(on: deviceID) else { return false }
            if nativeMuted {
                return muted
            }
        }

        guard hardware.isVolumeSettable(on: deviceID),
              let currentVolumes = hardware.readVolumes(on: deviceID),
              !currentVolumes.isEmpty
        else { return false }

        if muted {
            if AudioControlPolicy.volumesAreMuted(currentVolumes), !forceWrite {
                return true
            }
            // A retry may observe only some channels at zero. Keep the original baseline.
            if pendingRestore == nil, !ownsMute(identity) || savedVolumes[identity.key] == nil {
                savedVolumes[identity.key] = currentVolumes
                persistSavedVolumes()
            }
            let mutedVolumes = currentVolumes.mapValues { _ in Float32(0) }
            let alreadyOwned = ownsMute(identity)
            addAppMuteOwnership(identity)
            guard identityStillMatches(identity), hardware.setVolumes(mutedVolumes, on: deviceID) else {
                if !alreadyOwned { removeAppMuteOwnership(identity) }
                return false
            }
            guard identityStillMatches(identity) else { return false }
            return true
        }

        // A live gain before Brute attempts a restore belongs to the user or
        // another app. Once we start a restore, partial progress is still ours.
        if pendingRestore == nil, !AudioControlPolicy.volumesAreMuted(currentVolumes), !forceWrite {
            return true
        }
        var baseline = (savedVolumes[identity.key] ?? [:]).merging(pendingRestore ?? [:]) { _, target in target }
        if forceWrite, pendingRestore == nil {
            // Supersede an in-flight mute without changing any gains that
            // are already live, including gain a user adjusted externally.
            for (element, gain) in currentVolumes where gain > AudioControlPolicy.silenceThreshold {
                baseline[element] = gain
            }
        }
        let restoredVolumes = AudioControlPolicy.restorationVolumes(saved: baseline, current: currentVolumes)
        guard identityStillMatches(identity) else { return false }
        // A newly observed channel that is already live was never silenced by
        // this restore. Preserve its current gain without claiming it.
        let unrelatedLiveChannels = Set(currentVolumes.compactMap { element, volume in
            pendingRestore != nil && baseline[element] == nil && volume > AudioControlPolicy.silenceThreshold
                ? element : nil
        })
        let targets = restoredVolumes.filter { !unrelatedLiveChannels.contains($0.key) }
        let writeVolumes = currentVolumes.merging(targets) { _, restored in restored }
        let plan = (pendingRestore ?? [:]).merging(targets) { _, target in target }
        setPendingVolumeRestoration(plan, for: identity.key)
        if !forceWrite, AudioControlPolicy.restoredVolumesMatch(currentVolumes, target: writeVolumes) {
            return true
        }
        guard identityStillMatches(identity), hardware.setVolumes(writeVolumes, on: deviceID) else {
            if pendingRestore == nil { setPendingVolumeRestoration(nil, for: identity.key) }
            return false
        }
        return identityStillMatches(identity)
    }

    private func readState(on deviceID: AudioDeviceID) -> MicrophoneState {
        Self.readState(on: deviceID, using: hardware)
    }

    /// Samples each relevant control at most once per state read.
    static func readState(
        on deviceID: AudioDeviceID,
        using hardware: AudioDeviceControlling
    ) -> MicrophoneState {
        let hasNativeMute = hardware.hasMuteProperty(on: deviceID)
        let nativeMute = hasNativeMute ? hardware.readMute(on: deviceID) : nil
        return AudioControlPolicy.state(
            hasNativeMute: hasNativeMute,
            nativeMute: nativeMute,
            volumes: nativeMute == true ? nil : hardware.readVolumes(on: deviceID)
        )
    }

    private func restoreAppOwnedMute(_ identity: DeviceIdentity) -> Bool {
        guard identityStillMatches(identity) else { return false }
        let deviceID = identity.deviceID
        // Restore both native mute and any fallback volume this app changed.
        let restored = applyMute(false, to: identity, gainOnly: pendingVolumeRestorations[identity.key] != nil)
        if restored, identityStillMatches(identity) {
            confirm(readState(on: deviceID), desired: false, identity: identity)
        }
        return restored
    }

    private func ownsMute(_ identity: DeviceIdentity) -> Bool {
        appMutedDeviceIdentifiers.contains(identity.key)
    }

    private func addAppMuteOwnership(_ identity: DeviceIdentity) {
        knownDeviceIDs[identity.key] = identity.deviceID
        if appMutedDeviceIdentifiers.insert(identity.key).inserted {
            persistAppMutedDeviceIdentifiers()
        }
    }

    private func removeAppMuteOwnership(_ identity: DeviceIdentity) {
        knownDeviceIDs[identity.key] = identity.deviceID
        if appMutedDeviceIdentifiers.remove(identity.key) != nil {
            persistAppMutedDeviceIdentifiers()
        }
    }

    private func remember(_ deviceID: AudioDeviceID) {
        knownDeviceIDs[volumeKey(for: deviceID)] = deviceID
    }

    private func restoreDeviceState(for key: String, restoration: DeviceRestoration) -> Bool {
        guard let deviceID = validatedDeviceID(for: key),
              let identity = validatedIdentity(for: deviceID, mustRemainDefault: false),
              identity.key == key,
              applyMute(restoration.muted, to: identity, forceWrite: !acceptedDeviceRestorations.contains(key)),
              identityStillMatches(identity)
        else { return false }
        acceptedDeviceRestorations.insert(key)
        confirm(readState(on: deviceID), desired: restoration.muted, identity: identity, completingDeviceRestoration: true)
        return true
    }

    private func retryDeviceRestorations(includingOtherDevices: Bool = true) {
        let currentKey = currentDeviceID.map { trackedKey(for: $0) }
        for (key, restoration) in Array(pendingDeviceRestorations)
            where activeTemporaryMute?.identity.key != key && (includingOtherDevices || key == currentKey) {
            _ = restoreDeviceState(for: key, restoration: restoration)
        }
    }

    private func retryPendingRestorations(excluding excludedDeviceID: AudioDeviceID?) {
        let pending = Array(appMutedDeviceIdentifiers).compactMap { identifier -> AudioDeviceID? in
            guard pendingVolumeRestorations[identifier] == nil,
                  pendingDeviceRestorations[identifier] == nil,
                  let deviceID = validatedDeviceID(for: identifier),
                  deviceID != excludedDeviceID else { return nil }
            return deviceID
        }
        for deviceID in pending {
            if let identity = validatedIdentity(for: deviceID, mustRemainDefault: false) {
                _ = restoreAppOwnedMute(identity)
            }
        }
    }

    private func retryPendingDesiredStates(includingOtherDevices: Bool = true) {
        let currentKey = currentDeviceID.map { trackedKey(for: $0) }
        var requested = pendingVolumeRestorations.mapValues { _ in false }
        requested.merge(pendingDesiredStates) { _, explicit in explicit }
        let pending = requested.compactMap { identifier, desired -> (DeviceIdentity, Bool)? in
            guard pendingDeviceRestorations[identifier] == nil else { return nil }
            guard includingOtherDevices || identifier == currentKey else { return nil }
            let deviceID = identifier == currentKey ? currentDeviceID : validatedDeviceID(for: identifier)
            guard let deviceID else { return nil }
            let mustRemainDefault = deviceID == currentDeviceID
            guard let identity = validatedIdentity(for: deviceID, mustRemainDefault: mustRemainDefault),
                  identity.key == identifier
            else { return nil }
            return (identity, desired)
        }
        for (identity, desired) in pending {
            let accepted = applyMute(
                desired,
                to: identity,
                forceWrite: pendingForcedWrites.contains(identity.key),
                gainOnly: pendingDesiredStates[identity.key] == nil
            )
            if accepted, identityStillMatches(identity) {
                recordAcceptedDesiredState(desired, for: identity.key)
                confirm(readState(on: identity.deviceID), desired: desired, identity: identity)
            }
        }
    }

    private func reconcileCurrentDeviceIfNeeded() {
        let newDeviceID = hardware.defaultInputDeviceID()
        if newDeviceID != currentDeviceID || currentDeviceWasReplaced() {
            transitionDefaultDevice(to: newDeviceID)
        }
    }

    private func currentDeviceWasReplaced() -> Bool {
        guard let deviceID = currentDeviceID, let previous = cachedDeviceIdentifiers[deviceID],
              let live = hardware.persistentIdentifier(for: deviceID), !live.isEmpty
        else { return false }
        return live != previous
    }

    /// The single place state becomes visible, which also keeps `lastError` in step
    /// with the state it explains — the UI can never show a stale reason next to a
    /// healthy microphone.
    private func publish(_ newState: MicrophoneState, writeFailed: Bool? = nil) {
        let previousError = lastError
        if let writeFailed {
            currentWriteFailed = writeFailed
        } else if newState != state {
            currentWriteFailed = false
        }
        lastError = Self.availabilityError(for: newState, hasDevice: currentDeviceID != nil)
            ?? (currentWriteFailed ? .writeFailed : nil)
        scheduleStatePoll()
        guard newState != state || lastError != previousError else { return }
        state = newState
        onStateChanged?(newState)
    }

    private static func availabilityError(
        for state: MicrophoneState,
        hasDevice: Bool
    ) -> MicControlError? {
        guard state == .unavailable else { return nil }
        return hasDevice ? .deviceControlsUnreadable : .noInputDevice
    }

    // MARK: - Device identity

    private func trackedKey(for deviceID: AudioDeviceID) -> String {
        cachedDeviceIdentifiers[deviceID].map { "uid:\($0)" } ?? "session:\(deviceID)"
    }

    private func volumeKey(for deviceID: AudioDeviceID) -> String {
        if let identifier = hardware.persistentIdentifier(for: deviceID), !identifier.isEmpty {
            let newKey = "uid:\(identifier)"
            if let cached = cachedDeviceIdentifiers[deviceID], cached != identifier {
                let staleKey = "uid:\(cached)"
                if knownDeviceIDs[staleKey] == deviceID {
                    knownDeviceIDs.removeValue(forKey: staleKey)
                }
            } else if cachedDeviceIdentifiers[deviceID] == nil {
                migrateSessionState(for: deviceID, to: newKey)
            }
            cachedDeviceIdentifiers[deviceID] = identifier
            knownDeviceIDs[newKey] = deviceID
            return newKey
        }
        let key = "session:\(deviceID)"
        knownDeviceIDs[key] = deviceID
        return key
    }

    private func validatedCurrentIdentity(for deviceID: AudioDeviceID) -> (key: String, matches: Bool) {
        if let cached = cachedDeviceIdentifiers[deviceID] {
            let cachedKey = "uid:\(cached)"
            guard let live = hardware.persistentIdentifier(for: deviceID), !live.isEmpty else {
                return (cachedKey, false)
            }
            return (cachedKey, live == cached)
        }
        let sessionKey = "session:\(deviceID)"
        guard let live = hardware.persistentIdentifier(for: deviceID), !live.isEmpty else {
            return (sessionKey, true)
        }
        let persistentKey = "uid:\(live)"
        migrateSessionState(for: deviceID, to: persistentKey)
        cachedDeviceIdentifiers[deviceID] = live
        knownDeviceIDs[persistentKey] = deviceID
        return (persistentKey, true)
    }

    private func validatedDeviceID(for identifier: String) -> AudioDeviceID? {
        if identifier.hasPrefix("uid:") {
            let uid = String(identifier.dropFirst(4))
            if let known = knownDeviceIDs[identifier] {
                let live = hardware.persistentIdentifier(for: known)
                if live == uid { return known }
                if let live, !live.isEmpty {
                    knownDeviceIDs.removeValue(forKey: identifier)
                }
            }
            // A transient UID failure is not evidence that the previous
            // mapping disappeared. Resolve by UID, then verify before use.
            guard let found = hardware.deviceID(forPersistentIdentifier: uid),
                  hardware.persistentIdentifier(for: found) == uid
            else { return nil }
            knownDeviceIDs[identifier] = found
            if found != currentDeviceID { cachedDeviceIdentifiers[found] = uid }
            return found
        }
        guard let deviceID = knownDeviceIDs[identifier],
              cachedDeviceIdentifiers[deviceID] == nil,
              hardware.persistentIdentifier(for: deviceID) == nil,
              identifier == "session:\(deviceID)"
        else { return nil }
        return deviceID
    }

    private func validatedIdentity(
        for deviceID: AudioDeviceID,
        mustRemainDefault: Bool
    ) -> DeviceIdentity? {
        if mustRemainDefault, hardware.defaultInputDeviceID() != deviceID { return nil }
        let validation = validatedCurrentIdentity(for: deviceID)
        guard validation.matches else { return nil }
        let identity = DeviceIdentity(
            deviceID: deviceID,
            key: validation.key,
            mustRemainDefault: mustRemainDefault
        )
        guard identityStillMatches(identity) else { return nil }
        knownDeviceIDs[identity.key] = deviceID
        return identity
    }

    /// Re-checks identity against live hardware. Every write path calls this
    /// immediately before and after touching a device, so an AudioObjectID that has
    /// been recycled onto a different device can never receive this device's
    /// volume baseline.
    private func identityStillMatches(_ identity: DeviceIdentity) -> Bool {
        if identity.mustRemainDefault, hardware.defaultInputDeviceID() != identity.deviceID { return false }
        if identity.key.hasPrefix("uid:") {
            return hardware.persistentIdentifier(for: identity.deviceID).map { "uid:\($0)" } == identity.key
        }
        return cachedDeviceIdentifiers[identity.deviceID] == nil
            && hardware.persistentIdentifier(for: identity.deviceID) == nil
            && identity.key == "session:\(identity.deviceID)"
    }

    private func confirm(
        _ actual: MicrophoneState,
        desired: Bool,
        identity: DeviceIdentity,
        completingDeviceRestoration: Bool = false
    ) {
        guard identityStillMatches(identity), !pendingForcedWrites.contains(identity.key) else { return }
        if !desired, let target = pendingVolumeRestorations[identity.key] {
            guard identityStillMatches(identity),
                  let volumes = hardware.readVolumes(on: identity.deviceID),
                  !volumes.isEmpty
            else { return }
            let liveTarget = target.filter { volumes[$0.key] != nil }
            let observedTargets = volumes.filter { liveTarget[$0.key] != nil }
            guard AudioControlPolicy.restoredVolumesMatch(observedTargets, target: liveTarget) else { return }
            let gainOnly = !completingDeviceRestoration && pendingDesiredStates[identity.key] == nil
            let restoredSilentBaseline = AudioControlPolicy.volumesAreMuted(liveTarget)
                && (!hardware.hasMuteProperty(on: identity.deviceID) || hardware.readMute(on: identity.deviceID) == false)
            guard gainOnly || actual == .unmuted || restoredSilentBaseline,
                  identityStillMatches(identity)
            else { return }
            savedVolumes[identity.key] = (savedVolumes[identity.key] ?? [:]).merging(target) { _, restored in restored }
            persistSavedVolumes()
            setPendingVolumeRestoration(nil, for: identity.key)
        } else if actual.mutedValue != desired {
            return
        }
        clearPendingDesiredState(forIdentifier: identity.key)
        if completingDeviceRestoration {
            let preserveOwnership = pendingDeviceRestorations[identity.key]?.preserveOwnership == true
                && hardware.defaultInputDeviceID() == identity.deviceID
            if desired, !preserveOwnership { removeAppMuteOwnership(identity) }
            setDeviceRestoration(nil, for: identity.key)
        }
        if identity.mustRemainDefault {
            currentWriteFailed = false
        }
        if !desired {
            removeAppMuteOwnership(identity)
        }
    }

    private func migrateSessionState(for deviceID: AudioDeviceID, to persistentKey: String) {
        let sessionKey = "session:\(deviceID)"
        guard sessionKey != persistentKey else { return }
        if let volumes = savedVolumes.removeValue(forKey: sessionKey), savedVolumes[persistentKey] == nil {
            savedVolumes[persistentKey] = volumes
        }
        if appMutedDeviceIdentifiers.remove(sessionKey) != nil {
            appMutedDeviceIdentifiers.insert(persistentKey)
        }
        if let desired = pendingDesiredStates.removeValue(forKey: sessionKey) {
            pendingDesiredStates[persistentKey] = desired
        }
        if let target = pendingVolumeRestorations[sessionKey] {
            setPendingVolumeRestoration(nil, for: sessionKey)
            setPendingVolumeRestoration(target, for: persistentKey)
        }
        if pendingForcedWrites.remove(sessionKey) != nil {
            pendingForcedWrites.insert(persistentKey)
        }
        if let restoration = pendingDeviceRestorations.removeValue(forKey: sessionKey) {
            setDeviceRestoration(restoration, for: persistentKey)
        }
        if let active = activeTemporaryMute, active.identity.key == sessionKey {
            activeTemporaryMute = ActiveTemporaryMute(
                token: active.token,
                identity: DeviceIdentity(deviceID: deviceID, key: persistentKey, mustRemainDefault: true)
            )
        }
        if let accepted = acceptedPendingStates.removeValue(forKey: sessionKey) {
            acceptedPendingStates[persistentKey] = accepted
        }
        if acceptedDeviceRestorations.remove(sessionKey) != nil {
            acceptedDeviceRestorations.insert(persistentKey)
        }
        knownDeviceIDs.removeValue(forKey: sessionKey)
        persistSavedVolumes()
        persistAppMutedDeviceIdentifiers()
        persistPendingDesiredStates()
    }

    // MARK: - Persistence

    private func persistSavedVolumes() {
        persistVolumeSnapshots(savedVolumes, key: Self.savedVolumesDefaultsKey)
    }

    private func setPendingVolumeRestoration(_ target: InputVolumeSnapshot?, for identifier: String) {
        guard pendingVolumeRestorations[identifier] != target else { return }
        pendingVolumeRestorations[identifier] = target
        persistVolumeSnapshots(pendingVolumeRestorations, key: BruteDefaults.pendingInputVolumeRestorations)
    }

    private func persistVolumeSnapshots(_ snapshots: [String: InputVolumeSnapshot], key: String) {
        let persistent = snapshots.filter { $0.key.hasPrefix("uid:") }
        let encoded = persistent.mapValues { snapshot in
            Dictionary(uniqueKeysWithValues: snapshot.map { (String($0.key), Double($0.value)) })
        }
        defaults.set(encoded, forKey: key)
    }

    private func persistAppMutedDeviceIdentifiers() {
        let persistent = appMutedDeviceIdentifiers.filter { $0.hasPrefix("uid:") }
        defaults.set(Array(persistent).sorted(), forKey: Self.appMutedDevicesDefaultsKey)
    }

    private func setPendingDesiredState(_ desired: Bool, for identity: DeviceIdentity) {
        if pendingState(for: identity.key).map({ $0 != desired }) == true {
            // Supersede an accepted write even if its effect has not reached readback yet.
            pendingForcedWrites.insert(identity.key)
        }
        knownDeviceIDs[identity.key] = identity.deviceID
        pendingDesiredStates[identity.key] = desired
        persistPendingDesiredStates()
    }

    private func pendingState(for identifier: String) -> Bool? {
        if let desired = pendingDesiredStates[identifier] { return desired }
        if let desired = pendingDeviceRestorations[identifier]?.muted { return desired }
        return pendingVolumeRestorations[identifier] == nil ? nil : false
    }

    private func recordAcceptedDesiredState(_ desired: Bool, for identifier: String) {
        if pendingDesiredStates[identifier] != nil {
            acceptedPendingStates[identifier] = desired
        }
        if pendingForcedWrites.remove(identifier) != nil { persistPendingDesiredStates() }
    }

    private func setDeviceRestoration(_ restoration: DeviceRestoration?, for identifier: String) {
        guard pendingDeviceRestorations[identifier] != restoration else { return }
        pendingDeviceRestorations[identifier] = restoration
        acceptedDeviceRestorations.remove(identifier)
        let persistent = pendingDeviceRestorations.filter { Self.isPersistentKey($0.key) }.mapValues {
            ["muted": $0.muted, "preserveOwnership": $0.preserveOwnership]
        }
        defaults.set(persistent, forKey: BruteDefaults.pendingDeviceRestorations)
    }

    private func clearPendingDesiredState(forIdentifier identifier: String?) {
        guard let identifier else { return }
        pendingForcedWrites.remove(identifier)
        acceptedPendingStates.removeValue(forKey: identifier)
        if pendingDesiredStates.removeValue(forKey: identifier) != nil {
            persistPendingDesiredStates()
        }
    }

    private func persistPendingDesiredStates() {
        let persistent = pendingDesiredStates.reduce(into: [String: Any]()) { result, entry in
            guard Self.isPersistentKey(entry.key) else { return }
            // Keep the new intent and its reversal flag in one defaults entry.
            // Old unforced entries still decode as their original boolean.
            if pendingForcedWrites.contains(entry.key) {
                result[entry.key] = ["muted": entry.value, "force": true]
            } else {
                result[entry.key] = entry.value
            }
        }
        defaults.set(persistent, forKey: Self.pendingDesiredStatesDefaultsKey)
    }

    private static func loadVolumeSnapshots(from defaults: UserDefaults, key: String) -> [String: InputVolumeSnapshot] {
        guard let values = defaults.dictionary(forKey: key) else { return [:] }
        return values.reduce(into: [:]) { result, pair in
            guard isPersistentKey(pair.key) else { return }
            if let number = validNumericValue(pair.value) {
                let volume = number.floatValue
                if volume.isFinite, volume > 0, volume <= 1 {
                    result[pair.key] = [0: volume]
                }
                return
            }
            guard let encoded = pair.value as? [String: Any] else { return }
            var snapshot: InputVolumeSnapshot = [:]
            for element in encoded {
                guard let key = UInt32(element.key),
                      let number = validNumericValue(element.value)
                else { return }
                let volume = number.floatValue
                guard volume.isFinite, volume >= 0, volume <= 1 else { return }
                snapshot[key] = volume
            }
            if !snapshot.isEmpty,
               key == BruteDefaults.pendingInputVolumeRestorations || snapshot.values.contains(where: { $0 > 0 }) {
                result[pair.key] = snapshot
            }
        }
    }

    private static func loadAppMutedDeviceIdentifiers(from defaults: UserDefaults) -> Set<String> {
        let identifiers = defaults.array(forKey: appMutedDevicesDefaultsKey) as? [String] ?? []
        return Set(identifiers.filter(isPersistentKey))
    }

    private static func loadDesiredStates(from defaults: UserDefaults, key: String) -> [String: Bool] {
        guard let values = defaults.dictionary(forKey: key) else { return [:] }
        return values.reduce(into: [:]) { result, pair in
            guard isPersistentKey(pair.key),
                  let number = pair.value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID()
            else { return }
            result[pair.key] = number.boolValue
        }
    }

    private static func loadPendingWrites(from defaults: UserDefaults) -> (states: [String: Bool], forced: Set<String>) {
        var states = loadDesiredStates(from: defaults, key: pendingDesiredStatesDefaultsKey)
        var forced: Set<String> = []
        for (key, value) in defaults.dictionary(forKey: pendingDesiredStatesDefaultsKey) ?? [:] {
            guard isPersistentKey(key),
                  let record = value as? [String: NSNumber],
                  let muted = record["muted"], CFGetTypeID(muted) == CFBooleanGetTypeID(),
                  let force = record["force"], CFGetTypeID(force) == CFBooleanGetTypeID(), force.boolValue
            else { continue }
            states[key] = muted.boolValue
            forced.insert(key)
        }
        return (states, forced)
    }

    private static func loadDeviceRestorations(from defaults: UserDefaults) -> [String: DeviceRestoration] {
        let stored = defaults.dictionary(forKey: BruteDefaults.pendingDeviceRestorations) ?? [:]
        return stored.reduce(into: [:]) { result, pair in
            guard isPersistentKey(pair.key),
                  let record = pair.value as? [String: NSNumber],
                  let muted = record["muted"], CFGetTypeID(muted) == CFBooleanGetTypeID(),
                  let owned = record["preserveOwnership"], CFGetTypeID(owned) == CFBooleanGetTypeID()
            else { return }
            result[pair.key] = DeviceRestoration(muted: muted.boolValue, preserveOwnership: owned.boolValue)
        }
    }

    private static func validNumericValue(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number
    }

    /// Only persistent (`uid:`) keys are ever stored; a `session:` key is an
    /// AudioObjectID that the next launch may hand to a different device.
    private static func isPersistentKey(_ key: String) -> Bool {
        key.hasPrefix("uid:") && !key.dropFirst(4).isEmpty
    }

    // MARK: - Lifecycle observation

    private func observeDefaultDeviceChanges() {
        observesDefaultDevice = hardware.observeDefaultDeviceChanges { [weak self] in
            guard let self, self.observesSystemChanges else { return }
            self.handleDefaultDeviceChange()
        }
    }

    private func observeCurrentDeviceState() {
        let observesState = hardware.observeStateChanges(on: currentDeviceID) { [weak self] in
            guard let self, self.observesSystemChanges else { return }
            self.refreshState()
        }
        systemObservationIsHealthy = observesDefaultDevice && observesState
    }

    private func observeLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = NotificationObservation(
            center: center,
            name: NSWorkspace.willSleepNotification,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.observesSystemChanges else { return }
                self.prepareForSleep()
            }
        }
        wakeObserver = NotificationObservation(
            center: center,
            name: NSWorkspace.didWakeNotification,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.observesSystemChanges else { return }
                self.handleWake()
            }
        }
    }
}

/// Why Brute cannot currently verify or change the microphone, for the UI.
enum MicControlError: LocalizedError, Equatable {
    case noInputDevice
    case deviceControlsUnreadable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            "No input device is selected. Check your Mac's Sound settings."
        case .deviceControlsUnreadable:
            "The selected input device is not responding to level controls."
        case .writeFailed:
            "Brute couldn’t change the selected microphone."
        }
    }
}
