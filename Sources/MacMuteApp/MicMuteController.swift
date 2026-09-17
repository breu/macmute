import AppKit
import CoreAudio
import Foundation

final class MicMuteController {

    static let shared = MicMuteController()

    private(set) var isMuted: Bool = false
    var onMuteStateChanged: ((Bool) -> Void)?

    /// Keyed by device, not a single slot — otherwise switching the default
    /// input device while fallback-muted overwrites one device's saved volume
    /// with another's, and neither ever gets restored correctly.
    private var savedVolumesByDevice: [AudioDeviceID: Float32] = [:]
    private var currentDeviceID: AudioDeviceID?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    private var externalChangeListenerDeviceID: AudioDeviceID?
    private var externalChangeListenerAddress: AudioObjectPropertyAddress?
    private var externalChangeListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        currentDeviceID = Self.defaultInputDeviceID()
        if let deviceID = currentDeviceID {
            isMuted = Self.currentHardwareMuteState(for: deviceID) ?? false
            addExternalChangeListener(for: deviceID)
        }
        observeDefaultDeviceChanges()
        observeWake()
    }

    /// CoreAudio can silently reset a device's hardware mute property during its
    /// own post-sleep reinitialization, leaving the actual mic state out of sync
    /// with what this controller (and the menu bar icon) believes. Re-applying the
    /// last-known `isMuted` value forces the hardware back in line without
    /// overriding whatever the user's actual last intent was.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.setMuted(self.isMuted)
        }
    }

    func toggle() {
        setMuted(!isMuted)
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        guard let deviceID = Self.defaultInputDeviceID() else { return false }
        guard applyMute(muted, to: deviceID) else { return false }
        isMuted = muted
        onMuteStateChanged?(muted)
        return true
    }

    // MARK: - Device change tracking

    private func observeDefaultDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let previousDeviceID = self.currentDeviceID
            let newDeviceID = Self.defaultInputDeviceID()
            self.currentDeviceID = newDeviceID
            guard newDeviceID != previousDeviceID else { return }

            self.removeExternalChangeListener()
            if let newDeviceID {
                self.addExternalChangeListener(for: newDeviceID)
            }

            // The outgoing device is no longer the input, so it shouldn't stay
            // silenced under us just because it used to be fallback-muted.
            if let previousDeviceID,
               let savedVolume = self.savedVolumesByDevice.removeValue(forKey: previousDeviceID) {
                Self.restoreVolume(savedVolume, on: previousDeviceID)
            }

            if self.isMuted, let newDeviceID {
                // The new default device may not actually be muted (unsupported
                // property, disconnected, transient error) — correct our tracked
                // state and the UI rather than assuming the reapply worked.
                if !self.applyMute(true, to: newDeviceID) {
                    self.isMuted = false
                    self.onMuteStateChanged?(false)
                }
            }
        }
        deviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    // MARK: - External change tracking

    /// `isMuted` is only ever authoritative right after we write it ourselves —
    /// another app, a hardware mute switch, or CoreAudio's own post-sleep reset
    /// can change the real device state without going through this controller
    /// at all. Listening for the underlying property directly (rather than
    /// polling) keeps the cached flag and the menu bar icon honest.
    private func addExternalChangeListener(for deviceID: AudioDeviceID) {
        if deviceSupportsMuteProperty(deviceID) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, let hardwareMuted = Self.currentHardwareMuteState(for: deviceID) else { return }
                guard hardwareMuted != self.isMuted else { return }
                self.isMuted = hardwareMuted
                self.onMuteStateChanged?(hardwareMuted)
            }
            AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            externalChangeListenerBlock = block
            externalChangeListenerAddress = address
            externalChangeListenerDeviceID = deviceID
        } else {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(deviceID, &address) else { return }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleExternalVolumeChange(on: deviceID)
            }
            AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            externalChangeListenerBlock = block
            externalChangeListenerAddress = address
            externalChangeListenerDeviceID = deviceID
        }
    }

    private func removeExternalChangeListener() {
        guard let deviceID = externalChangeListenerDeviceID,
              var address = externalChangeListenerAddress,
              let block = externalChangeListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        externalChangeListenerDeviceID = nil
        externalChangeListenerAddress = nil
        externalChangeListenerBlock = nil
    }

    /// A volume-fallback device has no real mute flag, so a 0 reading is
    /// inherently ambiguous (see `currentHardwareMuteState`) — but a volume
    /// that jumps back up while we believe we're the ones holding it at zero
    /// is unambiguous: something outside this controller restored it.
    private func handleExternalVolumeChange(on deviceID: AudioDeviceID) {
        guard isMuted, savedVolumesByDevice[deviceID] != nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard let currentVolume = Self.readVolume(deviceID, &address), currentVolume > 0.0001 else { return }
        savedVolumesByDevice[deviceID] = nil
        isMuted = false
        onMuteStateChanged?(false)
    }

    // MARK: - Mute application

    @discardableResult
    private func applyMute(_ muted: Bool, to deviceID: AudioDeviceID) -> Bool {
        if deviceSupportsMuteProperty(deviceID) {
            return setMuteProperty(muted, on: deviceID)
        } else {
            return setVolumeFallback(muted, on: deviceID)
        }
    }

    private func deviceSupportsMuteProperty(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(deviceID, &address)
    }

    private func setMuteProperty(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue else {
            return false
        }

        var value: UInt32 = muted ? 1 : 0
        guard AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        ) == noErr else {
            return false
        }

        // Some drivers accept the write without actually applying it, so confirm
        // the hardware landed in the requested state before reporting success.
        var readBack: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &readBack) == noErr else {
            return false
        }
        return (readBack != 0) == muted
    }

    private func setVolumeFallback(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue else {
            return false
        }

        if muted {
            // Only capture the volume the first time we mute: a redundant re-mute
            // (e.g. the wake-resync path reapplying an already-muted state) would
            // otherwise read back the 0 we set last time and overwrite the real
            // saved value, permanently stranding the mic at zero on unmute.
            if savedVolumesByDevice[deviceID] == nil {
                var currentVolume: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &currentVolume)
                if status == noErr {
                    savedVolumesByDevice[deviceID] = currentVolume
                }
            }
            var zero: Float32 = 0
            guard AudioObjectSetPropertyData(
                deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &zero
            ) == noErr else {
                return false
            }
            guard let readBack = Self.readVolume(deviceID, &address) else { return false }
            return readBack <= 0.0001
        } else {
            let restored: Float32 = savedVolumesByDevice[deviceID] ?? 1.0
            var value = restored
            guard AudioObjectSetPropertyData(
                deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
            ) == noErr else {
                return false
            }
            guard let readBack = Self.readVolume(deviceID, &address), abs(readBack - restored) < 0.01 else {
                return false
            }
            savedVolumesByDevice[deviceID] = nil
            return true
        }
    }

    private static func restoreVolume(_ volume: Float32, on deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        var value = volume
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private static func readVolume(_ deviceID: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Float32? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    /// Only devices exposing the hardware mute property can be read reliably —
    /// a volume-fallback device's current volume doesn't tell us whether a 0
    /// reading means "muted by us" or just a quiet user-chosen level, so those
    /// devices fall back to the `false` default at launch instead of guessing.
    private static func currentHardwareMuteState(for deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }

    // MARK: - Device lookup

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
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
}
