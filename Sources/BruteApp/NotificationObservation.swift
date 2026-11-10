import Foundation

/// Removes a block-based notification observer when its owner releases it.
final class NotificationObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(
        center: NotificationCenter,
        name: Notification.Name,
        object: Any? = nil,
        queue: OperationQueue? = nil,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: queue, using: handler)
    }

    deinit {
        center.removeObserver(token)
    }
}
