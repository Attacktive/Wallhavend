import Network
import Combine

@MainActor
class NetworkMonitor: ObservableObject {
	static let shared = NetworkMonitor()

	@Published
	private(set) var isOnline: Bool = true

	private let monitor = NWPathMonitor()
	private let queue = DispatchQueue(label: "NetworkMonitor")

	private init() {
		monitor.pathUpdateHandler = { [weak self] path in
			Task { @MainActor [weak self] in
				self?.isOnline = path.status == .satisfied
			}
		}
		monitor.start(queue: queue)
	}

	deinit {
		monitor.cancel()
	}
}
