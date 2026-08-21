import AppKit
import CoreAudio
import Foundation

final class MicMuteController {

    static let shared = MicMuteController()

    private(set) var isMuted: Bool = false
    var onMuteStateChanged: ((Bool) -> Void)?

    private var savedVolume: Float32?
    private var currentDeviceID: AudioDeviceID?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        currentDeviceID = Self.defaultInputDeviceID()
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

    func setMuted(_ muted: Bool) {
        guard let deviceID = Self.defaultInputDeviceID() else { return }
        applyMute(muted, to: deviceID)
        isMuted = muted
        onMuteStateChanged?(muted)
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
            self.savedVolume = nil
            let newDeviceID = Self.defaultInputDeviceID()
            self.currentDeviceID = newDeviceID
            if self.isMuted, let newDeviceID {
                self.applyMute(true, to: newDeviceID)
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

    // MARK: - Mute application

    private func applyMute(_ muted: Bool, to deviceID: AudioDeviceID) {
        if deviceSupportsMuteProperty(deviceID) {
            setMuteProperty(muted, on: deviceID)
        } else {
            setVolumeFallback(muted, on: deviceID)
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

    private func setMuteProperty(_ muted: Bool, on deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
    }

    private func setVolumeFallback(_ muted: Bool, on deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return }

        if muted {
            var currentVolume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &currentVolume)
            if status == noErr {
                savedVolume = currentVolume
            }
            var zero: Float32 = 0
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &zero)
        } else {
            var restored: Float32 = savedVolume ?? 1.0
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &restored)
            savedVolume = nil
        }
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
