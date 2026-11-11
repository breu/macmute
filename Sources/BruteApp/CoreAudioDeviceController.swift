import AppKit
import CoreAudio
import Foundation

/// The hardware boundary: everything that talks to CoreAudio.
///
/// `MicMuteController` owns gesture state, device transfers and restoration; this
/// type owns only property reads/writes and observation, so the state machine can
/// be exercised against a fake.
@MainActor
protocol AudioDeviceControlling: AnyObject {
    func defaultInputDeviceID() -> AudioDeviceID?
    func persistentIdentifier(for deviceID: AudioDeviceID) -> String?
    func deviceID(forPersistentIdentifier identifier: String) -> AudioDeviceID?
    func hasMuteProperty(on deviceID: AudioDeviceID) -> Bool
    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool
    func readMute(on deviceID: AudioDeviceID) -> Bool?
    func setMute(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool
    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool
    func readVolumes(on deviceID: AudioDeviceID) -> InputVolumeSnapshot?
    func setVolumes(_ volumes: InputVolumeSnapshot, on deviceID: AudioDeviceID) -> Bool
    /// Drops cached control-capability discovery, for one device or for all of them.
    /// Anything that can change what a device exposes must come through here.
    func invalidateControlCaches(for deviceID: AudioDeviceID?)
    @discardableResult
    func observeDefaultDeviceChanges(_ handler: @escaping @MainActor () -> Void) -> Bool
    @discardableResult
    func observeStateChanges(on deviceID: AudioDeviceID?, _ handler: @escaping @MainActor () -> Void) -> Bool
    /// Stops observation and releases listener blocks. Safe to call more than once.
    func shutdown()
}

@MainActor
final class CoreAudioDeviceController: AudioDeviceControlling {
    private var defaultDeviceListener: PropertyListener?
    private var defaultDeviceChangeHandler: (@MainActor () -> Void)?
    private var stateListener: PropertyListener?
    private var stateChangeHandler: (@MainActor () -> Void)?

    private struct ControlAddresses {
        let readable: [AudioObjectPropertyAddress]
        let writable: [AudioObjectPropertyAddress]
    }

    private struct DeviceInventory {
        let controls: [AudioObjectPropertySelector: ControlAddresses]
        let resolvedAt: TimeInterval
    }

    /// Retains the exact registrations CoreAudio requires for removal.
    private final class PropertyListener {
        let id: UUID
        private let deviceID: AudioObjectID
        private let addresses: [AudioObjectPropertyAddress]
        private let block: AudioObjectPropertyListenerBlock

        init(
            id: UUID,
            deviceID: AudioObjectID,
            addresses: [AudioObjectPropertyAddress],
            block: @escaping AudioObjectPropertyListenerBlock
        ) {
            self.id = id
            self.deviceID = deviceID
            self.addresses = addresses
            self.block = block
        }

        deinit {
            for var address in addresses {
                let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
                if status != noErr && status != kAudioHardwareBadObjectError {
                    BruteLog.audio.error("Failed to remove CoreAudio observer (OSStatus \(status))")
                }
            }
        }
    }

    /// Longest an inventory is trusted without an invalidating event. Keeps the
    /// polling fallback honest when listeners failed to register.
    private static let inventoryTimeToLive: TimeInterval = 2

    private var inventoryCache: [AudioDeviceID: DeviceInventory] = [:]
    private let uptime: () -> TimeInterval

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    // MARK: - Lifecycle

    /// Releases listeners and cached state even when the controller itself is retained.
    func shutdown() {
        stateListener = nil
        defaultDeviceListener = nil
        defaultDeviceChangeHandler = nil
        stateChangeHandler = nil
        inventoryCache.removeAll()
    }

    func invalidateControlCaches(for deviceID: AudioDeviceID?) {
        if let deviceID {
            inventoryCache.removeValue(forKey: deviceID)
        } else {
            inventoryCache.removeAll()
        }
    }

    // MARK: - Device identity

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

