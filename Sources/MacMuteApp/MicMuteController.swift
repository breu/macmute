import AppKit
import CoreAudio
import Foundation

enum MicrophoneState: Equatable {
    case muted
    case unmuted
    case unavailable

    var mutedValue: Bool? {
        switch self {
        case .muted: true
        case .unmuted: false
        case .unavailable: nil
        }
    }
}

@MainActor
protocol AudioDeviceControlling: AnyObject {
    func defaultInputDeviceID() -> AudioDeviceID?
    func persistentIdentifier(for deviceID: AudioDeviceID) -> String
    func hasMuteProperty(on deviceID: AudioDeviceID) -> Bool
    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool
    func readMute(on deviceID: AudioDeviceID) -> Bool?
    func setMute(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool
    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool
    func readVolume(on deviceID: AudioDeviceID) -> Float32?
    func setVolume(_ volume: Float32, on deviceID: AudioDeviceID) -> Bool
    @discardableResult
    func observeDefaultDeviceChanges(_ handler: @escaping @MainActor () -> Void) -> Bool
    @discardableResult
    func observeStateChanges(on deviceID: AudioDeviceID?, _ handler: @escaping @MainActor () -> Void) -> Bool
}

@MainActor
final class CoreAudioDeviceController: AudioDeviceControlling {
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceChangeHandler: (@MainActor () -> Void)?
    private var stateListenerBlock: AudioObjectPropertyListenerBlock?
    private var stateListenerDeviceID: AudioDeviceID?
    private var stateListenerAddress: AudioObjectPropertyAddress?
    private var stateChangeHandler: (@MainActor () -> Void)?

    func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.defaultDeviceAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func persistentIdentifier(for deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var identifier: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &identifier)
        guard status == noErr, let identifier else { return "device-\(deviceID)" }
        return identifier.takeUnretainedValue() as String
    }

    func hasMuteProperty(on deviceID: AudioDeviceID) -> Bool {
        var address = Self.muteAddress
        return AudioObjectHasProperty(deviceID, &address)
    }

    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool {
        var address = Self.muteAddress
        return Self.isSettable(deviceID: deviceID, address: &address)
    }

    func readMute(on deviceID: AudioDeviceID) -> Bool? {
        var address = Self.muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    func setMute(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        var address = Self.muteAddress
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        ) == noErr
    }

    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool {
        var address = Self.volumeAddress
        return AudioObjectHasProperty(deviceID, &address)
            && Self.isSettable(deviceID: deviceID, address: &address)
    }

    func readVolume(on deviceID: AudioDeviceID) -> Float32? {
        var address = Self.volumeAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    func setVolume(_ volume: Float32, on deviceID: AudioDeviceID) -> Bool {
        var address = Self.volumeAddress
        var value = volume
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        ) == noErr
    }

    func observeDefaultDeviceChanges(_ handler: @escaping @MainActor () -> Void) -> Bool {
        defaultDeviceChangeHandler = handler
        guard defaultDeviceListenerBlock == nil else { return true }

        var address = Self.defaultDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.defaultDeviceChangeHandler?()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            NSLog("MacMute: failed to observe default input device changes (OSStatus %d)", status)
            return false
        }
        defaultDeviceListenerBlock = block
        return true
    }

    func observeStateChanges(
        on deviceID: AudioDeviceID?,
        _ handler: @escaping @MainActor () -> Void
    ) -> Bool {
        removeStateListener()
        stateChangeHandler = handler
        guard let deviceID else { return false }

        var address = hasMuteProperty(on: deviceID) ? Self.muteAddress : Self.volumeAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.stateChangeHandler?()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            NSLog("MacMute: failed to observe microphone state changes (OSStatus %d)", status)
            return false
        }
        stateListenerDeviceID = deviceID
        stateListenerAddress = address
        stateListenerBlock = block
        return true
    }

    private func removeStateListener() {
        guard let deviceID = stateListenerDeviceID,
              var address = stateListenerAddress,
              let block = stateListenerBlock
        else { return }
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        if status != noErr {
            NSLog("MacMute: failed to remove microphone state observer (OSStatus %d)", status)
        }
        stateListenerDeviceID = nil
        stateListenerAddress = nil
        stateListenerBlock = nil
    }

    private static func isSettable(
        deviceID: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    ) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

@MainActor
final class MicMuteController {
    static let shared = MicMuteController(hardware: CoreAudioDeviceController())

    private(set) var state: MicrophoneState
    var isMuted: Bool { state == .muted }
    var onStateChanged: ((MicrophoneState) -> Void)?

    private let hardware: AudioDeviceControlling
    private var savedVolumes: [String: Float32]
    private var appMutedDeviceIdentifiers: Set<String>
    private var knownDeviceIDs: [String: AudioDeviceID] = [:]
    private(set) var currentDeviceID: AudioDeviceID?
    private let defaults: UserDefaults
    private var statePollTimer: Timer?

