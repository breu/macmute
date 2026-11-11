import Foundation

/// Hardware-independent policy decisions for input-device control.
///
/// These are pure functions of the capability and value snapshots the caller
/// gathers, which makes the tricky parts — channel coverage rules, atomic
/// multi-element writes, how a mute is inferred from volumes — testable without
/// a CoreAudio device.
enum AudioControlPolicy {

    /// Volumes at or below this are treated as silent. Hardware rounding means an
    /// exact zero comparison is unreliable.
    static let silenceThreshold: Float32 = 0.0001

    /// Applied to a channel that has appeared since Brute last recorded a baseline.
    ///
    /// Deliberately mid-range rather than full scale: restoring a brand-new channel
    /// at 1.0 can send a microphone to maximum input gain mid-call, which is a worse
    /// surprise than a quieter-than-expected start. Channels Brute has a recorded
    /// baseline for are always restored to that exact value.
    static let conservativeRestoreVolume: Float32 = 0.5

    /// Elements to read for `selector`, preferring an aggregate "main" element when
    /// the device exposes one, and otherwise falling back to per-channel elements
    /// only when *every* input channel is represented. Partial coverage would let a
    /// read describe some channels and not others.
    static func resolveReadableControlElements(
        mainAvailable: Bool,
        inputElements: [UInt32],
        availableChannelElements: Set<UInt32>
    ) -> [UInt32] {
        if mainAvailable { return [kMainElement] }
        let required = Set(inputElements)
        return !required.isEmpty && required.isSubset(of: availableChannelElements) ? inputElements : []
    }

    /// Elements to write, using the aggregate "main" element only when the device
    /// says it is settable, and otherwise requiring that every input channel is
    /// both available and settable before writing at all.
    static func resolveWritableControlElements(
        mainAvailable: Bool,
        mainSettable: Bool,
        inputElements: [UInt32],
        availableChannelElements: Set<UInt32>,
        settableChannelElements: Set<UInt32>
    ) -> [UInt32] {
        if mainAvailable, mainSettable {
            return [kMainElement]
        }
        let required = Set(inputElements)
        if !required.isEmpty,
           required.isSubset(of: availableChannelElements),
           required.isSubset(of: settableChannelElements) {
            return inputElements
        }
        return []
    }

    /// `kAudioObjectPropertyElementMain`, spelled without pulling CoreAudio into
    /// every caller of the pure resolvers.
    static let kMainElement: UInt32 = 0

    /// Writes every element. On failure, attempts to restore the elements
    /// already changed in reverse order.
    ///
    /// Used by both native mute and volume writes, where a multi-channel device
    /// could otherwise end up muted on one channel and live on another.
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

    static func volumesAreMuted(_ volumes: InputVolumeSnapshot) -> Bool {
        !volumes.isEmpty && volumes.values.allSatisfy { $0 <= silenceThreshold }
    }

    /// Allow small driver rounding without treating a silent channel as restored
    /// when it was supposed to be live.
    static func restoredVolumesMatch(_ actual: InputVolumeSnapshot, target: InputVolumeSnapshot) -> Bool {
        actual.count == target.count && target.allSatisfy { element, expected in
            guard let observed = actual[element] else { return false }
            return (observed <= silenceThreshold) == (expected <= silenceThreshold)
                && abs(observed - expected) < 0.01
        }
    }

    /// Baseline to restore to, given what the device reports now.
    ///
    /// A channel that has disappeared since muting is dropped rather than blocking
    /// restoration of the rest; a channel that has appeared gets the conservative
    /// default.
    static func restorationVolumes(
        saved: InputVolumeSnapshot?,
        current: InputVolumeSnapshot
    ) -> InputVolumeSnapshot {
        Dictionary(uniqueKeysWithValues: current.keys.map { element in
            (element, saved?[element] ?? conservativeRestoreVolume)
        })
    }

    /// The microphone state implied by one coherent sample of a device's controls.
    ///
    /// A native mute reading of "muted" always wins. Otherwise all-zero input volume
    /// counts as muted, which is the fallback path for devices with no mute control.
    /// Anything Brute cannot read is `.unavailable` rather than a guess.
    static func state(
        hasNativeMute: Bool,
        nativeMute: Bool?,
        volumes: InputVolumeSnapshot?
    ) -> MicrophoneState {
        if nativeMute == true { return .muted }
        if let volumes, volumesAreMuted(volumes) { return .muted }
        if nativeMute == false { return .unmuted }
        if !hasNativeMute, let volumes, !volumes.isEmpty { return .unmuted }
        return .unavailable
    }
}