    func deviceID(forPersistentIdentifier identifier: String) -> AudioDeviceID? {
        let uid = identifier as CFString
        var qualifier = Unmanaged.passUnretained(uid)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withExtendedLifetime(uid) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout.size(ofValue: qualifier)), &qualifier, &size, &deviceID
            )
        }
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    // MARK: - Mute

    func hasMuteProperty(on deviceID: AudioDeviceID) -> Bool {
        !readableControlAddresses(selector: kAudioDevicePropertyMute, on: deviceID).isEmpty
    }

    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool {
        !writableControlAddresses(selector: kAudioDevicePropertyMute, on: deviceID).isEmpty
    }

    func readMute(on deviceID: AudioDeviceID) -> Bool? {
        let values = stateReadAddresses(selector: kAudioDevicePropertyMute, on: deviceID).map { address -> Bool? in
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
        return AudioControlPolicy.performAtomicWrite(
            elements: addresses.map(\.mElement),
            priorValues: priorValues,
            desiredValues: desiredValues
        ) { element, value in
            guard var address = addressesByElement[element] else { return false }
            var value = value
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value
            )
            if status != noErr {
                BruteLog.audio.error("CoreAudio mute write failed (OSStatus \(status))")
            }
            return status == noErr
        }
    }

    // MARK: - Volume

    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool {
        !writableControlAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID).isEmpty
    }

    func readVolumes(on deviceID: AudioDeviceID) -> InputVolumeSnapshot? {
        let addresses = stateReadAddresses(selector: kAudioDevicePropertyVolumeScalar, on: deviceID)
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
        return AudioControlPolicy.performAtomicWrite(
            elements: addresses.map(\.mElement),
            priorValues: prior,
            desiredValues: volumes
        ) { element, value in
            guard var address = addressesByElement[element] else { return false }
            var value = value
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            )
            if status != noErr {
                BruteLog.audio.error("CoreAudio volume write failed (OSStatus \(status))")
            }
            return status == noErr
        }
    }

    // MARK: - Observation

    func observeDefaultDeviceChanges(_ handler: @escaping @MainActor () -> Void) -> Bool {
        defaultDeviceChangeHandler = handler
        guard defaultDeviceListener == nil else { return true }

        var address = Self.defaultDeviceAddress
        let id = UUID()
        let deviceID = AudioObjectID(kAudioObjectSystemObject)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.defaultDeviceListener?.id == id else { return }
                self.invalidateControlCaches(for: nil)
                self.defaultDeviceChangeHandler?()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        guard status == noErr else {
            BruteLog.audio.error("Failed to observe default input device changes (OSStatus \(status))")
            return false
        }
        defaultDeviceListener = PropertyListener(id: id, deviceID: deviceID, addresses: [address], block: block)
        return true
    }

    func observeStateChanges(
        on deviceID: AudioDeviceID?,
        _ handler: @escaping @MainActor () -> Void
    ) -> Bool {
        stateListener = nil
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

        let id = UUID()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.stateListener?.id == id else { return }
                self.invalidateControlCaches(for: deviceID)
                self.stateChangeHandler?()
            }
        }
        let registered = addresses.filter { originalAddress in
            var address = originalAddress
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
            if status == noErr {
                return true
            }
            BruteLog.audio.error("Failed to observe microphone state changes (OSStatus \(status))")
            return false
        }
        guard !registered.isEmpty else { return false }
        stateListener = PropertyListener(id: id, deviceID: deviceID, addresses: registered, block: block)
        return registered.count == addresses.count
    }

    // MARK: - Control discovery

    private func inventory(on deviceID: AudioDeviceID) -> DeviceInventory {
        let now = uptime()
        if let cached = inventoryCache[deviceID],
           now - cached.resolvedAt < Self.inventoryTimeToLive {
            return cached
        }
        let inputElements = Self.inputChannelElements(on: deviceID)
        let selectors = [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar]
        let controls = Dictionary(uniqueKeysWithValues: selectors.map { selector in
            (selector, Self.buildControlAddresses(selector: selector, on: deviceID, inputElements: inputElements))
        })
        let resolved = DeviceInventory(controls: controls, resolvedAt: now)
        inventoryCache[deviceID] = resolved
        return resolved
    }

    private static func buildControlAddresses(
        selector: AudioObjectPropertySelector,
        on deviceID: AudioDeviceID,
        inputElements: [UInt32]
    ) -> ControlAddresses {
        let main = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var mainAvailabilityProbe = main
        let hasMain = AudioObjectHasProperty(deviceID, &mainAvailabilityProbe)
        var mainSettableProbe = main
        let mainIsSettable = hasMain && isSettable(deviceID: deviceID, address: &mainSettableProbe)
        if mainIsSettable {
            return ControlAddresses(readable: [main], writable: [main])
        }
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
            return isSettable(deviceID: deviceID, address: &address) ? element : nil
        })
        let availableElements = Set(channelAddressesByElement.keys)
        let readable = AudioControlPolicy.resolveReadableControlElements(
            mainAvailable: hasMain,
            inputElements: inputElements,
            availableChannelElements: availableElements
        )
        let writable = AudioControlPolicy.resolveWritableControlElements(
            mainAvailable: hasMain,
            mainSettable: mainIsSettable,
            inputElements: inputElements,
            availableChannelElements: availableElements,
            settableChannelElements: settableChannelElements
        )
        func address(for element: UInt32) -> AudioObjectPropertyAddress? {
            element == kAudioObjectPropertyElementMain ? main : channelAddressesByElement[element]
        }
        return ControlAddresses(
            readable: readable.compactMap(address(for:)),
            writable: writable.compactMap(address(for:))
        )
    }

    private func readableControlAddresses(
        selector: AudioObjectPropertySelector,
        on deviceID: AudioDeviceID
    ) -> [AudioObjectPropertyAddress] {
        inventory(on: deviceID).controls[selector]?.readable ?? []
    }

    /// Read the same complete set of channels used by a write. A read-only
    /// aggregate cannot supply prior values or readback for individual writes.
    private func stateReadAddresses(
        selector: AudioObjectPropertySelector,
        on deviceID: AudioDeviceID
    ) -> [AudioObjectPropertyAddress] {
        guard let addresses = inventory(on: deviceID).controls[selector] else { return [] }
        return addresses.writable.isEmpty ? addresses.readable : addresses.writable
    }

    private func writableControlAddresses(
        selector: AudioObjectPropertySelector,
        on deviceID: AudioDeviceID
    ) -> [AudioObjectPropertyAddress] {
        inventory(on: deviceID).controls[selector]?.writable ?? []
    }

    private static func inputChannelElements(on deviceID: AudioDeviceID) -> [UInt32] {
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
