import Foundation
import AppKit
import Combine

@MainActor
class WallpaperManager: ObservableObject {
	static let shared = WallpaperManager()

	private var sessionDidResignActiveObserver: NSObjectProtocol?
	private var sessionDidBecomeActiveObserver: NSObjectProtocol?
	private var isSessionActive: Bool = true

	private let networkMonitor = NetworkMonitor.shared
	private var networkCancellable: AnyCancellable?

	@Published
	private(set) var isOnline: Bool = true

	init() {
		// Initialise _poolSize directly to avoid didSet writing UserDefaults on launch
		let stored = UserDefaults.standard.object(forKey: "poolSize") as? Int ?? 10
		_poolSize = Published(initialValue: stored)

		setupSessionObservers()
		setupNetworkObserver()
		loadPoolFromDisk()
	}

	@Published
	var autoScaling = true

	@Published
	var manualScaling: NSImageScaling = .scaleProportionallyUpOrDown

	private var autoUpdateTask: Task<Void, Never>?
	private var timerInterval: TimeInterval = 60
	var savedUpdateInterval: TimeInterval {
		let value = UserDefaults.standard.double(forKey: "updateInterval")

		return if value > 0 { value } else { 60 }
	}

	var currentWallpaperFileURL: URL?

	@Published var poolPaths: [URL] = []

	var previousWallpaperFileURL: URL? { poolPaths.count > 1 ? poolPaths[1] : nil }

	@Published var poolSize: Int = 10 {
		didSet {
			UserDefaults.standard.set(poolSize, forKey: "poolSize")
		}
	}

	@Published
	var isRunning = false

	@Published
	var lastUpdated: Date?

	@Published
	var currentWallpaperURL: URL?

	@Published
	var error: String?

	private let wallhavenService = WallhavenService.shared
	private let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return formatter
	}()

	var hasCurrentWallpaper: Bool {
		currentWallpaperFileURL != nil
	}

	var formattedLastUpdated: String {
		guard let lastUpdated = lastUpdated else {
			return ""
		}

		return dateFormatter.string(from: lastUpdated)
	}

	func startAutoUpdate(interval: TimeInterval? = nil) {
		timerInterval = interval ?? savedUpdateInterval

		stopAutoUpdate()

		isRunning = true

		cleanupOldWallpapers()

		autoUpdateTask = Task { [weak self] in
			guard let self else { return }

			await self.runAutoUpdateLoop()
		}
	}

	func stopAutoUpdate() {
		autoUpdateTask?.cancel()
		autoUpdateTask = nil
		isRunning = false
	}

	private func setupNetworkObserver() {
		networkCancellable = networkMonitor.$isOnline
			.dropFirst()
			.sink { [weak self] isOnline in
				guard let self else { return }
				Task { @MainActor [weak self] in
					guard let self else { return }

					self.isOnline = isOnline
					if isOnline {
						print("Network came online.")
					} else {
						print("Network went offline.")
					}
				}
			}
	}

	private func runAutoUpdateLoop() async {
		await self.performAutoUpdateTick()

		while !Task.isCancelled {
			do {
				if #available(macOS 13.0, *) {
					try await Task.sleep(for: .seconds(timerInterval))
				} else {
					try await Task.sleep(nanoseconds: UInt64(timerInterval * 1_000_000_000))
				}
			} catch is CancellationError {
				return
			} catch {
				print("Auto-update loop stopped due to unexpected sleep error: \(error)")
				stopAutoUpdate()

				return
			}

			await self.performAutoUpdateTick()
		}
	}

	private func performAutoUpdateTick() async {
		guard isRunning else { return }

		guard isOnline else {
			if let oldest = poolPaths.last {
				await applyFromPool(url: oldest)
			} else {
				print("Offline and pool is empty. Skipping auto-update.")
			}

			return
		}

		guard isSessionActive else {
			print("Session inactive (screensaver/lock). Skipping auto-update.")
			return
		}

		await updateWallpaper()
		cleanupOldWallpapers()
	}

	private func setupSessionObservers() {
		sessionDidResignActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.sessionDidResignActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			guard let self else { return }
			Task { @MainActor in self.isSessionActive = false }
		}

		sessionDidBecomeActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.sessionDidBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			guard let self else { return }
			Task { @MainActor in self.isSessionActive = true }
		}
	}
}
