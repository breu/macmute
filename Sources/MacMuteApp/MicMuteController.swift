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

typealias InputVolumeSnapshot = [UInt32: Float32]

@MainActor
protocol AudioDeviceControlling: AnyObject {
    func defaultInputDeviceID() -> AudioDeviceID?
    func persistentIdentifier(for deviceID: AudioDeviceID) -> String?
    func hasMuteProperty(on deviceID: AudioDeviceID) -> Bool
    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool
    func readMute(on deviceID: AudioDeviceID) -> Bool?
    func setMute(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool
    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool
    func readVolumes(on deviceID: AudioDeviceID) -> InputVolumeSnapshot?
    func setVolumes(_ volumes: InputVolumeSnapshot, on deviceID: AudioDeviceID) -> Bool
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
    private var stateListenerAddresses: [AudioObjectPropertyAddress] = []
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

    func persistentIdentifier(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var identifier: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &identifier)
        guard status == noErr, let identifier else { return nil }
        return identifier.takeRetainedValue() as String
    }

    func hasMuteProperty(on deviceID: AudioDeviceID) -> Bool {
        !controlAddresses(selector: kAudioDevicePropertyMute, on: deviceID).isEmpty
    }

    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool {
        let addresses = controlAddresses(selector: kAudioDevicePropertyMute, on: deviceID)
        return !addresses.isEmpty && addresses.allSatisfy { address in
            var address = address
            return Self.isSettable(deviceID: deviceID, address: &address)
        }
    }

    func readMute(on deviceID: AudioDeviceID) -> Bool? {
        let values = controlAddresses(selector: kAudioDevicePropertyMute, on: deviceID).map { address -> Bool? in
            var address = address
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
            return status == noErr ? value != 0 : nil
        }
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.allSatisfy { $0 == true }
    }

    func setMute(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        let addresses = controlAddresses(selector: kAudioDevicePropertyMute, on: deviceID)
        guard !addresses.isEmpty else { return false }
        var priorValues: [UInt32: UInt32] = [:]
        for address in addresses {
            var address = address
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
                return false
            }
            priorValues[address.mElement] = value
        }
        var changed: [AudioObjectPropertyAddress] = []
        for originalAddress in addresses {
            var address = originalAddress
            var value: UInt32 = muted ? 1 : 0
            guard AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value
            ) == noErr else {
                rollbackMute(changed, to: priorValues, on: deviceID)
                return false
            }
            changed.append(originalAddress)
        }
        return true
    }

    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool {
        let addresses = controlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID)
        return !addresses.isEmpty && addresses.allSatisfy { address in
            var address = address
            return Self.isSettable(deviceID: deviceID, address: &address)
        }
    }

    func readVolumes(on deviceID: AudioDeviceID) -> InputVolumeSnapshot? {
        let addresses = controlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID)
        guard !addresses.isEmpty else { return nil }
        var result: InputVolumeSnapshot = [:]
        for originalAddress in addresses {
            var address = originalAddress
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
                  value.isFinite,
                  (0...1).contains(value)
            else { return nil }
            result[address.mElement] = value
        }
        return result
    }

    func setVolumes(_ volumes: InputVolumeSnapshot, on deviceID: AudioDeviceID) -> Bool {
        let addresses = controlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID)
        guard !addresses.isEmpty,
              Set(addresses.map(\.mElement)) == Set(volumes.keys),
              volumes.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let prior = readVolumes(on: deviceID)
        else { return false }
        var changed: [AudioObjectPropertyAddress] = []
        for originalAddress in addresses {
            var address = originalAddress
            var value = volumes[address.mElement]!
            guard AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            ) == noErr else {
                rollbackVolumes(changed, to: prior, on: deviceID)
                return false
            }
            changed.append(originalAddress)
        }
        return true
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

        var addresses = controlAddresses(selector: kAudioDevicePropertyMute, on: deviceID)
        if addresses.isEmpty || !isMuteSettable(on: deviceID) {
            addresses.append(contentsOf: controlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID))
        }
        guard !addresses.isEmpty else { return false }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.stateChangeHandler?()
            }
        }
        var allRegistered = true
        for originalAddress in addresses {
            var address = originalAddress
            let status = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                DispatchQueue.main,
                block
            )
            if status == noErr {
                stateListenerAddresses.append(originalAddress)
            } else {
                allRegistered = false
                NSLog("MacMute: failed to observe microphone state changes (OSStatus %d)", status)
            }
        }
        guard !stateListenerAddresses.isEmpty else { return false }
        stateListenerDeviceID = deviceID
        stateListenerBlock = block
        return allRegistered
    }

    private func removeStateListener() {
        guard let deviceID = stateListenerDeviceID,
              let block = stateListenerBlock
        else { return }
        for originalAddress in stateListenerAddresses {
            var address = originalAddress
            let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            if status != noErr {
                NSLog("MacMute: failed to remove microphone state observer (OSStatus %d)", status)
            }
        }
        stateListenerDeviceID = nil
        stateListenerAddresses = []
        stateListenerBlock = nil
    }

    private func controlAddresses(
        selector: AudioObjectPropertySelector,
        on deviceID: AudioDeviceID
    ) -> [AudioObjectPropertyAddress] {
        var main = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasMain = AudioObjectHasProperty(deviceID, &main)
        var mainForSettableCheck = main
        if hasMain, Self.isSettable(deviceID: deviceID, address: &mainForSettableCheck) {
            return [main]
        }
        let channelAddresses = inputChannelElements(on: deviceID).compactMap { element in
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            return AudioObjectHasProperty(deviceID, &address) ? address : nil
        }
        if !channelAddresses.isEmpty,
           channelAddresses.allSatisfy({ originalAddress in
               var address = originalAddress
               return Self.isSettable(deviceID: deviceID, address: &address)
           }) {
            return channelAddresses
        }
        return hasMain ? [main] : channelAddresses
    }

    private func inputChannelElements(on deviceID: AudioDeviceID) -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size
        else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return []
        }
        let channelCount = UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channelCount > 0 else { return [] }
        return (1...channelCount).map(UInt32.init)
    }

    private func rollbackMute(
        _ addresses: [AudioObjectPropertyAddress],
        to priorValues: [UInt32: UInt32],
        on deviceID: AudioDeviceID
    ) {
        for originalAddress in addresses {
            guard var value = priorValues[originalAddress.mElement] else { continue }
            var address = originalAddress
            _ = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value
            )
        }
    }

    private func rollbackVolumes(
        _ addresses: [AudioObjectPropertyAddress],
        to priorValues: InputVolumeSnapshot,
        on deviceID: AudioDeviceID
    ) {
        for originalAddress in addresses {
            guard var value = priorValues[originalAddress.mElement] else { continue }
            var address = originalAddress
            _ = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            )
        }
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


}

