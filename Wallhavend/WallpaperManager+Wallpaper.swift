import Foundation
import AppKit

extension WallpaperManager {
	func updateWallpaper() async {
		error = nil

		let screens = NSScreen.screens
		guard !screens.isEmpty else {
			print("No screens detected. Skipping update.")
			return
		}

		var screensByBucket: [AspectBucket: [NSScreen]] = [:]
		for screen in screens {
			let bucket = AspectBucket.forScreen(screen)
			screensByBucket[bucket, default: []].append(screen)
		}

		if isOnline {
			await withTaskGroup(of: Void.self) { group in
				for (bucket, bucketScreens) in screensByBucket {
					group.addTask { [weak self] in
						await self?.updateWallpaperForBucket(bucket: bucket, screens: bucketScreens)
					}
				}
			}
		} else {
			for (bucket, bucketScreens) in screensByBucket {
				await rotatePoolForBucket(bucket: bucket, screens: bucketScreens)
			}
		}
	}

	@MainActor
	private func updateWallpaperForBucket(bucket: AspectBucket, screens: [NSScreen]) async {
		do {
			let atleast = AspectBucket.atleastString(for: screens)
			let wallpaper = try await WallhavenService.shared.fetchRandomWallpaper(
				ratios: bucket.rawValue,
				atleast: atleast
			)

			let (data, fileExtension) = try await downloadWallpaper(from: wallpaper.path)
			let wallpaperPath = try saveWallpaper(
				data: data,
				id: wallpaper.id,
				fileExtension: fileExtension,
				bucket: bucket
			)

			try applyWallpaper(url: wallpaperPath, to: screens)

			prependToPool(url: wallpaperPath, bucket: bucket.rawValue)
			currentByBucket[bucket.rawValue] = wallpaperPath
			lastUpdated = Date()
			print("Updated wallpaper for bucket \(bucket.rawValue): \(wallpaperPath.lastPathComponent)")
		} catch {
			self.error = error.localizedDescription
			print("Failed to update wallpaper for bucket \(bucket.rawValue): \(error)")
		}
	}

	@MainActor
	private func rotatePoolForBucket(bucket: AspectBucket, screens: [NSScreen]) async {
		guard let list = poolsByBucket[bucket.rawValue], let oldest = list.last else {
			print("Offline and pool empty for \(bucket.rawValue). Skipping.")
			return
		}

		do {
			error = nil
			try applyWallpaper(url: oldest, to: screens)
			prependToPool(url: oldest, bucket: bucket.rawValue)
			currentByBucket[bucket.rawValue] = oldest
			lastUpdated = Date()
			print("Rotated pool wallpaper for \(bucket.rawValue): \(oldest.lastPathComponent)")
		} catch {
			self.error = "Failed to apply wallpaper: \(error.localizedDescription)"
		}
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

	private func saveWallpaper(data: Data, id: String, fileExtension: String, bucket: AspectBucket) throws -> URL {
		let storageURL = try getWallpaperStorageDirectory()
		let bucketDir = storageURL.appendingPathComponent(bucket.rawValue, isDirectory: true)
		try FileManager.default.createDirectory(at: bucketDir, withIntermediateDirectories: true)

		let wallpaperPath = bucketDir.appendingPathComponent("\(id).\(fileExtension)")
		print("Saving wallpaper to: \(wallpaperPath.path)")
		try data.write(to: wallpaperPath)

		guard NSImage(contentsOf: wallpaperPath) != nil else {
			try? FileManager.default.removeItem(at: wallpaperPath)
			throw WallpaperError.invalidImage
		}

		return wallpaperPath
	}

	func applyWallpaper(url: URL, to screens: [NSScreen]) throws {
		let workspace = NSWorkspace.shared
		let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
			.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
			.allowClipping: false,
			.fillColor: NSColor.black
		]

		for screen in screens {
			print("Applying wallpaper to screen \(screen.localizedName): \(url.lastPathComponent)")
			try workspace.setDesktopImageURL(url, for: screen, options: options)
		}
	}
}
