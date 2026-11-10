import AppKit
import AVFoundation

private let clickSampleRate = 44_100.0

/// The hardware-facing half of click playback, behind a seam so the policy in
/// `ClickSoundPlayer` can be tested without an audio device.
@MainActor
protocol ClickSoundEngineing: AnyObject {
    var isRunning: Bool { get }
    /// Invoked when the underlying output configuration changes (device, sample
    /// rate, channel count). The real engine stops itself at that point.
    var configurationChangeHandler: (@MainActor () -> Void)? { get set }
    func start()
    func stop()
    /// Recreates the audio graph after wake.
    func rebuild()
    func play(_ buffer: AVAudioPCMBuffer)
}

/// Anything that can give the user audible feedback for a microphone write.
@MainActor
protocol FeedbackPlaying: AnyObject {
    func play()
}

/// AVAudioEngine-backed click output.
///
/// Recreating the engine and player from scratch — rather than reusing and
/// restarting the existing objects — is what actually recovers audio after
/// sleep: a plain stop()/start() on the same instance kept leaving `isRunning`
/// reporting true with no audio actually reaching the hardware.
@MainActor
final class AVAudioClickEngine: ClickSoundEngineing {
    var configurationChangeHandler: (@MainActor () -> Void)?

    var isRunning: Bool { engine.isRunning }
    private let format: AVAudioFormat
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var configurationChangeObserver: NotificationObservation?
    private var graphGeneration = 0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: clickSampleRate, channels: 1)!
        buildGraph()
    }

    func start() {
        do {
            try engine.start()
        } catch {
            BruteLog.feedback.error("Audio engine start failed: \(error, privacy: .public)")
        }
    }

    func stop() {
        configurationChangeObserver = nil
        graphGeneration += 1
        engine.stop()
    }

    func rebuild() {
        stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        buildGraph()
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    private func buildGraph() {
        engine.mainMixerNode.outputVolume = 1.0
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        start()
        observeConfigurationChange()
    }

    /// Apple posts this specifically when the engine's hardware configuration changes
    /// (sample rate, device, channel count) — the engine stops itself but does not
    /// restart automatically. This is the documented signal for the exact class of
    /// bug where sleep/wake silently kills audio output.
    private func observeConfigurationChange() {
        let generation = graphGeneration
        configurationChangeObserver = NotificationObservation(
            center: .default,
            name: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.graphGeneration == generation else { return }
                self.configurationChangeHandler?()
            }
        }
    }
}

/// Delay before rebuilding after wake. CoreAudio needs a moment to finish its own
/// hardware reinitialization — rebuilding immediately at the notification can race
/// with that and still end up silently non-functional.
///
/// File-level so it can serve as an initializer default argument, which is a
/// nonisolated context.
private let clickWakeRebuildDelay: TimeInterval = 0.5

/// Plays a short synthesized "click" as feedback for hotkey-driven mic actions.
/// Generated in-process rather than bundled as an audio asset, so there's nothing
/// to ship or codesign alongside the binary.
@MainActor
final class ClickSoundPlayer: FeedbackPlaying {

    static let shared = ClickSoundPlayer()

    private let engine: ClickSoundEngineing
    private let clickBuffer: AVAudioPCMBuffer
    private let wakeRebuildDelay: TimeInterval
    private var wakeObserver: NotificationObservation?
    private var wakeRebuild: Task<Void, Never>?
    private var isShutdown = false

    init(
        engine: ClickSoundEngineing? = nil,
        observesLifecycle: Bool = true,
        wakeRebuildDelay: TimeInterval = clickWakeRebuildDelay
    ) {
        let resolvedEngine = engine ?? AVAudioClickEngine()
        self.engine = resolvedEngine
        self.wakeRebuildDelay = wakeRebuildDelay
        clickBuffer = Self.makeClickBuffer(
            format: AVAudioFormat(standardFormatWithSampleRate: clickSampleRate, channels: 1)!,
            sampleRate: clickSampleRate
        )
        resolvedEngine.configurationChangeHandler = { [weak self] in
            self?.handleConfigurationChange()
        }
        if observesLifecycle {
            observeWake()
        }
    }

    /// Test seam: lets a test observe that a wake-triggered rebuild was scheduled
    /// without waiting out the real delay.
    var isWakeRebuildScheduled: Bool { wakeRebuild != nil }

    /// Feedback for the hotkey muting/unmuting the mic.
    func play() {
        guard !isShutdown else { return }
        if !engine.isRunning {
            engine.start()
            guard engine.isRunning else { return }
        }
        engine.play(clickBuffer)
    }

    /// Recreates the audio graph after sleep,
    /// when the previous graph may report `isRunning` while reaching no hardware.
    func rebuildGraph() {
        engine.rebuild()
    }

    func handleConfigurationChange() {
        engine.start()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        wakeObserver = nil
        wakeRebuild?.cancel()
        wakeRebuild = nil
        engine.configurationChangeHandler = nil
        engine.stop()
    }

    private func observeWake() {
        wakeObserver = NotificationObservation(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.didWakeNotification,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWakeRebuild()
            }
        }
    }

    func scheduleWakeRebuild() {
        guard !isShutdown, wakeRebuild == nil else { return }
        wakeRebuild = Task { @MainActor [weak self, wakeRebuildDelay] in
            do {
                try await Task.sleep(for: .seconds(wakeRebuildDelay))
            } catch {
                return
            }
            guard let self, !self.isShutdown else { return }
            self.wakeRebuild = nil
            self.rebuildGraph()
        }
    }

    /// Broadband noise gives the sharp transient "click" character; a fast-decaying
    /// low tone underneath gives it body/loudness so it isn't just a thin hiss.
    static func makeClickBuffer(format: AVAudioFormat, sampleRate: Double) -> AVAudioPCMBuffer {
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
}
