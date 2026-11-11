import AppKit
import Foundation

/// One gesture: a short release toggles permanently; a hold toggles temporarily.
@MainActor
final class MicrophoneActionController {
    static let shared = MicrophoneActionController(micController: .shared, hotkeyManager: .shared, defaults: .standard)

    /// The slider stops offered to the user, and the stored default.
    static let minimumDelay: TimeInterval = 0.2
    static let maximumDelay: TimeInterval = 1.0
    static let defaultDelay: TimeInterval = 0.4

    private enum Gesture {
        case idle
        case pressed(TimeInterval)
        case held(MicMuteController.TemporaryMute)
        case consumed
    }

    private let micController: MicMuteController
    private let feedback: FeedbackPlaying?
    private let now: () -> TimeInterval
    /// Legacy key retained deliberately: `BruteDefaults` documents why the
    /// `MacMute.` prefix stays even though the app is Brute.
    private static let delayKey = BruteDefaults.tapHoldDelay
    private let defaults: UserDefaults?
    private(set) var holdThreshold: TimeInterval
    private var gesture: Gesture = .idle
    private var holdTask: Task<Void, Never>?
    private var wakeObserver: NotificationObservation?

    /// Production wiring. A separate initializer because a default argument cannot
    /// reach the main-actor-isolated `ClickSoundPlayer.shared`.
    convenience init(
        micController: MicMuteController,
        hotkeyManager: HotkeyManager? = nil,
        observesWake: Bool = true,
        defaults: UserDefaults? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.init(
            micController: micController,
            hotkeyManager: hotkeyManager,
            feedback: ClickSoundPlayer.shared,
            observesWake: observesWake,
            defaults: defaults,
            now: now
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
        self.now = now
        self.defaults = defaults
        let saved = defaults?.object(forKey: Self.delayKey) as? Double
        holdThreshold = Self.validatedDelay(saved ?? Self.defaultDelay)
        hotkeyManager?.onHotkeyDown = { [weak self] timestamp in self?.handleDown(at: timestamp) }
        hotkeyManager?.onHotkeyUp = { [weak self] timestamp in self?.handleUp(at: timestamp) }
        hotkeyManager?.onHotkeyCancelled = { [weak self] in self?.cancelActiveGesture() }
        // HotkeyManager resets its own edges and cancels the gesture together.
        if observesWake, hotkeyManager == nil {
            observeWake()
        }
    }

    deinit {
        holdTask?.cancel()
    }

    /// Updates future gestures; an in-progress gesture keeps its original deadline.
    func setHoldThreshold(_ delay: TimeInterval) {
        holdThreshold = Self.validatedDelay(delay)
        defaults?.set(holdThreshold, forKey: Self.delayKey)
    }

    private static func validatedDelay(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return defaultDelay }
        // Clamp first, then snap onto a slider stop, so an out-of-range stored
        // value still lands on a delay the user can see and select again.
        return (min(maximumDelay, max(minimumDelay, delay)) * 5).rounded() / 5
    }

    func handleDown(at timestamp: TimeInterval? = nil) {
        guard case .idle = gesture else { return }
        let currentTime = now()
        let pressedAt = eventTime(timestamp, noLaterThan: currentTime)
        let holdDeadline = pressedAt + holdThreshold
        gesture = .pressed(holdDeadline)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, holdDeadline - currentTime)))
        holdTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.advanceHold()
        }
    }

    /// The scheduled hold check and release both validate the original deadline.
    func advanceHold(at timestamp: TimeInterval? = nil) {
        guard case .pressed(let deadline) = gesture,
              eventTime(timestamp, noLaterThan: now()) >= deadline else { return }
        cancelHoldTask()
        guard let temporary = micController.beginTemporaryToggle() else {
            gesture = .consumed
            return
        }
        gesture = .held(temporary)
        feedback?.play()
    }

    func handleUp(at timestamp: TimeInterval? = nil) {
        advanceHold(at: timestamp)
        finishGesture(commitTap: true)
    }

    func handleWake() { cancelActiveGesture() }
    func prepareForTermination() {
        cancelActiveGesture()
        wakeObserver = nil
    }
    func cancelActiveGesture() { finishGesture(commitTap: false) }

    private func finishGesture(commitTap: Bool) {
        cancelHoldTask()
        let finished = gesture
        gesture = .idle
        switch finished {
        case .pressed:
            if commitTap, micController.toggleMute() { feedback?.play() }
        case .held(let temporary):
            if micController.endTemporaryToggle(temporary) { feedback?.play() }
        case .idle, .consumed:
            break
        }
    }

    private func eventTime(_ timestamp: TimeInterval?, noLaterThan currentTime: TimeInterval) -> TimeInterval {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return currentTime }
        return min(timestamp, currentTime)
    }

    private func cancelHoldTask() {
        holdTask?.cancel()
        holdTask = nil
    }

    private func observeWake() {
        wakeObserver = NotificationObservation(
            center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWake() }
        }
    }
}
