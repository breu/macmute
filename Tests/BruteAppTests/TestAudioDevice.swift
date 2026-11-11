import CoreAudio
import Foundation
@testable import BruteApp

@MainActor
final class FakeAudioDeviceController: AudioDeviceControlling {
    struct MuteCall: Equatable {
        let muted: Bool
        let deviceID: AudioDeviceID
    }

    struct VolumeCall: Equatable {
        let volume: Float32
        let deviceID: AudioDeviceID
    }

    var defaultDeviceID: AudioDeviceID?
    var muteProperties: Set<AudioDeviceID> = []
    var muteSettable = true
    var volumeSettable = true
    var muteWritesSucceed = true
    var volumeWritesSucceed = true
    var volumeWriteFailuresRemaining: [AudioDeviceID: Int] = [:]
    var mutes: [AudioDeviceID: Bool] = [:]
    var volumes: [AudioDeviceID: Float32] = [:]
    var volumeSnapshots: [AudioDeviceID: InputVolumeSnapshot] = [:]
    var setMuteCalls: [MuteCall] = []
    var setVolumeCalls: [VolumeCall] = []
    private let identifierPrefix: String
    var persistentIdentifiersAvailable = true
    var persistentIdentifiers: [AudioDeviceID: String] = [:]
    var muteReadsSucceed = true
    var muteReadResults: [Bool?] = []
    var deferMuteWrites = false
    var deferredMuteWrites: [AudioDeviceID: Bool] = [:]
    var onSetMute: (() -> Void)?
    var deferVolumeWrites = false
    var deferredVolumeWrites: [AudioDeviceID: InputVolumeSnapshot] = [:]
    var invalidateControlCachesCalls: [AudioDeviceID?] = []
    var stateObservationSucceeds = true
    var shutdownCalled = false

    private var defaultDeviceChangeHandler: (@MainActor () -> Void)?
    private var stateChangeHandler: (@MainActor () -> Void)?

    init(defaultDeviceID: AudioDeviceID?, identifierPrefix: String = UUID().uuidString) {
        self.defaultDeviceID = defaultDeviceID
        self.identifierPrefix = identifierPrefix
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID
    }

    func persistentIdentifier(for deviceID: AudioDeviceID) -> String? {
        guard persistentIdentifiersAvailable else { return nil }
        return persistentIdentifiers[deviceID] ?? "\(identifierPrefix)-\(deviceID)"
    }

    func deviceID(forPersistentIdentifier identifier: String) -> AudioDeviceID? {
        let known = Set(persistentIdentifiers.keys)
            .union(mutes.keys).union(volumes.keys).union(volumeSnapshots.keys)
        return known.first { persistentIdentifier(for: $0) == identifier }
    }

    func hasMuteProperty(on deviceID: AudioDeviceID) -> Bool {
        muteProperties.contains(deviceID)
    }

    func isMuteSettable(on deviceID: AudioDeviceID) -> Bool {
        muteSettable
    }

    func readMute(on deviceID: AudioDeviceID) -> Bool? {
        if !muteReadResults.isEmpty {
            return muteReadResults.removeFirst()
        }
        return muteReadsSucceed ? mutes[deviceID] : nil
    }

    func setMute(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        setMuteCalls.append(MuteCall(muted: muted, deviceID: deviceID))
        guard muteWritesSucceed else { return false }
        if deferMuteWrites {
            deferredMuteWrites[deviceID] = muted
        } else {
            mutes[deviceID] = muted
        }
        onSetMute?()
        return true
    }

    func isVolumeSettable(on deviceID: AudioDeviceID) -> Bool {
        volumeSettable && (volumes[deviceID] != nil || volumeSnapshots[deviceID] != nil)
    }

    func readVolumes(on deviceID: AudioDeviceID) -> InputVolumeSnapshot? {
        if let snapshot = volumeSnapshots[deviceID] { return snapshot }
        return volumes[deviceID].map { [0: $0] }
    }

    func setVolumes(_ snapshot: InputVolumeSnapshot, on deviceID: AudioDeviceID) -> Bool {
        for volume in snapshot.sorted(by: { $0.key < $1.key }).map(\.value) {
            setVolumeCalls.append(VolumeCall(volume: volume, deviceID: deviceID))
        }
        if let failures = volumeWriteFailuresRemaining[deviceID], failures > 0 {
            volumeWriteFailuresRemaining[deviceID] = failures - 1
            return false
        }
        guard volumeWritesSucceed else { return false }
        if deferVolumeWrites {
            deferredVolumeWrites[deviceID] = snapshot
            return true
        }
        applyVolumes(snapshot, on: deviceID)
        return true
    }

    func completeDeferredWrites() {
        for (deviceID, muted) in deferredMuteWrites { mutes[deviceID] = muted }
        deferredMuteWrites.removeAll()
        for (deviceID, snapshot) in deferredVolumeWrites { applyVolumes(snapshot, on: deviceID) }
        deferredVolumeWrites.removeAll()
    }

    private func applyVolumes(_ snapshot: InputVolumeSnapshot, on deviceID: AudioDeviceID) {
        if volumeSnapshots[deviceID] != nil || snapshot.keys.contains(where: { $0 != 0 }) {
            volumeSnapshots[deviceID] = snapshot
        }
        if let main = snapshot[0] {
            volumes[deviceID] = main
        }
    }

    func observeDefaultDeviceChanges(_ handler: @escaping @MainActor () -> Void) -> Bool {
        defaultDeviceChangeHandler = handler
        return true
    }

    func invalidateControlCaches(for deviceID: AudioDeviceID?) {
        invalidateControlCachesCalls.append(deviceID)
    }

    func shutdown() {
        shutdownCalled = true
        defaultDeviceChangeHandler = nil
        stateChangeHandler = nil
    }

    func observeStateChanges(
        on deviceID: AudioDeviceID?,
        _ handler: @escaping @MainActor () -> Void
    ) -> Bool {
        stateChangeHandler = stateObservationSucceeds ? handler : nil
        return stateObservationSucceeds
    }

    func triggerDefaultDeviceChange() {
        defaultDeviceChangeHandler?()
    }

    func triggerStateChange() {
        stateChangeHandler?()
    }
}
