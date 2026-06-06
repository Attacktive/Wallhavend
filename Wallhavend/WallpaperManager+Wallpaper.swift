import Foundation
import AppKit

extension WallpaperManager {
	func revealCurrentWallpaperInFinder() {
		guard let url = currentWallpaperFileURL else { return }

		NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
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

	private func fetchRandomWallpaper() async throws -> Wallpaper {
		print("Fetching random wallpaper...")
		let mainScreen = NSScreen.main ?? NSScreen.screens.first
		let ratios = mainScreen.map { AspectBucket.forScreen($0).rawValue } ?? "16x9"
		let atleast = mainScreen.map { AspectBucket.atleastString(for: [$0]) } ?? "1920x1080"
		let wallpaper = try await WallhavenService.shared.fetchRandomWallpaper(ratios: ratios, atleast: atleast)
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

	func getWallpaperStorageDirectory() throws -> URL {
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

	func setWallpaperForAllScreens(url: URL, image: NSImage) throws {
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
}
