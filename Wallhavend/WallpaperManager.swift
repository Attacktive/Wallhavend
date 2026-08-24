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

	private let networkMonitor = NetworkMonitor.shared
	private var networkCancellable: AnyCancellable?

	@Published private(set) var isOnline: Bool = true

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

	/// Which sources automatic rotation and pool fills may draw from.
	/// Defaults to Wallhaven alone, so an install that never opts in keeps exactly today's behavior and today's network traffic.
	@Published var enabledSources: Set<WallpaperSource> = [.wallhaven] {
		didSet {
			UserDefaults.standard.set(Self.encodeSources(enabledSources), forKey: "enabledSources")
		}
	}

	@Published var isRunning = false

	/// The in-flight wallpaper update, if any. Held so a stalled download can be cancelled and so a second update can't start on top of one.
	var updateTask: Task<Void, Never>? {
		didSet {
			isUpdating = updateTask != nil
		}
	}

	/// Mirrors `updateTask`, so SwiftUI and the status-bar menu can observe it.
	@Published private(set) var isUpdating = false
	@Published var lastUpdated: Date?
	@Published var error: String?

	/// The in-flight background pool fill, if any. Held so settings changes, going offline, or stopping can cancel it.
	var prefetchTask: Task<Void, Never>?

	/// Bumped on every fill start/cancel so a superseded fill's completion no-ops instead of clobbering a newer one.
	var prefetchGeneration = 0

	/// True while a background fill runs; drives the gallery's "Filling pool…" indicator.
	@Published var isPrefetching = false

	/// Best-effort count of wallpapers still to download in the current fill.
	@Published var prefetchRemaining = 0

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

	/// Determines if a manual update is allowed: true when online and no update is currently running.
	var canUpdateNow: Bool {
		Self.canUpdateNow(isOnline: isOnline, isUpdating: isUpdating)
	}

	/// Core logic for `canUpdateNow`, extracted for testing.
	static func canUpdateNow(isOnline: Bool, isUpdating: Bool) -> Bool {
		isOnline && !isUpdating
	}

	init() {
		let stored = UserDefaults.standard.object(forKey: "poolSize") as? Int ?? 10
		// "Current only" used to be 0; it's now 1 so the current wallpaper shows in the gallery. Migrate any persisted 0.
		let migratedPoolSize = if stored == 0 { 1 } else { stored }
		if migratedPoolSize != stored {
			UserDefaults.standard.set(migratedPoolSize, forKey: "poolSize")
		}

		_poolSize = Published(initialValue: migratedPoolSize)

		let storedMode = UserDefaults.standard.string(forKey: "rotationMode")
			.flatMap(RotationMode.init(rawValue:)) ?? .fresh

		_rotationMode = Published(initialValue: storedMode)

		_enabledSources = Published(initialValue: Self.decodeSources(UserDefaults.standard.string(forKey: "enabledSources")))

		setupSessionObservers()
		setupScreenLockObservers()
		setupNetworkObserver()
		loadPoolFromDisk()
		setupSettingsObserver()
	}

	/// Comma-joined raw keys, sorted so the stored string doesn't churn on every write.
	nonisolated static func encodeSources(_ sources: Set<WallpaperSource>) -> String {
		sources.map { $0.rawValue }
			.sorted()
			.joined(separator: ",")
	}

	/// A missing, empty, or unrecognizable value falls back to Wallhaven.
	/// Everything downstream assumes at least one source is enabled, and Wallhaven is the one that needs no opt-in.
	nonisolated static func decodeSources(_ raw: String?) -> Set<WallpaperSource> {
		let parsed = Set(
			(raw ?? "").split(separator: ",")
				.compactMap { WallpaperSource(rawValue: String($0)) }
		)

		return if parsed.isEmpty { [.wallhaven] } else { parsed }
	}

	func startAutoUpdate(interval: TimeInterval? = nil, tickImmediately: Bool = true) {
		timerInterval = interval ?? savedUpdateInterval

		stopAutoUpdate()

		isRunning = true

		cleanupOldWallpapers()

		autoUpdateTask = Task { [weak self] in
			guard let self else { return }

			await self.runAutoUpdateLoop(tickImmediately: tickImmediately)
		}
	}

	func stopAutoUpdate() {
		autoUpdateTask?.cancel()
		autoUpdateTask = nil
		isRunning = false
		cancelPoolTopUp()
	}

	var updateGeneration = 0

	/// Serializes the wallpaper-applying paths: at most one runs at a time, and a stalled one can be cancelled.
	@discardableResult
	func runExclusively(_ body: @escaping @MainActor () async -> Void) -> Bool {
		guard updateTask == nil else { return false }

		updateGeneration += 1
		let generation = updateGeneration

		updateTask = Task { @MainActor [weak self] in
			defer {
				if self?.updateGeneration == generation {
					self?.updateTask = nil
				}
			}
			await body()
		}

		return true
	}

	/// Cancels any in-flight manual update, releasing the lock immediately and voiding the current task.
	func cancelUpdate() {
		updateGeneration += 1
		updateTask?.cancel()
		updateTask = nil
	}

	/// Request a manual update from the UI.
	func requestManualUpdate() {
		runExclusively { [weak self] in
			await self?.fetchFreshNow()
		}
	}

	/// The user's last explicit Start/Stop choice, persisted so it survives relaunch.
	/// Defaults to true, so "Start automatically on launch" works until the user explicitly stops.
	/// `bool(forKey:)` rather than a `Bool` cast, so coercible values (e.g. `-autoUpdateUserIntent NO` launch arguments, which arrive as strings) are honored too.
	var autoUpdateUserIntent: Bool {
		let defaults = UserDefaults.standard

		return if defaults.object(forKey: "autoUpdateUserIntent") == nil {
			true
		} else {
			defaults.bool(forKey: "autoUpdateUserIntent")
		}
	}

	/// User-facing Start: records the explicit intent, then starts.
	func startAutoUpdateExplicitly(interval: TimeInterval? = nil) {
		UserDefaults.standard.set(true, forKey: "autoUpdateUserIntent")
		startAutoUpdate(interval: interval)
	}

	/// User-facing Stop: records the explicit intent, then stops.
	/// Without the record, "start on launch" would resurrect auto-update on the next relaunch — and Sparkle's silent updates relaunch the app without the user asking.
	func stopAutoUpdateExplicitly() {
		UserDefaults.standard.set(false, forKey: "autoUpdateUserIntent")
		stopAutoUpdate()
	}

	/// Restarts the tick loop when the user picks a new interval while it runs, so the change doesn't wait out the current (possibly hours-long) sleep.
	/// Only the delay changes — restarting must not rotate the wallpaper on the spot, hence `tickImmediately: false`.
	/// The restart cancels any in-flight pool fill along the way, so it re-requests one rather than leaving the pool short until the next tick.
	func restartAutoUpdateIfIntervalChanged() {
		guard isRunning else { return }

		let interval = savedUpdateInterval
		guard interval != timerInterval else { return }

		startAutoUpdate(interval: interval, tickImmediately: false)
		requestPoolTopUp()
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

	private func runAutoUpdateLoop(tickImmediately: Bool) async {
		if tickImmediately {
			await self.performAutoUpdateTick()
		}

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

		let started = runExclusively { [weak self] in
			await self?.updateWallpaper()
			self?.cleanupOldWallpapers()
			self?.requestPoolTopUp()
		}

		if !started {
			print("Update already in progress. Skipping auto-update.")
		}
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
	/// While locked we skip the visible rotation and pause background fills; on unlock the fill resumes.
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
				self.requestPoolTopUp()
			}
		}
	}
}
