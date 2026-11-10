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
        case held(priorMuted: Bool)
        case failed
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
        hotkeyManager?.onHotkeyDown = { [weak self] in self?.handleDown() }
        hotkeyManager?.onHotkeyUp = { [weak self] in self?.handleUp() }
        hotkeyManager?.onHotkeyCancelled = { [weak self] in self?.cancelActiveGesture() }
        if observesWake {
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

    func handleDown() {
        guard case .idle = gesture else { return }
        gesture = .pressed(now() + holdThreshold)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(holdThreshold))
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
    func advanceHold() {
        guard case .pressed(let deadline) = gesture,
              now() >= deadline else { return }
        cancelHoldTask()
        applyFlip(temporary: true)
    }

    func handleUp() {
        advanceHold()
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
        switch gesture {
        case .pressed:
            if commitTap { applyFlip(temporary: false) }
        case .held(let prior):
            writeMuted(prior, retryOnFailure: true)
        case .idle, .failed:
            break
        }
        gesture = .idle
    }

    private func applyFlip(temporary: Bool) {
        micController.syncBeforeGesture()
        guard let prior = micController.state.mutedValue else {
            gesture = .failed
            return
        }
        // Restore even if a hardware write was accepted but readback is deferred.
        gesture = temporary ? .held(priorMuted: prior) : .idle
        writeMuted(!prior)
    }

    /// All hotkey writes, including restoration, pass through this one boundary.
    private func writeMuted(_ muted: Bool, retryOnFailure: Bool = false) {
        if micController.setMuted(muted, retryOnFailure: retryOnFailure) {
            feedback?.play()
        }
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