    private let silenceThreshold: Float32 = 0.0001
    private let defaultExplicitUnmuteVolume: Float32 = 1.0
    private static let savedVolumesDefaultsKey = "MacMute.savedInputVolumes"
    private static let appMutedDevicesDefaultsKey = "MacMute.appMutedInputDevices"

    init(
        hardware: AudioDeviceControlling,
        observeSystemChanges: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        self.hardware = hardware
        self.defaults = defaults
        savedVolumes = Self.loadSavedVolumes(from: defaults)
        appMutedDeviceIdentifiers = Self.loadAppMutedDeviceIdentifiers(from: defaults)
        currentDeviceID = hardware.defaultInputDeviceID()
        state = currentDeviceID.map { Self.readState(on: $0, using: hardware) } ?? .unavailable
        if let currentDeviceID {
            remember(currentDeviceID)
        }
        if state == .unmuted, let currentDeviceID {
            removeAppMuteOwnership(for: currentDeviceID)
        }

        guard observeSystemChanges else { return }
        let observesDefaultDevice = hardware.observeDefaultDeviceChanges { [weak self] in
            self?.handleDefaultDeviceChange()
        }
        let observesState = hardware.observeStateChanges(on: currentDeviceID) { [weak self] in
            self?.refreshState()
        }
        if !observesDefaultDevice || !observesState {
            NSLog("MacMute: CoreAudio observation is incomplete; periodic verification remains active")
        }
        startStatePolling()
        observeWake()
    }

    @discardableResult
    func toggle() -> Bool {
        guard let muted = state.mutedValue else {
            refreshState()
            return false
        }
        return setMuted(!muted)
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        reconcileCurrentDeviceIfNeeded()
        guard let deviceID = currentDeviceID else {
            publish(.unavailable)
            return false
        }

        let succeeded = applyMute(muted, to: deviceID)
        let actual = Self.readState(on: deviceID, using: hardware)
        publish(actual)
        return succeeded && actual.mutedValue == muted
    }

    func handleWake() {
        if let deviceID = currentDeviceID, ownsMute(on: deviceID) {
            _ = applyMute(true, to: deviceID)
        }
        retryPendingRestorations(excluding: currentDeviceID)
        refreshState()
    }

    func handleDefaultDeviceChange() {
        let newDeviceID = hardware.defaultInputDeviceID()
        guard newDeviceID != currentDeviceID else {
            refreshState()
            return
        }

        let oldDeviceID = currentDeviceID
        let departingState = oldDeviceID.map { Self.readState(on: $0, using: hardware) } ?? state
        let shouldCarryMute = departingState == .muted
            || (departingState == .unavailable && state == .muted)
        if let oldDeviceID, ownsMute(on: oldDeviceID), !restoreAppOwnedMute(on: oldDeviceID) {
            NSLog("MacMute: could not restore departing input device; restoration remains queued")
        }

        currentDeviceID = newDeviceID
        if let newDeviceID {
            remember(newDeviceID)
        }
        let observesState = hardware.observeStateChanges(on: newDeviceID) { [weak self] in
            self?.refreshState()
        }
        if !observesState {
            startStatePolling()
        }

        guard let newDeviceID else {
            publish(.unavailable)
            return
        }
        if shouldCarryMute {
            _ = applyMute(true, to: newDeviceID)
        }
        publish(Self.readState(on: newDeviceID, using: hardware))
    }

    func refreshState() {
        reconcileCurrentDeviceIfNeeded()
        retryPendingRestorations(excluding: currentDeviceID)
        guard let deviceID = currentDeviceID else {
            publish(.unavailable)
            return
        }
        let actual = Self.readState(on: deviceID, using: hardware)
        if actual == .unmuted {
            removeAppMuteOwnership(for: deviceID)
        }
        publish(actual)
    }

    private func reconcileCurrentDeviceIfNeeded() {
        if hardware.defaultInputDeviceID() != currentDeviceID {
            handleDefaultDeviceChange()
        }
    }

    private func applyMute(_ muted: Bool, to deviceID: AudioDeviceID) -> Bool {
        if hardware.hasMuteProperty(on: deviceID) {
            guard hardware.isMuteSettable(on: deviceID),
                  let current = hardware.readMute(on: deviceID)
            else { return false }
            if current == muted {
                return true
            }
            guard hardware.setMute(muted, on: deviceID),
                  hardware.readMute(on: deviceID) == muted
            else { return false }
            if muted {
                addAppMuteOwnership(for: deviceID)
            } else {
                removeAppMuteOwnership(for: deviceID)
            }
            return true
        }

        guard hardware.isVolumeSettable(on: deviceID),
              let currentVolume = hardware.readVolume(on: deviceID)
        else { return false }

        if muted {
            if currentVolume <= silenceThreshold {
                return true
            }
            savedVolumes[volumeKey(for: deviceID)] = currentVolume
            persistSavedVolumes()
            guard hardware.setVolume(0, on: deviceID),
                  let verified = hardware.readVolume(on: deviceID),
                  verified <= silenceThreshold
            else { return false }
            addAppMuteOwnership(for: deviceID)
            return true
        }

        if currentVolume > silenceThreshold {
            removeAppMuteOwnership(for: deviceID)
            return true
        }
        let restoredVolume = savedVolumes[volumeKey(for: deviceID)] ?? defaultExplicitUnmuteVolume
        guard hardware.setVolume(restoredVolume, on: deviceID),
              let verified = hardware.readVolume(on: deviceID),
              verified > silenceThreshold
        else { return false }
        removeAppMuteOwnership(for: deviceID)
        return true
    }

