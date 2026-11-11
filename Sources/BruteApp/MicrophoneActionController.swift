import AppKit
import Foundation

/// A sustained press changes mute temporarily. Two completed taps toggle it persistently.
@MainActor
final class MicrophoneActionController {
    static let shared = MicrophoneActionController(micController: .shared, hotkeyManager: .shared)

    static let minimumDoublePressInterval: TimeInterval = 0.2
    static let maximumDoublePressInterval: TimeInterval = 1.0
    static let holdThreshold: TimeInterval = 0.2
    private static let defaultDoublePressInterval: TimeInterval = 0.4

    private struct Tap {
        let releasedAt: TimeInterval
        let deviceGeneration: UInt64
    }

    private enum Gesture {
        case idle
        case pressed(at: TimeInterval, deviceGeneration: UInt64, canCountAsTap: Bool)
        case holding(MicMuteController.TemporaryMute?)
    }

    private let micController: MicMuteController
    private weak var hotkeyManager: HotkeyManager?
    private let feedback: FeedbackPlaying?
    private let defaults: UserDefaults?
    private let now: () -> TimeInterval
    private(set) var doublePressInterval: TimeInterval
    private var gesture: Gesture = .idle
    private var previousTap: Tap?
    private var holdTask: Task<Void, Never>?
    private var wakeObserver: NotificationObservation?

    /// Production wiring. A separate initializer because a default argument cannot
    /// reach the main-actor-isolated `ClickSoundPlayer.shared`.
    convenience init(
        micController: MicMuteController,
        hotkeyManager: HotkeyManager
    ) {
        self.init(
            micController: micController,
            hotkeyManager: hotkeyManager,
            feedback: ClickSoundPlayer.shared,
            defaults: .standard
        )
    }

    init(
        micController: MicMuteController,
        hotkeyManager: HotkeyManager? = nil,
        feedback: FeedbackPlaying?,
        observesWake: Bool = true,
        defaults: UserDefaults? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.micController = micController
        self.hotkeyManager = hotkeyManager
        self.feedback = feedback
        self.defaults = defaults
        self.now = now
        let saved = defaults?.object(forKey: BruteDefaults.doublePressInterval) as? TimeInterval
        doublePressInterval = Self.validatedInterval(saved ?? Self.defaultDoublePressInterval)
        hotkeyManager?.onHotkeyDown = { [weak self] timestamp in self?.handleDown(at: timestamp) }
        hotkeyManager?.onHotkeyUp = { [weak self] timestamp in self?.handleUp(at: timestamp) }
        hotkeyManager?.onHotkeyCancelled = { [weak self] in self?.cancelActiveGesture() }
        // HotkeyManager resets its own edges and cancels the gesture together.
        if observesWake, hotkeyManager == nil {
            observeWake()
        }
    }

    func setDoublePressInterval(_ interval: TimeInterval) {
        let updated = Self.validatedInterval(interval)
        guard updated != doublePressInterval else { return }
        doublePressInterval = updated
        defaults?.set(updated, forKey: BruteDefaults.doublePressInterval)
        previousTap = nil
        if case .pressed(let pressedAt, let generation, _) = gesture {
            gesture = .pressed(at: pressedAt, deviceGeneration: generation, canCountAsTap: false)
        }
    }

    private static func validatedInterval(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return defaultDoublePressInterval }
        let clamped = min(maximumDoublePressInterval, max(minimumDoublePressInterval, interval))
        return (clamped * 5).rounded() / 5
    }

    func handleDown(at timestamp: TimeInterval? = nil) {
        guard case .idle = gesture else { return }
        let pressedAt = eventTime(timestamp)
        gesture = .pressed(at: pressedAt, deviceGeneration: micController.shortcutDeviceGeneration(), canCountAsTap: true)
        let deadline = ContinuousClock.now + .seconds(max(0, pressedAt + Self.holdThreshold - now()))
        holdTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled else { return }
            self?.advanceHold(at: pressedAt + Self.holdThreshold)
        }
    }

    func advanceHold(at timestamp: TimeInterval) {
        guard case .pressed(let pressedAt, let generation, _) = gesture,
              eventTime(timestamp) >= pressedAt + Self.holdThreshold,
              hotkeyManager?.isTriggerKeyDown != false else { return }
        previousTap = nil
        let temporary = micController.beginTemporaryToggle(forDeviceGeneration: generation)
        gesture = .holding(temporary)
        if temporary != nil { feedback?.play() }
    }

    func handleUp(at timestamp: TimeInterval? = nil) {
        finishPress(at: eventTime(timestamp))
    }

    func handleWake() { cancelActiveGesture() }
    func prepareForTermination() {
        cancelActiveGesture()
        wakeObserver = nil
    }
    func cancelActiveGesture() {
        previousTap = nil
        finishPress(at: nil)
    }

    private func finishPress(at releasedAt: TimeInterval?) {
        holdTask?.cancel()
        holdTask = nil
        let finished = gesture
        gesture = .idle
        switch finished {
        case .idle:
            return
        case .holding(let temporary):
            if let temporary, micController.endTemporaryToggle(temporary) { feedback?.play() }
        case .pressed(let pressedAt, let generation, let canCountAsTap):
            completeTap(at: releasedAt, pressedAt: pressedAt, deviceGeneration: generation, canCountAsTap: canCountAsTap)
        }
    }

    private func completeTap(at releasedAt: TimeInterval?, pressedAt: TimeInterval, deviceGeneration: UInt64, canCountAsTap: Bool) {
        let firstTap = previousTap
        previousTap = nil
        guard canCountAsTap, let releasedAt,
              pressedAt < releasedAt, releasedAt < pressedAt + Self.holdThreshold,
              micController.shortcutDeviceGeneration() == deviceGeneration else { return }
        if let firstTap, firstTap.deviceGeneration == deviceGeneration,
           firstTap.releasedAt < pressedAt, releasedAt <= firstTap.releasedAt + doublePressInterval {
            if micController.toggleMuted(forDeviceGeneration: deviceGeneration) { feedback?.play() }
        } else {
            previousTap = Tap(releasedAt: releasedAt, deviceGeneration: deviceGeneration)
        }
    }

    private func eventTime(_ timestamp: TimeInterval?) -> TimeInterval {
        let currentTime = now()
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return currentTime }
        return min(timestamp, currentTime)
    }

    private func observeWake() {
        wakeObserver = NotificationObservation(
            center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWake() }
        }
    }
}
