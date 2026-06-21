import Foundation
import AppKit

extension WallpaperManager {
	/// The automatic rotation tick. In `.fresh` mode it fetches fresh online and rotates the pool offline; in `.pinnedOnly` it never downloads and cycles only the pinned set (so it works offline too).
	func updateWallpaper() async {
		error = nil

		guard let screensByBucket = currentScreensByBucket() else {
			return
		}

		switch effectiveRotationMode {
			case .fresh:
				await runFreshUpdate(screensByBucket: screensByBucket)
			case .pinnedOnly:
				await runPinnedUpdate(screensByBucket: screensByBucket)
		}
	}

	/// Manual "Update Now": always fetch a fresh wallpaper, regardless of rotation mode (the button is gated to online-only). This is the on-demand "casual blend" the issue settled on — fetch fresh, pin it if you like it — that keeps Pinned-only useful.
	func fetchFreshNow() async {
		error = nil

		guard let screensByBucket = currentScreensByBucket() else {
			return
		}

		await runFreshUpdate(screensByBucket: screensByBucket)
	}

	/// Run the normal update for a single bucket, respecting the current rotation mode (used by the block-replacement fallback).
	func updateBucket(_ bucket: AspectBucket, screens: [NSScreen]) async {
		switch effectiveRotationMode {
			case .fresh:
				if isOnline {
					await updateWallpaperForBucket(bucket: bucket, screens: screens)
				} else {
					await rotatePoolForBucket(bucket: bucket, screens: screens)
				}
			case .pinnedOnly:
				await rotatePinnedForBucket(bucket: bucket, screens: screens)
		}
	}

	private func currentScreensByBucket() -> [AspectBucket: [NSScreen]]? {
		let screens = NSScreen.screens
		guard !screens.isEmpty else {
			print("No screens detected. Skipping update.")
			return nil
		}

		var screensByBucket: [AspectBucket: [NSScreen]] = [:]
		for screen in screens {
			let bucket = AspectBucket.forScreen(screen)
			screensByBucket[bucket, default: []].append(screen)
		}

		return screensByBucket
	}

	/// Fetch fresh per bucket when online; rotate the saved pool per bucket when offline (a no-op when the pool is empty).
	private func runFreshUpdate(screensByBucket: [AspectBucket: [NSScreen]]) async {
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

	/// Cycle the pinned set per bucket, never downloading. Buckets with no usable pinned file are skipped.
	private func runPinnedUpdate(screensByBucket: [AspectBucket: [NSScreen]]) async {
		for (bucket, bucketScreens) in screensByBucket {
			await rotatePinnedForBucket(bucket: bucket, screens: bucketScreens)
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
			let wallpaperPath = try await Task.detached(priority: .userInitiated) {
				try self.saveWallpaper(
					data: data,
					id: wallpaper.id,
					fileExtension: fileExtension,
					bucket: bucket
				)
			}.value

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
		let blockedIds = WallhavenService.shared.blockedIds

		guard
			let list = poolsByBucket[bucket.rawValue],
			let oldest = list.last(where: { !blockedIds.contains(wallpaperId(for: $0)) })
		else {
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

	/// Pinned-only rotation for a single bucket: apply the oldest usable pinned wallpaper, never downloading. A no-op when the bucket has no pinned file — Pinned-only honors "never download" rather than falling back to a fetch.
	@MainActor
	private func rotatePinnedForBucket(bucket: AspectBucket, screens: [NSScreen]) async {
		let pinnedIds = WallhavenService.shared.pinnedIds
		let blockedIds = WallhavenService.shared.blockedIds

		guard
			let list = poolsByBucket[bucket.rawValue],
			let target = Self.nextPinnedToRotate(pool: list, pinnedIds: pinnedIds, blockedIds: blockedIds)
		else {
			print("Pinned-only and no pinned wallpaper for \(bucket.rawValue). Skipping.")
			return
		}

		do {
			error = nil
			try applyWallpaper(url: target, to: screens)

			prependToPool(url: target, bucket: bucket.rawValue)
			currentByBucket[bucket.rawValue] = target
			lastUpdated = Date()
			print("Rotated pinned wallpaper for \(bucket.rawValue): \(target.lastPathComponent)")
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

	nonisolated func getWallpaperStorageDirectory() throws -> URL {
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

	nonisolated private func saveWallpaper(data: Data, id: String, fileExtension: String, bucket: AspectBucket) throws -> URL {
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
