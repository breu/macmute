import AVFoundation

/// Plays a short synthesized "click" as feedback for hotkey-driven mic actions.
/// Generated in-process rather than bundled as an audio asset, so there's nothing
/// to ship or codesign alongside the binary.
final class ClickSoundPlayer {

    static let shared = ClickSoundPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let clickBuffer: AVAudioPCMBuffer
    private let modeChangeBuffer: AVAudioPCMBuffer

    private init() {
        let sampleRate = 44_100.0
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        clickBuffer = Self.makeClickBuffer(format: format, sampleRate: sampleRate)
        modeChangeBuffer = Self.makeModeChangeBuffer(format: format, sampleRate: sampleRate)

        engine.mainMixerNode.outputVolume = 1.0
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            NSLog("ClickSoundPlayer: engine.start() failed: \(error)")
        }
    }

    /// Feedback for the hotkey muting/unmuting the mic.
    func play() {
        play(clickBuffer)
    }

    /// Feedback for double-click toggling the hotkey's mode — distinct from the mute
    /// click so the two actions don't feel the same.
    func playModeChange() {
        play(modeChangeBuffer)
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("ClickSoundPlayer: engine restart failed: \(error)")
                return
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    /// Broadband noise gives the sharp transient "click" character; a fast-decaying
    /// low tone underneath gives it body/loudness so it isn't just a thin hiss.
    private static func makeClickBuffer(format: AVAudioFormat, sampleRate: Double) -> AVAudioPCMBuffer {
        let duration = 0.03
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let noiseEnvelope = exp(-t * 350)
            let toneEnvelope = exp(-t * 220)
            let noise = Float.random(in: -1...1) * Float(noiseEnvelope)
            let tone = Float(sin(2 * Double.pi * 1_100 * t)) * Float(toneEnvelope)
            samples[i] = max(-1, min(1, noise * 0.75 + tone * 0.5))
        }
        return buffer
    }

    /// Two clean rising tones (no noise) reads as a "mode switched" chirp rather than
    /// a mechanical click.
    private static func makeModeChangeBuffer(format: AVAudioFormat, sampleRate: Double) -> AVAudioPCMBuffer {
        let noteDuration = 0.05
        let gap = 0.02
        let totalDuration = noteDuration * 2 + gap
        let frameCount = AVAudioFrameCount(sampleRate * totalDuration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let firstToneFrames = Int(sampleRate * noteDuration)
        let gapFrames = Int(sampleRate * gap)
        let secondToneStart = firstToneFrames + gapFrames

        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            if i < firstToneFrames {
                let t = Double(i) / sampleRate
                let envelope = exp(-t * 60)
                samples[i] = Float(sin(2 * Double.pi * 900 * t)) * Float(envelope) * 0.7
            } else if i >= secondToneStart {
                let t = Double(i - secondToneStart) / sampleRate
                let envelope = exp(-t * 60)
                samples[i] = Float(sin(2 * Double.pi * 1_400 * t)) * Float(envelope) * 0.7
            } else {
                samples[i] = 0
            }
        }
        return buffer
    }
}
