import Foundation
import Network

/// Whether this Mac has a usable network path.
///
/// Retrying ssh against a down interface just burns attempts on instant
/// failures; watching the path means a reconnect fires the moment the link is
/// actually back, rather than on the next backoff tick.
final class NetworkWatch {
    static let shared = NetworkWatch()

    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private var waiting: [() -> Void] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                let cameBack = online && !self.isOnline
                self.isOnline = online
                guard cameBack else { return }
                let pending = self.waiting
                self.waiting.removeAll()
                pending.forEach { $0() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "shh.network"))
    }

    /// Run `body` as soon as the network is back — immediately if it already is.
    func onceOnline(_ body: @escaping () -> Void) {
        if isOnline { body() } else { waiting.append(body) }
    }
}
