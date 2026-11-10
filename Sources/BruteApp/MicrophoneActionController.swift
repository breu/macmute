import AppKit
import Foundation

/// One gesture: a short release toggles permanently; a hold toggles temporarily.
@MainActor
final class MicrophoneActionController {
    static let shared = MicrophoneActionController(micController: .shared, hotkeyManager: .shared, defaults: .standard)

    private enum Gesture {
        case idle
        case pressed(TimeInterval)
        case held(priorMuted: Bool)
        case failed
    }

    private let micController: MicMuteController
    private let playsFeedback: Bool
    private let now: () -> TimeInterval
    private static let delayKey = "MacMute.tapHoldDelay"
    private let defaults: UserDefaults?
    private(set) var holdThreshold: TimeInterval
    private var gesture: Gesture = .idle
    private var holdTimer: Timer?

    init(
        micController: MicMuteController,
        hotkeyManager: HotkeyManager? = nil,
        playsFeedback: Bool = true,
        observesWake: Bool = true,
        defaults: UserDefaults? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.micController = micController
        self.playsFeedback = playsFeedback
        self.now = now
        self.defaults = defaults
        let saved = defaults?.object(forKey: Self.delayKey) as? Double
        holdThreshold = Self.validatedDelay(saved ?? 0.4)
        hotkeyManager?.onHotkeyDown = { [weak self] in self?.handleDown() }
        hotkeyManager?.onHotkeyUp = { [weak self] in self?.handleUp() }
        hotkeyManager?.onHotkeyCancelled = { [weak self] in self?.cancelActiveGesture() }
        if observesWake {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleWake() }
            }
        }
    }

    /// Updates future gestures; an in-progress gesture keeps its original deadline.
    func setHoldThreshold(_ delay: TimeInterval) {
        holdThreshold = Self.validatedDelay(delay)
        defaults?.set(holdThreshold, forKey: Self.delayKey)
    }

    private static func validatedDelay(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return 0.4 }
        return (min(1.0, max(0.2, delay)) * 5).rounded() / 5
    }

    func handleDown() {
        guard case .idle = gesture else { return }
        gesture = .pressed(now() + holdThreshold)
        let timer = Timer(timeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceHold() }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The timer and release both check elapsed time, including a delayed timer delivery.
    func advanceHold() {
        guard case .pressed(let deadline) = gesture,
              now() >= deadline else { return }
        invalidateTimer()
        applyFlip(temporary: true)
    }

    func handleUp() {
        advanceHold()
        finishGesture(commitTap: true)
    }

    func handleWake() { cancelActiveGesture() }
    func prepareForTermination() { cancelActiveGesture() }
    func cancelActiveGesture() { finishGesture(commitTap: false) }

    private func finishGesture(commitTap: Bool) {
        invalidateTimer()
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
        micController.refreshState()
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
        if micController.setMuted(muted, retryOnFailure: retryOnFailure), playsFeedback {
            ClickSoundPlayer.shared.play()
        }
    }

    private func invalidateTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}
