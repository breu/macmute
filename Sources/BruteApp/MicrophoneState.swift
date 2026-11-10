import Foundation

/// What Brute believes about the microphone it controls.
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

/// One input device's scalar volume per channel element.
typealias InputVolumeSnapshot = [UInt32: Float32]
