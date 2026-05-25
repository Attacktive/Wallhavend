import AppKit

extension WallpaperManager {
	func loadPoolFromDisk() {
		guard let storageURL = try? getWallpaperStorageDirectory() else { return }

		let fileManager = FileManager.default
		guard let files = try? fileManager.contentsOfDirectory(
			at: storageURL,
			includingPropertiesForKeys: [.contentModificationDateKey],
			options: .skipsHiddenFiles
		) else { return }

		let sorted = files.sorted { left, right in
			let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
			let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

			return leftDate > rightDate
		}

		poolPaths = Array(sorted.prefix(poolSize))
		currentWallpaperFileURL = sorted.first
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

	func cleanupOldWallpapers() {
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
