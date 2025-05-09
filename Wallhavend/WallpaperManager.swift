import Foundation
import AppKit

@MainActor
class WallpaperManager: ObservableObject {
	static let shared = WallpaperManager()

	@Published
	var autoScaling = true

	@Published
	var manualScaling: NSImageScaling = .scaleProportionallyUpOrDown

	private var timer: Timer?
	private var currentWallpaperFileURL: URL?
	private var previousWallpaperFileURL: URL?
	private var deletionWorkItem: DispatchWorkItem?

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

	func startAutoUpdate(interval: TimeInterval = 60) {
		stopAutoUpdate()
		isRunning = true

		// Clean up old wallpapers on start
		cleanupOldWallpapers()

		timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
			guard let self = self else {
				return
			}

			Task { @MainActor in
				await self.updateWallpaper()
				self.cleanupOldWallpapers()
			}
		}

		timer?.fire()
	}

	func stopAutoUpdate() {
		timer?.invalidate()
		timer = nil
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

	private func saveAndProcessWallpaper(data: Data, id: String, fileExtension: String) async throws -> URL {
		let appSupportURL = try FileManager.default.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)
		.appendingPathComponent("Wallhavend", isDirectory: true)

		try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

		let wallpaperPath = appSupportURL.appendingPathComponent("\(id).\(fileExtension)")
		print("Saving wallpaper to: \(wallpaperPath.path)")
		try data.write(to: wallpaperPath)

		guard NSImage(contentsOf: wallpaperPath) != nil else {
			try? FileManager.default.removeItem(at: wallpaperPath)
			throw WallpaperError.invalidImage
		}

		return wallpaperPath
	}

	private func setWallpaperAndUpdateState(wallpaperPath: URL, originalURL: String) async throws {
		if let oldURL = currentWallpaperFileURL {
			previousWallpaperFileURL = oldURL
			scheduleWallpaperDeletion(fileURL: oldURL, delay: timer?.timeInterval ?? 60)
		}

		currentWallpaperFileURL = wallpaperPath

		guard let image = NSImage(contentsOf: wallpaperPath) else {
			throw WallpaperError.invalidImage
		}

		print("Setting wallpaper for all screens and spaces...")
		try setWallpaperForAllScreens(url: wallpaperPath, image: image)
		print("Wallpaper set successfully")

		currentWallpaperURL = URL(string: originalURL)
		lastUpdated = Date()
	}

	private func setWallpaperForAllScreens(url: URL, image: NSImage) throws {
		let workspace = NSWorkspace.shared
		let screens = NSScreen.screens
		print("Found \(screens.count) screen(s)")

		for (index, screen) in screens.enumerated() {
			let imageScaling = self.autoScaling
				? determineImageScaling(for: image, on: screen)
				: manualScaling

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
			let appSupportURL = try FileManager.default.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			.appendingPathComponent("Wallhavend", isDirectory: true)

			let fileManager = FileManager.default
			let files = try fileManager.contentsOfDirectory(at: appSupportURL, includingPropertiesForKeys: [.creationDateKey])

			// Keep current and previous wallpapers
			let wallpapersToKeep = Set([currentWallpaperFileURL, previousWallpaperFileURL].compactMap { $0 })

			for file in files {
				guard !wallpapersToKeep.contains(file) else { continue }

				try? fileManager.removeItem(at: file)
				print("Cleaned up old wallpaper: \(file.lastPathComponent)")
			}
		} catch {
			print("Failed to cleanup old wallpapers: \(error)")
		}
	}

	private func scheduleWallpaperDeletion(fileURL: URL, delay: TimeInterval) {
		// Cancel any pending deletion
		deletionWorkItem?.cancel()

		// Schedule new deletion
		let workItem = DispatchWorkItem { [weak self] in
			guard let self = self else { return }

			// Only delete if this URL is not the current or previous wallpaper
			if fileURL != self.currentWallpaperFileURL && fileURL != self.previousWallpaperFileURL {
				try? FileManager.default.removeItem(at: fileURL)
				print("Deleted old wallpaper: \(fileURL.lastPathComponent)")
			}
		}

		deletionWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
	}
}
