import Foundation
import AppKit
import Combine

/// How automatic rotation picks the next wallpaper.
///
/// macOS has no wifi-only axis (the Android sibling's middle option) — rotation is already auto-gated on online/offline — so the source axis collapses to two real states. The network rule stays automatic within `.fresh`.
enum RotationMode: String, CaseIterable, Identifiable {
	/// Download fresh when online; rotate the saved pool when offline (the historical behavior).
	case fresh

	/// Never download — cycle only the pinned set.
	/// Works offline; the manual "Update Wallpaper Now" still fetches fresh.
	/// With nothing pinned, scheduled updates pause (and say so in the UI) rather than fall back to downloading.
	case pinnedOnly = "pinned_only"

	var id: String { rawValue }

	var label: String {
		switch self {
			case .fresh:
				return "Fresh"
			case .pinnedOnly:
				return "Pinned only"
		}
	}
}

@MainActor
class WallpaperManager: ObservableObject {
	static let shared = WallpaperManager()

	private var sessionDidResignActiveObserver: NSObjectProtocol?
	private var sessionDidBecomeActiveObserver: NSObjectProtocol?
	var isSessionActive: Bool = true

	private var screenDidLockObserver: NSObjectProtocol?
	private var screenDidUnlockObserver: NSObjectProtocol?
	var isScreenLocked: Bool = false

	/// Set while the locked-session sanitizer has stripped our wallpaper config from the store, so unlock knows to put the wallpaper back.
	var didSanitizeWallpaperStoreWhileLocked = false

	private let networkMonitor = NetworkMonitor.shared
	private var networkCancellable: AnyCancellable?

	@Published
	private(set) var isOnline: Bool = true

	init() {
		let stored = UserDefaults.standard.object(forKey: "poolSize") as? Int ?? 10
		// "Current only" used to be 0; it's now 1 so the current wallpaper shows in the gallery. Migrate any persisted 0.
		let migratedPoolSize = stored == 0 ? 1 : stored
		if migratedPoolSize != stored {
			UserDefaults.standard.set(migratedPoolSize, forKey: "poolSize")
		}

		_poolSize = Published(initialValue: migratedPoolSize)

		let storedMode = UserDefaults.standard.string(forKey: "rotationMode")
			.flatMap(RotationMode.init(rawValue:)) ?? .fresh

		_rotationMode = Published(initialValue: storedMode)

		setupSessionObservers()
		setupScreenLockObservers()
		setupNetworkObserver()
		loadPoolFromDisk()
		setupSettingsObserver()
	}

	private var autoUpdateTask: Task<Void, Never>?
	private var timerInterval: TimeInterval = 60
	var savedUpdateInterval: TimeInterval {
		let value = UserDefaults.standard.double(forKey: "updateInterval")

		return if value > 0 { value } else { 60 }
	}

	@Published var poolsByBucket: [String: [URL]] = [:]
	@Published var currentByBucket: [String: URL] = [:]

	@Published var poolSize: Int = 10 {
		didSet {
			UserDefaults.standard.set(poolSize, forKey: "poolSize")
		}
	}

	@Published var rotationMode: RotationMode = .fresh {
		didSet {
			UserDefaults.standard.set(rotationMode.rawValue, forKey: "rotationMode")
		}
	}

	@Published
	var isRunning = false

	@Published
	var lastUpdated: Date?

	@Published
	var error: String?

	/// The in-flight background pool fill, if any. Held so settings changes, going offline, or stopping can cancel it.
	var prefetchTask: Task<Void, Never>?

	/// Bumped on every fill start/cancel so a superseded fill's completion no-ops instead of clobbering a newer one.
	var prefetchGeneration = 0

	/// True while a background fill runs; drives the gallery's "Filling pool…" indicator.
	@Published
	var isPrefetching = false

	/// Best-effort count of wallpapers still to download in the current fill.
	@Published
	var prefetchRemaining = 0

	/// Debounced observer of the search/pool settings that should refill the pool.
	var topUpSettingsCancellable: AnyCancellable?

	/// Last-seen settings snapshot, so unrelated UserDefaults writes don't restart the fill.
	var lastPrefetchInputs: PrefetchInputs?

	private let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return formatter
	}()

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
		cancelPoolTopUp()
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
						self.requestPoolTopUp()
					} else {
						print("Network went offline.")
						self.cancelPoolTopUp()
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

		guard isSessionActive else {
			print("Session inactive (fast user switch). Skipping auto-update.")
			return
		}

		guard !isScreenLocked else {
			print("Screen locked. Skipping auto-update.")
			return
		}

		await updateWallpaper()
		cleanupOldWallpapers()
		requestPoolTopUp()
	}

	private func setupSessionObservers() {
		sessionDidResignActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.sessionDidResignActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			guard let self else { return }

			Task { @MainActor in
				self.isSessionActive = false
				self.cancelPoolTopUp()
			}
		}

		sessionDidBecomeActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.sessionDidBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			guard let self else { return }

			Task { @MainActor in
				self.isSessionActive = true
				self.requestPoolTopUp()
			}
		}
	}

	/// Screen lock/unlock gating.
	/// `NSWorkspace.sessionDidResignActive` only fires on fast user switching, so locking the screen needs its own signal.
	/// While locked we skip the visible rotation, pause background fills, and strip our wallpaper config from the wallpaper store so the aerial screensaver dodges the macOS 26.5 WindowServer meltdown (see `WallpaperStoreSanitizer`); on unlock the wallpaper and the fill come back.
	/// Delivered as `DistributedNotificationCenter` broadcasts.
	private func setupScreenLockObservers() {
		screenDidLockObserver = DistributedNotificationCenter.default().addObserver(
			forName: Notification.Name("com.apple.screenIsLocked"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			guard let self else { return }

			Task { @MainActor in
				self.isScreenLocked = true
				self.cancelPoolTopUp()
				self.sanitizeWallpaperStoreForLockedSession()
			}
		}

		screenDidUnlockObserver = DistributedNotificationCenter.default().addObserver(
			forName: Notification.Name("com.apple.screenIsUnlocked"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			guard let self else { return }

			Task { @MainActor in
				self.isScreenLocked = false
				self.restoreWallpaperAfterUnlock()
				self.requestPoolTopUp()
			}
		}

		// A launch (or crash-relaunch, or update-restart) that happens while the screen is already locked never sees the notification edge, so read the live session state once after registering.
		let session = CGSessionCopyCurrentDictionary() as? [String: Any]
		if Self.isScreenLocked(inSessionDictionary: session) {
			isScreenLocked = true
			sanitizeWallpaperStoreForLockedSession()
		}
	}
}
