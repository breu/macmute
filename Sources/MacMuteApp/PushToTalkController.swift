import AppKit
import Foundation

enum HotkeyMode: String {
    case pushToMute
    case pushToUnmute

    var displayName: String {
        switch self {
        case .pushToMute: return "Push to Mute"
        case .pushToUnmute: return "Push to Unmute"
        }
    }

    /// The muted state this mode's action puts the mic into.
    var targetMutedState: Bool {
        self == .pushToMute
    }

    /// The mic's resting/baseline state while this mode is active — the opposite of
    /// what the mode's action produces, since the action is what "pushes" away from it.
    var restingMutedState: Bool {
        self == .pushToUnmute
    }
}

/// Interprets the global hotkey's down/up edges as a tap, a double-click, or a hold:
/// - Double-click toggles the mode.
/// - A single tap performs the current mode's action and leaves it.
/// - A hold performs the mode's action while held, then reverts to the prior mic state on release.
final class PushToTalkController {

    static let shared = PushToTalkController()

    private(set) var mode: HotkeyMode
    var onModeChanged: ((HotkeyMode) -> Void)?

    private let holdThreshold: TimeInterval = 0.3
    /// Keyboard taps run slower than mouse clicks, so floor the system's double-click
    /// speed setting rather than using it as-is — respects a user who's set it slower,
    /// but doesn't inherit an unreasonably tight value from a fast mouse-click setting.
    private let doubleClickWindow: TimeInterval = max(NSEvent.doubleClickInterval, 0.5)

    private var holdTimer: Timer?
    private var pendingTapTimer: Timer?
    private var tapCount = 0
    private var isHoldActive = false
    private var micStateBeforeHold: Bool?

    private static let defaultsKey = "MacMute.hotkeyMode"

    private init() {
        mode = Self.loadMode() ?? .pushToMute
        MicMuteController.shared.setMuted(mode.restingMutedState)
        HotkeyManager.shared.onHotkeyDown = { [weak self] in self?.handleDown() }
        HotkeyManager.shared.onHotkeyUp = { [weak self] in self?.handleUp() }
    }

    private func handleDown() {
        isHoldActive = false
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: holdThreshold, repeats: false) { [weak self] _ in
            self?.beginHold()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func handleUp() {
        holdTimer?.invalidate()
        holdTimer = nil

        if isHoldActive {
            isHoldActive = false
            if let prior = micStateBeforeHold {
                MicMuteController.shared.setMuted(prior)
            }
            micStateBeforeHold = nil
            return
        }

        registerTap()
    }

    private func beginHold() {
        isHoldActive = true
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        tapCount = 0
        micStateBeforeHold = MicMuteController.shared.isMuted
        applyModeAction()
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
            self?.resolveSingleTap()
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingTapTimer = timer
    }

    private func resolveSingleTap() {
        guard tapCount == 1 else { return }
        tapCount = 0
        pendingTapTimer = nil
        applyModeAction()
    }

    private func applyModeAction() {
        MicMuteController.shared.setMuted(mode.targetMutedState)
    }

    func setMode(_ newMode: HotkeyMode) {
        guard newMode != mode else { return }
        mode = newMode
        Self.saveMode(mode)
        MicMuteController.shared.setMuted(mode.restingMutedState)
        onModeChanged?(mode)
    }

    private func toggleMode() {
        setMode(mode == .pushToMute ? .pushToUnmute : .pushToMute)
    }

    private static func loadMode() -> HotkeyMode? {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(HotkeyMode.init(rawValue:))
    }

    private static func saveMode(_ mode: HotkeyMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }
}
