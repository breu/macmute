import AppKit
import Foundation

enum HotkeyMode: String {
    case pushToMute
    case pushToUnmute

    var displayName: String {
        switch self {
        case .pushToMute: "Push to Mute"
        case .pushToUnmute: "Push to Unmute"
        }
    }

    var targetMutedState: Bool { self == .pushToMute }
    var restingMutedState: Bool { self == .pushToUnmute }
}

/// Interprets the global hotkey's down/up edges as a tap, a double-click, or a hold.
/// Launching only observes microphone state; it never applies a mode-derived state.
@MainActor
final class PushToTalkController {
    static let shared = PushToTalkController(
        micController: .shared,
        hotkeyManager: .shared
    )

    private(set) var mode: HotkeyMode
    var onModeChanged: ((HotkeyMode) -> Void)?

    private let micController: MicMuteController
    private let playsFeedback: Bool
    private let holdThreshold: TimeInterval = 0.2
    private let doubleClickWindow: TimeInterval

    private var holdTimer: Timer?
    private var pendingTapTimer: Timer?
    private var tapCount = 0
    private var isHoldActive = false
    private var holdAttemptFailed = false
    private var micStateBeforeHold: Bool?

    private static let defaultsKey = "MacMute.hotkeyMode"

    init(
        micController: MicMuteController,
        hotkeyManager: HotkeyManager? = nil,
        playsFeedback: Bool = true,
        observesWake: Bool = true,
        initialMode: HotkeyMode? = nil,
        doubleClickWindow: TimeInterval = max(NSEvent.doubleClickInterval, 0.5)
    ) {
        self.micController = micController
        self.playsFeedback = playsFeedback
        self.doubleClickWindow = doubleClickWindow
        mode = initialMode ?? Self.loadMode() ?? .pushToMute

        hotkeyManager?.onHotkeyDown = { [weak self] in self?.handleDown() }
        hotkeyManager?.onHotkeyUp = { [weak self] in self?.handleUp() }
        hotkeyManager?.onHotkeyCancelled = { [weak self] in self?.cancelActiveGesture() }
        if observesWake {
            observeWake()
        }
    }

    func handleDown() {
        guard holdTimer == nil, !isHoldActive else { return }
        holdAttemptFailed = false
        let timer = Timer(timeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beginHold()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    func handleUp() {
        holdTimer?.invalidate()
        holdTimer = nil

        if isHoldActive {
            restoreActiveHold()
            return
        }
        if holdAttemptFailed {
            holdAttemptFailed = false
            return
        }
        registerTap()
    }

    func beginHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        tapCount = 0

        micController.refreshState()
        guard let prior = micController.state.mutedValue else {
            holdAttemptFailed = true
            return
        }
        micStateBeforeHold = prior
        guard applyModeAction() else {
            micStateBeforeHold = nil
            holdAttemptFailed = true
            return
        }
        isHoldActive = true
    }

    func handleWake() {
        if isHoldActive {
            restoreActiveHold()
        }
        clearGestureState()
    }

    func prepareForTermination() {
        if isHoldActive {
            restoreActiveHold()
        }
        clearGestureState()
    }

    func cancelActiveGesture() {
        if isHoldActive {
            restoreActiveHold()
        }
        clearGestureState()
    }

    @discardableResult
    func setMode(_ newMode: HotkeyMode) -> Bool {
        guard newMode != mode else { return true }
        if isHoldActive {
            guard restoreActiveHold() else {
                clearGestureState()
                return false
            }
        }
        clearGestureState()
        guard micController.setMuted(newMode.restingMutedState) else { return false }
        mode = newMode
        Self.saveMode(mode)
        onModeChanged?(mode)
        return true
    }

    private func registerTap() {
        tapCount += 1
        if tapCount >= 2 {
            pendingTapTimer?.invalidate()
            pendingTapTimer = nil
            tapCount = 0
            toggleMode()
            return
        }

        pendingTapTimer?.invalidate()
        let timer = Timer(timeInterval: doubleClickWindow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resolveSingleTap()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingTapTimer = timer
    }

    private func resolveSingleTap() {
        guard tapCount == 1 else { return }
        tapCount = 0
        pendingTapTimer = nil
        _ = applyModeAction()
    }

    @discardableResult
    private func applyModeAction() -> Bool {
        let succeeded = micController.setMuted(mode.targetMutedState)
        if succeeded, playsFeedback {
            ClickSoundPlayer.shared.play()
        }
        return succeeded
    }

    @discardableResult
    private func restoreActiveHold() -> Bool {
        isHoldActive = false
        guard let prior = micStateBeforeHold else { return true }
        let succeeded = micController.setMuted(prior, retryOnFailure: true)
        if succeeded, playsFeedback {
            ClickSoundPlayer.shared.play()
        }
        micStateBeforeHold = nil
        return succeeded
    }

    private func clearGestureState() {
        holdTimer?.invalidate()
        holdTimer = nil
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        tapCount = 0
        isHoldActive = false
        holdAttemptFailed = false
        micStateBeforeHold = nil
    }

    private func toggleMode() {
        let changed = setMode(mode == .pushToMute ? .pushToUnmute : .pushToMute)
        if changed, playsFeedback {
            ClickSoundPlayer.shared.playModeChange()
        }
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        }
    }

    private static func loadMode() -> HotkeyMode? {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(HotkeyMode.init(rawValue:))
    }

    private static func saveMode(_ mode: HotkeyMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }
}