@MainActor
final class MicMuteController {
    static let shared = MicMuteController(hardware: CoreAudioDeviceController())

    private(set) var state: MicrophoneState
    var isMuted: Bool { state == .muted }
    var onStateChanged: ((MicrophoneState) -> Void)?

    private let hardware: AudioDeviceControlling
    private var savedVolumes: [String: InputVolumeSnapshot]
    private var appMutedDeviceIdentifiers: Set<String>
    private var pendingDesiredStates: [String: Bool]
    private var knownDeviceIDs: [String: AudioDeviceID] = [:]
    private var cachedDeviceIdentifiers: [AudioDeviceID: String] = [:]
    private var pendingDesiredStateAcrossUnavailableDevice: Bool?
    private(set) var currentDeviceID: AudioDeviceID?
    private let defaults: UserDefaults
    private var statePollTimer: Timer?

    private let defaultExplicitUnmuteVolume: Float32 = 1.0
    private static let savedVolumesDefaultsKey = "MacMute.savedInputVolumes"
    private static let appMutedDevicesDefaultsKey = "MacMute.appMutedInputDevices"
    private static let pendingDesiredStatesDefaultsKey = "MacMute.pendingInputStates"

    init(
        hardware: AudioDeviceControlling,
        observeSystemChanges: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        self.hardware = hardware
        self.defaults = defaults
        savedVolumes = Self.loadSavedVolumes(from: defaults)
        appMutedDeviceIdentifiers = Self.loadAppMutedDeviceIdentifiers(from: defaults)
        pendingDesiredStates = Self.loadPendingDesiredStates(from: defaults)
        currentDeviceID = hardware.defaultInputDeviceID()
        state = currentDeviceID.map { Self.readState(on: $0, using: hardware) } ?? .unavailable
        if let currentDeviceID {
            remember(currentDeviceID)
            retryPendingDesiredStates()
            state = Self.readState(on: currentDeviceID, using: hardware)
        }
        if state == .unmuted,
           let currentDeviceID,
           pendingDesiredState(for: currentDeviceID) != true {
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
        refreshState()
        guard let muted = state.mutedValue else {
            return false
        }
        return setMuted(!muted)
    }

    @discardableResult
    func setMuted(_ muted: Bool, retryOnFailure: Bool = false) -> Bool {
        reconcileCurrentDeviceIfNeeded()
        guard let deviceID = currentDeviceID else {
            if retryOnFailure {
                pendingDesiredStateAcrossUnavailableDevice = muted
            }
            publish(.unavailable)
            return false
        }

        if retryOnFailure {
            setPendingDesiredState(muted, for: deviceID)
        } else {
            clearPendingDesiredState(for: deviceID)
        }

        let succeeded = applyMute(muted, to: deviceID)
        let actual = Self.readState(on: deviceID, using: hardware)
        if succeeded, actual.mutedValue == muted {
            clearPendingDesiredState(for: deviceID)
        }
        publish(actual)
        return succeeded && actual.mutedValue == muted
    }

    func prepareForSleep() {
        guard let deviceID = currentDeviceID, ownsMute(on: deviceID) else { return }
        setPendingDesiredState(true, for: deviceID)
    }

    func handleWake() {
        if let deviceID = currentDeviceID,
           ownsMute(on: deviceID) || pendingDesiredState(for: deviceID) == true {
            _ = setMuted(true, retryOnFailure: true)
        }
        retryPendingDesiredStates()
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
        let oldIdentity = oldDeviceID.map { validatedCurrentIdentity(for: $0) }
        let departingState = oldDeviceID.flatMap { deviceID in
            oldIdentity?.matches == true ? Self.readState(on: deviceID, using: hardware) : nil
        } ?? state
        let departingPendingState = oldIdentity.flatMap { pendingDesiredStates[$0.key] }
        let desiredStateToCarry = pendingDesiredStateAcrossUnavailableDevice
            ?? departingPendingState
            ?? ((departingState == .muted || (departingState == .unavailable && state == .muted)) ? true : nil)
        if let oldDeviceID {
            if departingPendingState != nil {
                clearPendingDesiredState(forIdentifier: oldIdentity?.key)
            }
            if oldIdentity?.matches == true,
               departingPendingState != true,
               ownsMute(on: oldDeviceID),
               !restoreAppOwnedMute(on: oldDeviceID) {
                NSLog("MacMute: could not restore departing input device; restoration remains queued")
            } else if oldIdentity?.matches == false,
                      let key = oldIdentity?.key,
                      knownDeviceIDs[key] == oldDeviceID {
                knownDeviceIDs.removeValue(forKey: key)
            }
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
            pendingDesiredStateAcrossUnavailableDevice = desiredStateToCarry
            publish(.unavailable)
            return
        }
        pendingDesiredStateAcrossUnavailableDevice = nil
        if let desiredState = desiredStateToCarry {
            setPendingDesiredState(desiredState, for: newDeviceID)
            let succeeded = applyMute(desiredState, to: newDeviceID)
            if succeeded, Self.readState(on: newDeviceID, using: hardware).mutedValue == desiredState {
                clearPendingDesiredState(for: newDeviceID)
            }
        }
        publish(Self.readState(on: newDeviceID, using: hardware))
    }

    func refreshState() {
        reconcileCurrentDeviceIfNeeded()
        retryPendingDesiredStates()
        retryPendingRestorations(excluding: currentDeviceID)
        guard let deviceID = currentDeviceID else {
            publish(.unavailable)
            return
        }
        let actual = Self.readState(on: deviceID, using: hardware)
        if let desired = pendingDesiredState(for: deviceID), actual.mutedValue == desired {
            clearPendingDesiredState(for: deviceID)
        }
        if actual == .unmuted, pendingDesiredState(for: deviceID) != true {
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
        let hasNativeMute = hardware.hasMuteProperty(on: deviceID)
        let nativeMuteIsSettable = hasNativeMute && hardware.isMuteSettable(on: deviceID)
        if nativeMuteIsSettable {
            guard let current = hardware.readMute(on: deviceID) else { return false }
            if current == muted {
                if !muted {
                    removeAppMuteOwnership(for: deviceID)
                }
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

        if hasNativeMute {
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
            if Self.volumesAreMuted(currentVolumes) {
                return true
            }
            savedVolumes[volumeKey(for: deviceID)] = currentVolumes
            persistSavedVolumes()
            let mutedVolumes = currentVolumes.mapValues { _ in Float32(0) }
            guard hardware.setVolumes(mutedVolumes, on: deviceID),
                  let verified = hardware.readVolumes(on: deviceID),
                  Self.volumesAreMuted(verified)
            else { return false }
            addAppMuteOwnership(for: deviceID)
            return true
        }

        if !Self.volumesAreMuted(currentVolumes) {
            removeAppMuteOwnership(for: deviceID)
            return true
        }
        let restoredVolumes = savedVolumes[volumeKey(for: deviceID)]
            ?? currentVolumes.mapValues { _ in defaultExplicitUnmuteVolume }
        guard Set(restoredVolumes.keys) == Set(currentVolumes.keys),
              hardware.setVolumes(restoredVolumes, on: deviceID),
              let verified = hardware.readVolumes(on: deviceID),
              Self.volumesMatch(verified, restoredVolumes)
        else { return false }
        removeAppMuteOwnership(for: deviceID)
        return true
    }

    private func restoreAppOwnedMute(on deviceID: AudioDeviceID) -> Bool {
        let restored: Bool
        let hasNativeMute = hardware.hasMuteProperty(on: deviceID)
        if hasNativeMute,
           hardware.isMuteSettable(on: deviceID),
           let currentlyMuted = hardware.readMute(on: deviceID) {
            restored = !currentlyMuted
                || (hardware.setMute(false, on: deviceID)
                    && hardware.readMute(on: deviceID) == false)
        } else if hardware.isVolumeSettable(on: deviceID) {
            if hasNativeMute, hardware.readMute(on: deviceID) != false {
                return false
            }
            guard let currentVolumes = hardware.readVolumes(on: deviceID), !currentVolumes.isEmpty else {
                return false
            }
            let volumes = savedVolumes[volumeKey(for: deviceID)]
                ?? currentVolumes.mapValues { _ in defaultExplicitUnmuteVolume }
            restored = !Self.volumesAreMuted(currentVolumes)
                || (Set(volumes.keys) == Set(currentVolumes.keys)
                    && hardware.setVolumes(volumes, on: deviceID)
                    && hardware.readVolumes(on: deviceID).map { Self.volumesMatch($0, volumes) } == true)
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
        let pending = Array(appMutedDeviceIdentifiers).compactMap { identifier -> AudioDeviceID? in
            guard let deviceID = validatedDeviceID(for: identifier), deviceID != excludedDeviceID else { return nil }
            return deviceID
        }
        for deviceID in pending {
            _ = restoreAppOwnedMute(on: deviceID)
        }
    }

    private func retryPendingDesiredStates() {
        let pending = Array(pendingDesiredStates).compactMap { identifier, desired -> (AudioDeviceID, Bool)? in
            guard let deviceID = validatedDeviceID(for: identifier) else { return nil }
            return (deviceID, desired)
        }
        for (deviceID, desired) in pending {
            let succeeded = applyMute(desired, to: deviceID)
            if succeeded, Self.readState(on: deviceID, using: hardware).mutedValue == desired {
                clearPendingDesiredState(for: deviceID)
            }
        }
    }

    private func publish(_ newState: MicrophoneState) {
        guard newState != state else { return }
        state = newState
        onStateChanged?(newState)
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
        if let cached = cachedDeviceIdentifiers[deviceID] {
            let key = "uid:\(cached)"
            knownDeviceIDs[key] = deviceID
            return key
        }
        let key = "session:\(deviceID)"
        knownDeviceIDs[key] = deviceID
        return key
    }

    private func validatedCurrentIdentity(for deviceID: AudioDeviceID) -> (key: String, matches: Bool) {
        if let cached = cachedDeviceIdentifiers[deviceID] {
            let cachedKey = "uid:\(cached)"
            guard let live = hardware.persistentIdentifier(for: deviceID), !live.isEmpty else {
                return (cachedKey, true)
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
        guard let deviceID = knownDeviceIDs[identifier] else { return nil }
        guard volumeKey(for: deviceID) == identifier else {
            if knownDeviceIDs[identifier] == deviceID {
                knownDeviceIDs.removeValue(forKey: identifier)
            }
            return nil
        }
        return deviceID
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
        knownDeviceIDs.removeValue(forKey: sessionKey)
        persistSavedVolumes()
        persistAppMutedDeviceIdentifiers()
        persistPendingDesiredStates()
    }

    private func persistSavedVolumes() {
        let persistent = savedVolumes.filter { $0.key.hasPrefix("uid:") }
        let encoded = persistent.mapValues { snapshot in
            Dictionary(uniqueKeysWithValues: snapshot.map { (String($0.key), Double($0.value)) })
        }
        defaults.set(encoded, forKey: Self.savedVolumesDefaultsKey)
    }

    private func persistAppMutedDeviceIdentifiers() {
        let persistent = appMutedDeviceIdentifiers.filter { $0.hasPrefix("uid:") }
        defaults.set(Array(persistent).sorted(), forKey: Self.appMutedDevicesDefaultsKey)
    }

    private func pendingDesiredState(for deviceID: AudioDeviceID) -> Bool? {
        pendingDesiredStates[volumeKey(for: deviceID)]
    }

    private func setPendingDesiredState(_ desired: Bool, for deviceID: AudioDeviceID) {
        let identifier = volumeKey(for: deviceID)
        knownDeviceIDs[identifier] = deviceID
        pendingDesiredStates[identifier] = desired
        persistPendingDesiredStates()
    }

    private func clearPendingDesiredState(for deviceID: AudioDeviceID) {
        let identifier = volumeKey(for: deviceID)
        clearPendingDesiredState(forIdentifier: identifier)
    }

    private func clearPendingDesiredState(forIdentifier identifier: String?) {
        guard let identifier,
              pendingDesiredStates.removeValue(forKey: identifier) != nil
        else { return }
        persistPendingDesiredStates()
    }

    private func persistPendingDesiredStates() {
        let persistent = pendingDesiredStates.filter { $0.key.hasPrefix("uid:") }
        defaults.set(persistent, forKey: Self.pendingDesiredStatesDefaultsKey)
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

    private static func loadSavedVolumes(from defaults: UserDefaults) -> [String: InputVolumeSnapshot] {
        guard let values = defaults.dictionary(forKey: savedVolumesDefaultsKey) else { return [:] }
        return values.reduce(into: [:]) { result, pair in
            guard pair.key.hasPrefix("uid:") else { return }
            if let number = pair.value as? NSNumber {
                let volume = number.floatValue
                if volume.isFinite, volume > 0, volume <= 1 {
                    result[pair.key] = [0: volume]
                }
                return
            }
            guard let encoded = pair.value as? [String: Any] else { return }
            let snapshot = encoded.reduce(into: InputVolumeSnapshot()) { snapshot, element in
                guard let key = UInt32(element.key),
                      let number = element.value as? NSNumber
                else { return }
                let volume = number.floatValue
                guard volume.isFinite, volume >= 0, volume <= 1 else { return }
                snapshot[key] = volume
            }
            if !snapshot.isEmpty, snapshot.values.contains(where: { $0 > 0 }) {
                result[pair.key] = snapshot
            }
        }
    }

    private static func loadAppMutedDeviceIdentifiers(from defaults: UserDefaults) -> Set<String> {
        let identifiers = defaults.array(forKey: appMutedDevicesDefaultsKey) as? [String] ?? []
        return Set(identifiers.filter { $0.hasPrefix("uid:") && $0.count > 4 })
    }

    private static func loadPendingDesiredStates(from defaults: UserDefaults) -> [String: Bool] {
        guard let values = defaults.dictionary(forKey: pendingDesiredStatesDefaultsKey) else { return [:] }
        return values.reduce(into: [:]) { result, pair in
            guard pair.key.hasPrefix("uid:"), let number = pair.value as? NSNumber else { return }
            result[pair.key] = number.boolValue
        }
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.prepareForSleep()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        }
    }

    private static func readState(
        on deviceID: AudioDeviceID,
        using hardware: AudioDeviceControlling
    ) -> MicrophoneState {
        let hasNativeMute = hardware.hasMuteProperty(on: deviceID)
        if hasNativeMute {
            if let muted = hardware.readMute(on: deviceID) {
                if muted { return .muted }
                if hardware.isMuteSettable(on: deviceID) { return .unmuted }
            } else if hardware.isMuteSettable(on: deviceID) {
                return .unavailable
            }
        }
        guard let volumes = hardware.readVolumes(on: deviceID), !volumes.isEmpty else { return .unavailable }
        if Self.volumesAreMuted(volumes) { return .muted }
        return hasNativeMute && hardware.readMute(on: deviceID) == nil ? .unavailable : .unmuted
    }

    private static func volumesAreMuted(_ volumes: InputVolumeSnapshot) -> Bool {
        !volumes.isEmpty && volumes.values.allSatisfy { $0 <= 0.0001 }
    }

    private static func volumesMatch(
        _ actual: InputVolumeSnapshot,
        _ expected: InputVolumeSnapshot
    ) -> Bool {
        guard Set(actual.keys) == Set(expected.keys) else { return false }
        return expected.allSatisfy { element, volume in
            guard let actualVolume = actual[element] else { return false }
            return abs(actualVolume - volume) <= 0.0001
        }
    }
}
