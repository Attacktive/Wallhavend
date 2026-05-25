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

	private func loadPoolFromDisk() {
		guard let storageURL = try? getWallpaperStorageDirectory() else { return }

		let fileManager = FileManager.default
		guard let files = try? fileManager.contentsOfDirectory(
			at: storageURL,
			includingPropertiesForKeys: [.contentModificationDateKey],
			options: .skipsHiddenFiles
		) else { return }

		let sorted = files.sorted { a, b in
			let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
			let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
			return aDate > bDate
		}

		poolPaths = Array(sorted.prefix(poolSize))
		currentWallpaperFileURL = sorted.first
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
			print("Offline. Skipping auto-update.")
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

	func stopAutoUpdate() {
		autoUpdateTask?.cancel()
		autoUpdateTask = nil
		isRunning = false
	}

	func updateWallpaper() async {
		do {
			error = nil

			let wallpaper = try await fetchRandomWallpaper()
			let (data, fileExtension) = try await downloadWallpaper(from: wallpaper.path)
			let wallpaperPath = try await saveAndProcessWallpaper(data: data, id: wallpaper.id, fileExtension: fileExtension)
			try await setWallpaperAndUpdateState(wallpaperPath: wallpaperPath, originalURL: wallpaper.path)
		} catch {
			self.error = error.localizedDescription
			print("Failed to update wallpaper: \(error)")
		}
	}

	func revealCurrentWallpaperInFinder() {
		guard let url = currentWallpaperFileURL else { return }

		NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
	}

	func restorePreviousWallpaper() async {
		guard let previous = poolPaths.dropFirst().first else {
			print("No previous wallpaper available")
			return
		}

		await applyFromPool(url: previous)
	}

	func applyFromPool(url: URL) async {
		guard
			FileManager.default.fileExists(atPath: url.path),
			let image = NSImage(contentsOf: url)
		else {
			print("Pool wallpaper no longer exists: \(url.lastPathComponent)")
			poolPaths.removeAll { $0 == url }
			return
		}

		do {
			error = nil
			try setWallpaperForAllScreens(url: url, image: image)

			poolPaths.removeAll { $0 == url }
			poolPaths.insert(url, at: 0)
			currentWallpaperFileURL = url
			lastUpdated = Date()
			print("Applied pool wallpaper: \(url.lastPathComponent)")
		} catch {
			self.error = "Failed to apply wallpaper: \(error.localizedDescription)"
			print("Failed to apply pool wallpaper: \(error)")
		}
	}

	func deleteFromPool(url: URL) {
		poolPaths.removeAll { $0 == url }
		try? FileManager.default.removeItem(at: url)

		if currentWallpaperFileURL == url {
			currentWallpaperFileURL = poolPaths.first
		}

		print("Deleted from pool: \(url.lastPathComponent)")
	}

	private func fetchRandomWallpaper() async throws -> Wallpaper {
		print("Fetching random wallpaper...")
		let wallpaper = try await WallhavenService.shared.fetchRandomWallpaper()
		print("Got wallpaper: \(wallpaper.path)")

		return wallpaper
	}

	private func downloadWallpaper(from path: String) async throws -> (Data, String) {
		guard let wallpaperURL = URL(string: path) else {
			throw WallpaperError.invalidURL
		}

		print("Downloading image from \(wallpaperURL)")
		let (data, response) = try await URLSession(configuration: .ephemeral)
			.data(from: wallpaperURL)

		guard let httpResponse = response as? HTTPURLResponse else {
			throw WallpaperError.invalidResponse
		}

		print("Download complete. Status: \(httpResponse.statusCode), Size: \(data.count) bytes")

		guard httpResponse.statusCode == 200 else {
			throw WallpaperError.httpError(httpResponse.statusCode)
		}

		guard let mimeType = httpResponse.mimeType else {
			throw WallpaperError.noContentType
		}

		print("Content-Type: \(mimeType)")
		let fileExtension = try getFileExtension(from: mimeType)

		return (data, fileExtension)
	}

	private func getFileExtension(from mimeType: String) throws -> String {
		if mimeType.contains("jpeg") || mimeType.contains("jpg") {
			return "jpg"
		} else if mimeType.contains("png") {
			return "png"
		}

		throw WallpaperError.unsupportedImageType(mimeType)
	}

	private func getWallpaperStorageDirectory() throws -> URL {
		let libraryURL = try FileManager.default.url(
			for: .libraryDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)
		let desktopPicturesURL = libraryURL
			.appendingPathComponent("Desktop Pictures", isDirectory: true)
			.appendingPathComponent("Wallhavend", isDirectory: true)

		try FileManager.default.createDirectory(at: desktopPicturesURL, withIntermediateDirectories: true)
		return desktopPicturesURL
	}

	private func saveAndProcessWallpaper(data: Data, id: String, fileExtension: String) async throws -> URL {
		let storageURL = try getWallpaperStorageDirectory()
		let wallpaperPath = storageURL.appendingPathComponent("\(id).\(fileExtension)")
		print("Saving wallpaper to: \(wallpaperPath.path)")
		try data.write(to: wallpaperPath)

		guard NSImage(contentsOf: wallpaperPath) != nil else {
			try? FileManager.default.removeItem(at: wallpaperPath)
			throw WallpaperError.invalidImage
		}

		return wallpaperPath
	}

	private func setWallpaperAndUpdateState(wallpaperPath: URL, originalURL: String) async throws {
		currentWallpaperFileURL = wallpaperPath

		guard let image = NSImage(contentsOf: wallpaperPath) else {
			throw WallpaperError.invalidImage
		}

		print("Setting wallpaper for all screens and spaces...")
		try setWallpaperForAllScreens(url: wallpaperPath, image: image)
		print("Wallpaper set successfully")

		poolPaths.removeAll { $0 == wallpaperPath }
		poolPaths.insert(wallpaperPath, at: 0)
		poolPaths = Array(poolPaths.prefix(poolSize))

		currentWallpaperURL = URL(string: originalURL)
		lastUpdated = Date()
	}

	private func setWallpaperForAllScreens(url: URL, image: NSImage) throws {
		let workspace = NSWorkspace.shared
		let screens = NSScreen.screens
		print("Found \(screens.count) screen(s)")

		for (index, screen) in screens.enumerated() {
			let imageScaling: NSImageScaling
			if self.autoScaling {
				imageScaling = determineImageScaling(for: image, on: screen)
			} else {
				imageScaling = manualScaling
			}

			let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
				.imageScaling: imageScaling.rawValue,
				.allowClipping: false,
				.fillColor: NSColor.black
			]

			print("Setting wallpaper for screen \(index + 1)")
			try workspace.setDesktopImageURL(url, for: screen, options: options)
		}
	}

	private func determineImageScaling(for image: NSImage, on screen: NSScreen) -> NSImageScaling {
		let imageAspectRatio = image.size.width / image.size.height
		let screenAspectRatio = screen.frame.width / screen.frame.height

		let threshold: CGFloat = 0.2
		let difference = abs(imageAspectRatio - screenAspectRatio)

		if difference > threshold {
			return .scaleAxesIndependently
		} else {
			return .scaleProportionallyUpOrDown
		}
	}

	private func cleanupOldWallpapers() {
		do {
			let storageURL = try getWallpaperStorageDirectory()
			let fileManager = FileManager.default
			let files = try fileManager.contentsOfDirectory(
				at: storageURL,
				includingPropertiesForKeys: nil
			)

			var toKeep = Set(poolPaths.map { $0.standardized })
			if let current = currentWallpaperFileURL {
				toKeep.insert(current.standardized)
			}

			for file in files where !toKeep.contains(file.standardized) {
				try? fileManager.removeItem(at: file)
				print("Cleaned up old wallpaper: \(file.lastPathComponent)")
			}
		} catch {
			print("Failed to cleanup old wallpapers: \(error)")
		}
	}

}

