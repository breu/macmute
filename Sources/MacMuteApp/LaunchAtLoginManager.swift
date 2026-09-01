import ServiceManagement

enum LaunchAtLoginError: LocalizedError {
    case requestFailed(Error)
    case requiresApproval
    case stateDidNotChange

    var errorDescription: String? {
        switch self {
        case .requestFailed(let error):
            "Launch at Login could not be updated: \(error.localizedDescription)"
        case .requiresApproval:
            "Approve MacMute in System Settings → General → Login Items."
        case .stateDidNotChange:
            "macOS did not apply the requested Launch at Login setting."
        }
    }
}

@MainActor
final class LaunchAtLoginManager {

    static let shared = LaunchAtLoginManager()

    private init() {}

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Result<Bool, LaunchAtLoginError> {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("MacMute: failed to update launch-at-login state: \(error)")
            return .failure(.requestFailed(error))
        }

        let actual = isEnabled
        guard actual == enabled else {
            if SMAppService.mainApp.status == .requiresApproval {
                return .failure(.requiresApproval)
            }
            return .failure(.stateDidNotChange)
        }
        return .success(actual)
    }
}
