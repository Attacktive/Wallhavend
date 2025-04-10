import Foundation
import AppKit

@MainActor
class WallpaperManager: ObservableObject {
	static let shared = WallpaperManager()
	private var timer: Timer?
	private var currentWallpaperFileURL: URL?
	private var previousWallpaperFileURL: URL?
	private var deletionWorkItem: DispatchWorkItem?
	@Published var isRunning = false
	@Published var lastUpdated: Date?
	@Published var currentWallpaperURL: URL?
	@Published var error: String?
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
		timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
			guard let self = self else {
				return
			}

			Task { @MainActor in
				await self.updateWallpaper()
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

			print("Fetching random wallpaper...")
			let wallpaper = try await WallhavenService.shared.fetchRandomWallpaper()
			print("Got wallpaper: \(wallpaper.path)")

			guard let wallpaperURL = URL(string: wallpaper.path) else {
				error = "Invalid wallpaper URL"
				return
			}

			print("Downloading image from \(wallpaperURL)")
			let (data, response) = try await URLSession(configuration: .ephemeral)
				.data(from: wallpaperURL)

			guard let httpResponse = response as? HTTPURLResponse else {
				error = "Invalid response type"
				return
			}

			print("Download complete. Status: \(httpResponse.statusCode), Size: \(data.count) bytes")

			guard let mimeType = httpResponse.mimeType else {
				error = "No content type in response"
				return
			}

			print("Content-Type: \(mimeType)")

			// Get the correct file extension from the response
			let fileExtension: String
			if mimeType.contains("jpeg") || mimeType.contains("jpg") {
				fileExtension = "jpg"
			} else if mimeType.contains("png") {
				fileExtension = "png"
			} else {
				error = "Unsupported image type: \(mimeType)"
				return
			}

			// Create wallpapers directory in Application Support
			let appSupportURL = try FileManager.default.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			.appendingPathComponent("Wallhavend", isDirectory: true)

			try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

			// Save the wallpaper with its ID as filename
			let wallpaperPath = appSupportURL.appendingPathComponent("\(wallpaper.id).\(fileExtension)")
			print("Saving wallpaper to: \(wallpaperPath.path)")

			try data.write(to: wallpaperPath)

			// Clean up previous wallpaper file after interval
			if let oldURL = currentWallpaperFileURL {
				previousWallpaperFileURL = oldURL
				scheduleWallpaperDeletion(fileURL: oldURL, delay: timer?.timeInterval ?? 60)
			}

			currentWallpaperFileURL = wallpaperPath

			// Verify the image can be loaded
			guard let image = NSImage(contentsOf: wallpaperPath) else {
				error = "Failed to load downloaded image"
				try? FileManager.default.removeItem(at: wallpaperPath)
				return
			}

			print("Setting wallpaper for all screens and spaces...")
			try setWallpaperForAllScreensAndSpaces(url: wallpaperPath, image: image)
			print("Wallpaper set successfully")

			currentWallpaperURL = wallpaperURL
			lastUpdated = Date()
		} catch {
			self.error = error.localizedDescription
			print("Failed to update wallpaper: \(error)")
		}
	}

	private func setWallpaperForAllScreensAndSpaces(url: URL, image: NSImage) throws {
		// Set some nice scaling options
		let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
			.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
			.allowClipping: false,
			.fillColor: NSColor.black
		]

		let workspace = NSWorkspace.shared

		// Get all screens
		let screens = NSScreen.screens
		print("Found \(screens.count) screen(s)")

		// Set wallpaper for each screen
		for (index, screen) in screens.enumerated() {
			print("Setting wallpaper for screen \(index + 1)")
			try workspace.setDesktopImageURL(url, for: screen, options: options)
		}
	}

	func revealCurrentWallpaperInFinder() {
		guard let url = currentWallpaperFileURL else { return }

		NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
	}

	private func scheduleWallpaperDeletion(fileURL: URL, delay: TimeInterval) {
		// Cancel any pending deletion
		deletionWorkItem?.cancel()

		// Create new deletion work item
		let workItem = DispatchWorkItem { [weak self] in
			guard let self = self else { return }

			do {
				if fileURL == self.previousWallpaperFileURL {
					try FileManager.default.removeItem(at: fileURL)
					self.previousWallpaperFileURL = nil
				}
			} catch {
				print("Failed to delete old wallpaper: \(error)")
			}
		}

		// Store the work item and schedule it
		deletionWorkItem = workItem
		DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay, execute: workItem)
	}
}
