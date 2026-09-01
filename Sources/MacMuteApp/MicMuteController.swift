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
        !readableControlAddresses(selector: kAudioDevicePropertyMute, on: deviceID).isEmpty
    }

    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool {
        !writableControlAddresses(selector: kAudioDevicePropertyMute, on: deviceID).isEmpty
    }

    func readMute(on deviceID: AudioDeviceID) -> Bool? {
        let values = readableControlAddresses(selector: kAudioDevicePropertyMute, on: deviceID).map { address -> Bool? in
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
        let addresses = writableControlAddresses(selector: kAudioDevicePropertyMute, on: deviceID)
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
        let addressesByElement = Dictionary(uniqueKeysWithValues: addresses.map { ($0.mElement, $0) })
        let desiredValues = Dictionary(
            uniqueKeysWithValues: addresses.map { ($0.mElement, muted ? UInt32(1) : UInt32(0)) }
        )
        return Self.performAtomicWrite(
            elements: addresses.map(\.mElement),
            priorValues: priorValues,
            desiredValues: desiredValues
        ) { element, value in
            guard var address = addressesByElement[element] else { return false }
            var value = value
            return AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value
            ) == noErr
        }
    }

    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool {
        !writableControlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID).isEmpty
    }

    func readVolumes(on deviceID: AudioDeviceID) -> InputVolumeSnapshot? {
        let addresses = readableControlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID)
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
        let addresses = writableControlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID)
        guard !addresses.isEmpty,
              Set(addresses.map(\.mElement)) == Set(volumes.keys),
              volumes.values.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return false }
        var prior: InputVolumeSnapshot = [:]
        for originalAddress in addresses {
            var address = originalAddress
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
                  value.isFinite,
                  (0...1).contains(value)
            else { return false }
            prior[address.mElement] = value
        }
        let addressesByElement = Dictionary(uniqueKeysWithValues: addresses.map { ($0.mElement, $0) })
        return Self.performAtomicWrite(
            elements: addresses.map(\.mElement),
            priorValues: prior,
            desiredValues: volumes
        ) { element, value in
            guard var address = addressesByElement[element] else { return false }
            var value = value
            return AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            ) == noErr
        }
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

        var addresses = readableControlAddresses(selector: kAudioDevicePropertyMute, on: deviceID)
        addresses.append(contentsOf: writableControlAddresses(selector: kAudioDevicePropertyMute, on: deviceID))
        addresses.append(contentsOf: readableControlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID))
        addresses.append(contentsOf: writableControlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID))
        addresses = addresses.reduce(into: []) { result, address in
            guard !result.contains(where: {
                $0.mSelector == address.mSelector && $0.mScope == address.mScope && $0.mElement == address.mElement
            }) else { return }
            result.append(address)
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

    private func controlAddressInventory(
        selector: AudioObjectPropertySelector,
        on deviceID: AudioDeviceID
    ) -> (
        main: AudioObjectPropertyAddress,
        mainAvailable: Bool,
        mainSettable: Bool,
        inputElements: [UInt32],
        channels: [UInt32: AudioObjectPropertyAddress],
        settableChannels: Set<UInt32>
    ) {
        var main = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasMain = AudioObjectHasProperty(deviceID, &main)
        var mainForSettableCheck = main
        let mainIsSettable = hasMain && Self.isSettable(deviceID: deviceID, address: &mainForSettableCheck)
        let inputElements = inputChannelElements(on: deviceID)
        let channelAddressesByElement = Dictionary(uniqueKeysWithValues: inputElements.compactMap { element in
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            return AudioObjectHasProperty(deviceID, &address) ? (element, address) : nil
        })
        let settableChannelElements = Set(channelAddressesByElement.compactMap { element, originalAddress in
            var address = originalAddress
            return Self.isSettable(deviceID: deviceID, address: &address) ? element : nil
        })
        return (main, hasMain, mainIsSettable, inputElements, channelAddressesByElement, settableChannelElements)
    }

    private func readableControlAddresses(
        selector: AudioObjectPropertySelector,
        on deviceID: AudioDeviceID
    ) -> [AudioObjectPropertyAddress] {
        let inventory = controlAddressInventory(selector: selector, on: deviceID)
        let selectedElements = Self.resolveReadableControlElements(
            mainAvailable: inventory.mainAvailable,
            inputElements: inventory.inputElements,
            availableChannelElements: Set(inventory.channels.keys)
        )
        return selectedElements.compactMap { element in
            element == kAudioObjectPropertyElementMain ? inventory.main : inventory.channels[element]
        }
    }

    private func writableControlAddresses(
        selector: AudioObjectPropertySelector,
        on deviceID: AudioDeviceID
    ) -> [AudioObjectPropertyAddress] {
        let inventory = controlAddressInventory(selector: selector, on: deviceID)
        let selectedElements = Self.resolveWritableControlElements(
            mainAvailable: inventory.mainAvailable,
            mainSettable: inventory.mainSettable,
            inputElements: inventory.inputElements,
            availableChannelElements: Set(inventory.channels.keys),
            settableChannelElements: inventory.settableChannels
        )
        return selectedElements.compactMap { element in
            element == kAudioObjectPropertyElementMain ? inventory.main : inventory.channels[element]
        }
    }

    static func resolveReadableControlElements(
        mainAvailable: Bool,
        inputElements: [UInt32],
        availableChannelElements: Set<UInt32>
    ) -> [UInt32] {
        if mainAvailable { return [kAudioObjectPropertyElementMain] }
        let required = Set(inputElements)
        return !required.isEmpty && required.isSubset(of: availableChannelElements) ? inputElements : []
    }

    static func resolveWritableControlElements(
        mainAvailable: Bool,
        mainSettable: Bool,
        inputElements: [UInt32],
        availableChannelElements: Set<UInt32>,
        settableChannelElements: Set<UInt32>
    ) -> [UInt32] {
        if mainAvailable, mainSettable {
            return [kAudioObjectPropertyElementMain]
        }
        let required = Set(inputElements)
        if !required.isEmpty,
           required.isSubset(of: availableChannelElements),
           required.isSubset(of: settableChannelElements) {
            return inputElements
        }
        return []
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

    static func performAtomicWrite<Value>(
        elements: [UInt32],
        priorValues: [UInt32: Value],
        desiredValues: [UInt32: Value],
        write: (UInt32, Value) -> Bool
    ) -> Bool {
        guard Set(elements) == Set(priorValues.keys),
              Set(elements) == Set(desiredValues.keys)
        else { return false }
        var changed: [UInt32] = []
        for element in elements {
            guard let desired = desiredValues[element], write(element, desired) else {
                for changedElement in changed.reversed() {
                    if let prior = priorValues[changedElement] {
                        _ = write(changedElement, prior)
                    }
                }
                return false
            }
            changed.append(element)
        }
        return true
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

    private struct DeviceIdentity {
        let deviceID: AudioDeviceID
        let key: String
        let mustRemainDefault: Bool
    }

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
           let identity = validatedIdentity(for: currentDeviceID, mustRemainDefault: true),
           pendingDesiredStates[identity.key] != true {
            removeAppMuteOwnership(identity)
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
        guard let deviceID = currentDeviceID,
              let identity = validatedIdentity(for: deviceID, mustRemainDefault: true)
        else {
            if retryOnFailure {
                pendingDesiredStateAcrossUnavailableDevice = muted
            }
            publish(.unavailable)
            return false
        }

        setPendingDesiredState(muted, for: identity)
        let accepted = applyMute(muted, to: identity)
        guard identityStillMatches(identity) else {
            publish(.unavailable)
            return false
        }
        let actual = Self.readState(on: deviceID, using: hardware)
        confirm(actual, desired: muted, identity: identity)
        if !accepted, !retryOnFailure {
            clearPendingDesiredState(forIdentifier: identity.key)
        }
        publish(actual)
        return accepted
    }

    func prepareForSleep() {
        guard let deviceID = currentDeviceID,
              let identity = validatedIdentity(for: deviceID, mustRemainDefault: true),
              ownsMute(identity)
        else { return }
        setPendingDesiredState(true, for: identity)
    }

    func handleWake() {
        if let deviceID = currentDeviceID,
           let identity = validatedIdentity(for: deviceID, mustRemainDefault: true),
           ownsMute(identity) || pendingDesiredStates[identity.key] == true {
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
               let identity = validatedIdentity(for: oldDeviceID, mustRemainDefault: false),
               ownsMute(identity),
               !restoreAppOwnedMute(identity) {
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
            if let identity = validatedIdentity(for: newDeviceID, mustRemainDefault: true) {
                setPendingDesiredState(desiredState, for: identity)
                let accepted = applyMute(desiredState, to: identity)
                if accepted, identityStillMatches(identity) {
                    confirm(Self.readState(on: newDeviceID, using: hardware), desired: desiredState, identity: identity)
                }
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
        if let identity = validatedIdentity(for: deviceID, mustRemainDefault: true) {
            if let desired = pendingDesiredStates[identity.key] {
                confirm(actual, desired: desired, identity: identity)
            }
            if actual == .unmuted, pendingDesiredStates[identity.key] != true {
                removeAppMuteOwnership(identity)
            }
        }
        publish(actual)
    }

    private func reconcileCurrentDeviceIfNeeded() {
        if hardware.defaultInputDeviceID() != currentDeviceID {
            handleDefaultDeviceChange()
        }
    }

    private func applyMute(_ muted: Bool, to identity: DeviceIdentity) -> Bool {
        guard identityStillMatches(identity) else { return false }
        let deviceID = identity.deviceID
        let hasNativeMute = hardware.hasMuteProperty(on: deviceID)
        let nativeMuteIsSettable = hasNativeMute && hardware.isMuteSettable(on: deviceID)
        if nativeMuteIsSettable {
            guard let current = hardware.readMute(on: deviceID) else { return false }
            if current == muted, muted {
                return true
            }
            if current != muted {
                let alreadyOwned = ownsMute(identity)
                if muted { addAppMuteOwnership(identity) }
                guard identityStillMatches(identity), hardware.setMute(muted, on: deviceID) else {
                    if muted, !alreadyOwned { removeAppMuteOwnership(identity) }
                    return false
                }
                guard identityStillMatches(identity) else { return false }
                return true
            }
            if let volumes = hardware.readVolumes(on: deviceID), Self.volumesAreMuted(volumes) {
                // Continue so an explicit unmute also restores a fallback-zeroed volume.
            } else {
                removeAppMuteOwnership(identity)
                return true
            }
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
            savedVolumes[identity.key] = currentVolumes
            persistSavedVolumes()
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

        if !Self.volumesAreMuted(currentVolumes) {
            removeAppMuteOwnership(identity)
            return true
        }
        let restoredVolumes = restorationVolumes(
            saved: savedVolumes[identity.key],
            current: currentVolumes
        )
        guard identityStillMatches(identity), hardware.setVolumes(restoredVolumes, on: deviceID) else { return false }
        guard identityStillMatches(identity) else { return false }
        savedVolumes[identity.key] = restoredVolumes
        persistSavedVolumes()
        return true
    }

    private func restoreAppOwnedMute(_ identity: DeviceIdentity) -> Bool {
        guard identityStillMatches(identity) else { return false }
        let deviceID = identity.deviceID
        let restored: Bool
        let hasNativeMute = hardware.hasMuteProperty(on: deviceID)
        if hasNativeMute,
           hardware.isMuteSettable(on: deviceID),
           let currentlyMuted = hardware.readMute(on: deviceID) {
            restored = !currentlyMuted || hardware.setMute(false, on: deviceID)
        } else if hardware.isVolumeSettable(on: deviceID) {
            if hasNativeMute, hardware.readMute(on: deviceID) != false {
                return false
            }
            guard let currentVolumes = hardware.readVolumes(on: deviceID), !currentVolumes.isEmpty else {
                return false
            }
            let volumes = restorationVolumes(saved: savedVolumes[identity.key], current: currentVolumes)
            restored = !Self.volumesAreMuted(currentVolumes)
                || hardware.setVolumes(volumes, on: deviceID)
            if restored {
                savedVolumes[identity.key] = volumes
                persistSavedVolumes()
            }
        } else {
            restored = false
        }
        if restored, identityStillMatches(identity), Self.readState(on: deviceID, using: hardware) == .unmuted {
            removeAppMuteOwnership(identity)
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

    private func retryPendingRestorations(excluding excludedDeviceID: AudioDeviceID?) {
        let pending = Array(appMutedDeviceIdentifiers).compactMap { identifier -> AudioDeviceID? in
            guard let deviceID = validatedDeviceID(for: identifier), deviceID != excludedDeviceID else { return nil }
            return deviceID
        }
        for deviceID in pending {
            if let identity = validatedIdentity(for: deviceID, mustRemainDefault: false) {
                _ = restoreAppOwnedMute(identity)
            }
        }
    }

    private func retryPendingDesiredStates() {
        let pending = Array(pendingDesiredStates).compactMap { identifier, desired -> (DeviceIdentity, Bool)? in
            guard let deviceID = validatedDeviceID(for: identifier) else { return nil }
            let mustRemainDefault = deviceID == currentDeviceID
            guard let identity = validatedIdentity(for: deviceID, mustRemainDefault: mustRemainDefault),
                  identity.key == identifier
            else { return nil }
            return (identity, desired)
        }
        for (identity, desired) in pending {
            let accepted = applyMute(desired, to: identity)
            if accepted, identityStillMatches(identity) {
                confirm(Self.readState(on: identity.deviceID, using: hardware), desired: desired, identity: identity)
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
        guard let deviceID = knownDeviceIDs[identifier] else { return nil }
        let matches: Bool
        if identifier.hasPrefix("uid:") {
            matches = hardware.persistentIdentifier(for: deviceID).map { "uid:\($0)" } == identifier
        } else {
            matches = cachedDeviceIdentifiers[deviceID] == nil
                && hardware.persistentIdentifier(for: deviceID) == nil
                && identifier == "session:\(deviceID)"
        }
        guard matches else {
            if knownDeviceIDs[identifier] == deviceID {
                knownDeviceIDs.removeValue(forKey: identifier)
            }
            return nil
        }
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
        return identityStillMatches(identity) ? identity : nil
    }

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
        identity: DeviceIdentity
    ) {
        guard actual.mutedValue == desired else { return }
        clearPendingDesiredState(forIdentifier: identity.key)
        if !desired {
            removeAppMuteOwnership(identity)
        }
    }

    private func restorationVolumes(
        saved: InputVolumeSnapshot?,
        current: InputVolumeSnapshot
    ) -> InputVolumeSnapshot {
        Dictionary(uniqueKeysWithValues: current.keys.map { element in
            (element, saved?[element] ?? defaultExplicitUnmuteVolume)
        })
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

    private func setPendingDesiredState(_ desired: Bool, for identity: DeviceIdentity) {
        knownDeviceIDs[identity.key] = identity.deviceID
        pendingDesiredStates[identity.key] = desired
        persistPendingDesiredStates()
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
            if !snapshot.isEmpty, snapshot.values.contains(where: { $0 > 0 }) {
                result[pair.key] = snapshot
            }
        }
    }

    private static func loadAppMutedDeviceIdentifiers(from defaults: UserDefaults) -> Set<String> {
        let identifiers = defaults.array(forKey: appMutedDevicesDefaultsKey) as? [String] ?? []
        return Set(identifiers.filter(isPersistentKey))
    }

    private static func loadPendingDesiredStates(from defaults: UserDefaults) -> [String: Bool] {
        guard let values = defaults.dictionary(forKey: pendingDesiredStatesDefaultsKey) else { return [:] }
        return values.reduce(into: [:]) { result, pair in
            guard isPersistentKey(pair.key),
                  let number = pair.value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID()
            else { return }
            result[pair.key] = number.boolValue
        }
    }

    private static func validNumericValue(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number
    }

    private static func isPersistentKey(_ key: String) -> Bool {
        key.hasPrefix("uid:") && !key.dropFirst(4).isEmpty
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

    static func readState(
        on deviceID: AudioDeviceID,
        using hardware: AudioDeviceControlling
    ) -> MicrophoneState {
        let hasNativeMute = hardware.hasMuteProperty(on: deviceID)
        let nativeMute = hasNativeMute ? hardware.readMute(on: deviceID) : nil
        if nativeMute == true { return .muted }
        let volumes = hardware.readVolumes(on: deviceID)
        if let volumes, Self.volumesAreMuted(volumes) { return .muted }
        if nativeMute == false { return .unmuted }
        if !hasNativeMute, let volumes, !volumes.isEmpty { return .unmuted }
        return .unavailable
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