    private func restoreAppOwnedMute(on deviceID: AudioDeviceID) -> Bool {
        let restored: Bool
        if hardware.hasMuteProperty(on: deviceID) {
            guard let currentlyMuted = hardware.readMute(on: deviceID) else { return false }
            restored = !currentlyMuted
                || (hardware.isMuteSettable(on: deviceID)
                    && hardware.setMute(false, on: deviceID)
                    && hardware.readMute(on: deviceID) == false)
        } else if hardware.isVolumeSettable(on: deviceID) {
            guard let currentVolume = hardware.readVolume(on: deviceID) else { return false }
            let volume = savedVolumes[volumeKey(for: deviceID)] ?? defaultExplicitUnmuteVolume
            restored = currentVolume > silenceThreshold
                || (hardware.setVolume(volume, on: deviceID)
                    && (hardware.readVolume(on: deviceID) ?? 0) > silenceThreshold)
        } else {
            restored = false
        }
        if restored {
            removeAppMuteOwnership(for: deviceID)
        }
        return restored
    }

    private func ownsMute(on deviceID: AudioDeviceID) -> Bool {
        appMutedDeviceIdentifiers.contains(volumeKey(for: deviceID))
    }

    private func addAppMuteOwnership(for deviceID: AudioDeviceID) {
        let identifier = volumeKey(for: deviceID)
        knownDeviceIDs[identifier] = deviceID
        if appMutedDeviceIdentifiers.insert(identifier).inserted {
            persistAppMutedDeviceIdentifiers()
        }
    }

    private func removeAppMuteOwnership(for deviceID: AudioDeviceID) {
        let identifier = volumeKey(for: deviceID)
        knownDeviceIDs[identifier] = deviceID
        if appMutedDeviceIdentifiers.remove(identifier) != nil {
            persistAppMutedDeviceIdentifiers()
        }
    }

    private func remember(_ deviceID: AudioDeviceID) {
        knownDeviceIDs[volumeKey(for: deviceID)] = deviceID
    }

    private func retryPendingRestorations(excluding excludedDeviceID: AudioDeviceID?) {
        let pending = appMutedDeviceIdentifiers.compactMap { identifier -> AudioDeviceID? in
            guard let deviceID = knownDeviceIDs[identifier], deviceID != excludedDeviceID else { return nil }
            return deviceID
        }
        for deviceID in pending {
            _ = restoreAppOwnedMute(on: deviceID)
        }
    }

    private func publish(_ newState: MicrophoneState) {
        guard newState != state else { return }
        state = newState
        onStateChanged?(newState)
    }

    private func volumeKey(for deviceID: AudioDeviceID) -> String {
        hardware.persistentIdentifier(for: deviceID)
    }

    private func persistSavedVolumes() {
        defaults.set(savedVolumes.mapValues(Double.init), forKey: Self.savedVolumesDefaultsKey)
    }

    private func persistAppMutedDeviceIdentifiers() {
        defaults.set(Array(appMutedDeviceIdentifiers).sorted(), forKey: Self.appMutedDevicesDefaultsKey)
    }

    private func startStatePolling() {
        guard statePollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statePollTimer = nil
                self.refreshState()
                self.startStatePolling()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statePollTimer = timer
    }

    private static func loadSavedVolumes(from defaults: UserDefaults) -> [String: Float32] {
        guard let values = defaults.dictionary(forKey: savedVolumesDefaultsKey) else { return [:] }
        return values.reduce(into: [:]) { result, pair in
            if let number = pair.value as? NSNumber {
                let volume = number.floatValue
                if volume > 0, volume <= 1 {
                    result[pair.key] = volume
                }
            }
        }
    }

    private static func loadAppMutedDeviceIdentifiers(from defaults: UserDefaults) -> Set<String> {
        let identifiers = defaults.array(forKey: appMutedDevicesDefaultsKey) as? [String] ?? []
        return Set(identifiers.filter { !$0.isEmpty })
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MicMuteController.shared.handleWake()
            }
        }
    }

    private static func readState(
        on deviceID: AudioDeviceID,
        using hardware: AudioDeviceControlling
    ) -> MicrophoneState {
        if hardware.hasMuteProperty(on: deviceID) {
            guard let muted = hardware.readMute(on: deviceID) else { return .unavailable }
            return muted ? .muted : .unmuted
        }
        guard let volume = hardware.readVolume(on: deviceID) else { return .unavailable }
        return volume <= 0.0001 ? .muted : .unmuted
    }
}
