import AppKit
import Foundation

/// A press flips mute immediately. Release restores it unless it completes a double press.
@MainActor
final class MicrophoneActionController {
    static let shared = MicrophoneActionController(micController: .shared, hotkeyManager: .shared)

    private struct Tap {
        let releasedAt: TimeInterval
        let deviceGeneration: UInt64
    }

    private enum Gesture {
        case idle
        case pressed(at: TimeInterval, temporary: MicMuteController.TemporaryMute)
        case ignored
    }

    private let micController: MicMuteController
    private let feedback: FeedbackPlaying?
    private let doubleClickInterval: TimeInterval
    private let now: () -> TimeInterval
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
            feedback: ClickSoundPlayer.shared
        )
    }

    init(
        micController: MicMuteController,
        hotkeyManager: HotkeyManager? = nil,
        feedback: FeedbackPlaying?,
        observesWake: Bool = true,
        doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.micController = micController
        self.feedback = feedback
        self.doubleClickInterval = doubleClickInterval
        self.now = now
        hotkeyManager?.onHotkeyDown = { [weak self] timestamp in self?.handleDown(at: timestamp) }
        hotkeyManager?.onHotkeyUp = { [weak self] timestamp in self?.handleUp(at: timestamp) }
        hotkeyManager?.onHotkeyCancelled = { [weak self] in self?.cancelActiveGesture() }
        // HotkeyManager resets its own edges and cancels the gesture together.
        if observesWake, hotkeyManager == nil {
            observeWake()
        }
    }

    func handleDown(at timestamp: TimeInterval? = nil) {
        guard case .idle = gesture else { return }
        let pressedAt = eventTime(timestamp)
        guard let temporary = micController.beginTemporaryToggle() else {
            previousTap = nil
            gesture = .ignored
            return
        }
        gesture = .pressed(at: pressedAt, temporary: temporary)
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
        guard case .pressed(let pressedAt, let temporary) = finished else { return }
        let firstTap = previousTap
        previousTap = nil
        let tap = releasedAt.flatMap { time in
            time >= pressedAt && time <= pressedAt + doubleClickInterval
                ? Tap(releasedAt: time, deviceGeneration: temporary.deviceGeneration)
                : nil
        }
        if let tap, let firstTap,
           firstTap.deviceGeneration == tap.deviceGeneration,
           firstTap.releasedAt <= pressedAt,
           tap.releasedAt <= firstTap.releasedAt + doubleClickInterval,
           micController.commitTemporaryToggle(temporary) {
            return
        }
        guard micController.endTemporaryToggle(temporary) else { return }
        previousTap = tap
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
