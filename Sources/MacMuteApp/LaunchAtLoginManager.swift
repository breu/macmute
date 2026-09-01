import ServiceManagement

enum LaunchServiceStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

@MainActor
protocol LaunchServiceControlling: AnyObject {
    var status: LaunchServiceStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
private final class SystemLaunchService: LaunchServiceControlling {
    var status: LaunchServiceStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
protocol LaunchAtLoginManaging: AnyObject {
    var isEnabled: Bool { get }
    var isRequested: Bool { get }
    func setEnabled(_ enabled: Bool) -> Result<Bool, LaunchAtLoginError>
}

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
final class LaunchAtLoginManager: LaunchAtLoginManaging {

    static let shared = LaunchAtLoginManager()

    private let service: LaunchServiceControlling

    init(service: LaunchServiceControlling? = nil) {
        self.service = service ?? SystemLaunchService()
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    var isRequested: Bool {
        let status = service.status
        return status == .enabled || status == .requiresApproval
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Result<Bool, LaunchAtLoginError> {
        do {
            if enabled {
                switch service.status {
                case .enabled:
                    return .success(true)
                case .requiresApproval:
                    return .failure(.requiresApproval)
                case .notRegistered, .notFound:
                    try service.register()
                case .unknown:
                    return .failure(.stateDidNotChange)
                }
            } else {
                switch service.status {
                case .enabled, .requiresApproval:
                    try service.unregister()
                case .notRegistered, .notFound:
                    return .success(false)
                case .unknown:
                    return .failure(.stateDidNotChange)
                }
            }
        } catch {
            NSLog("MacMute: failed to update launch-at-login state: \(error)")
            return .failure(.requestFailed(error))
        }

        let status = service.status
        if enabled {
            if status == .requiresApproval {
                return .failure(.requiresApproval)
            }
            guard status == .enabled else { return .failure(.stateDidNotChange) }
            return .success(true)
        } else {
            guard status == .notRegistered || status == .notFound else {
                return .failure(.stateDidNotChange)
            }
            return .success(false)
        }
    }
}
