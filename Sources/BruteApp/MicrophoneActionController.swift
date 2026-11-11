import AppKit
import Foundation

/// A press flips mute immediately. Release restores it unless it completes a double press.
@MainActor
final class MicrophoneActionController {
    static let shared = MicrophoneActionController(micController: .shared, hotkeyManager: .shared)

    static let minimumDoublePressInterval: TimeInterval = 0.2
    static let maximumDoublePressInterval: TimeInterval = 1.0
    private static let defaultDoublePressInterval: TimeInterval = 0.4

    private struct Tap {
        let releasedAt: TimeInterval
        let secondReleaseDeadline: TimeInterval
        let deviceGeneration: UInt64
    }

    private enum Gesture {
        case idle
        case pressed(at: TimeInterval, interval: TimeInterval, temporary: MicMuteController.TemporaryMute)
        case ignored
    }

    private let micController: MicMuteController
    private let feedback: FeedbackPlaying?
    private let defaults: UserDefaults?
    private let now: () -> TimeInterval
    private(set) var doublePressInterval: TimeInterval
    private var gesture: Gesture = .idle
    private var previousTap: Tap?
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

    /// The first press captures the interval for the pair already in progress.
    func setDoublePressInterval(_ interval: TimeInterval) {
        doublePressInterval = Self.validatedInterval(interval)
        defaults?.set(doublePressInterval, forKey: BruteDefaults.doublePressInterval)
    }

    private static func validatedInterval(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return defaultDoublePressInterval }
        let clamped = min(maximumDoublePressInterval, max(minimumDoublePressInterval, interval))
        return (clamped * 5).rounded() / 5
    }

    func handleDown(at timestamp: TimeInterval? = nil) {
        guard case .idle = gesture else { return }
        let pressedAt = eventTime(timestamp)
        let interval = doublePressInterval
        guard let temporary = micController.beginTemporaryToggle() else {
            previousTap = nil
            gesture = .ignored
            return
        }
        gesture = .pressed(at: pressedAt, interval: interval, temporary: temporary)
        feedback?.play()
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
        let finished = gesture
        gesture = .idle
        guard case .pressed(let pressedAt, let interval, let temporary) = finished else { return }
        let firstTap = previousTap
        previousTap = nil
        if let releasedAt, let firstTap,
           firstTap.deviceGeneration == temporary.deviceGeneration,
           firstTap.releasedAt <= pressedAt,
           pressedAt <= releasedAt,
           releasedAt <= firstTap.secondReleaseDeadline,
           micController.commitTemporaryToggle(temporary) {
            return
        }
        guard micController.endTemporaryToggle(temporary) else { return }
        if let releasedAt, releasedAt >= pressedAt, releasedAt <= pressedAt + interval {
            previousTap = Tap(
                releasedAt: releasedAt,
                secondReleaseDeadline: releasedAt + interval,
                deviceGeneration: temporary.deviceGeneration
            )
        }
        feedback?.play()
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
