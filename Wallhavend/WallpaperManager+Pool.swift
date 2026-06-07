import AppKit
import ImageIO

extension WallpaperManager {
	func loadPoolFromDisk() {
		guard let storageURL = try? getWallpaperStorageDirectory() else { return }

		migrateFlatFilesToBuckets(in: storageURL)

		let fileManager = FileManager.default
		var loadedPools: [String: [URL]] = [:]
		var loadedCurrent: [String: URL] = [:]

		for bucket in AspectBucket.allCases {
			let bucketDir = storageURL.appendingPathComponent(bucket.rawValue, isDirectory: true)
			guard let files = try? fileManager.contentsOfDirectory(
				at: bucketDir,
				includingPropertiesForKeys: [.contentModificationDateKey],
				options: .skipsHiddenFiles
			) else {
				continue
			}

			let sorted = files.sorted { left, right in
				let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
				let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

				return leftDate > rightDate
			}

			if !sorted.isEmpty {
				loadedPools[bucket.rawValue] = Array(sorted.prefix(poolSize))
				loadedCurrent[bucket.rawValue] = sorted.first
			}
		}

		poolsByBucket = loadedPools
		currentByBucket = loadedCurrent
	}

	nonisolated static func readImagePixelDimensions(at url: URL) -> (Int, Int)? {
		guard
			let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
			let width = props[kCGImagePropertyPixelWidth as String] as? Int,
			let height = props[kCGImagePropertyPixelHeight as String] as? Int,
			width > 0,
			height > 0
		else {
			return nil
		}

		return (width, height)
	}

	@discardableResult
	nonisolated static func migrateFlatFilesToBuckets(in storageURL: URL) -> Int {
		let fileManager = FileManager.default
		guard
			let entries = try? fileManager.contentsOfDirectory(
				at: storageURL,
				includingPropertiesForKeys: [.isDirectoryKey],
				options: .skipsHiddenFiles
			)
		else {
			return 0
		}

		var movedCount = 0
		for entry in entries {
			let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
			if isDirectory { continue }

			guard let (width, height) = readImagePixelDimensions(at: entry) else {
				try? fileManager.removeItem(at: entry)
				print("Migration deleted unreadable flat file: \(entry.lastPathComponent)")
				continue
			}

			let aspect = Double(width) / Double(height)
			let bucket = AspectBucket.snap(aspectRatio: aspect)
			let bucketDir = storageURL.appendingPathComponent(bucket.rawValue, isDirectory: true)

			do {
				try fileManager.createDirectory(at: bucketDir, withIntermediateDirectories: true)
				let dest = bucketDir.appendingPathComponent(entry.lastPathComponent)
				if fileManager.fileExists(atPath: dest.path) {
					try? fileManager.removeItem(at: entry)
				} else {
					try fileManager.moveItem(at: entry, to: dest)
				}

				movedCount += 1
			} catch {
				print("Migration failed for \(entry.lastPathComponent): \(error)")
			}
		}

		return movedCount
	}

	func migrateFlatFilesToBuckets(in storageURL: URL) {
		_ = Self.migrateFlatFilesToBuckets(in: storageURL)
	}

	func applyFromPool(url: URL, bucket: String) async {
		let targetScreens = NSScreen.screens.filter {
			AspectBucket.forScreen($0).rawValue == bucket
		}

		guard !targetScreens.isEmpty else {
			print("No screens currently in bucket \(bucket); pool entry unused.")
			return
		}

		guard FileManager.default.fileExists(atPath: url.path) else {
			print("Pool wallpaper no longer exists: \(url.lastPathComponent)")
			poolsByBucket[bucket]?.removeAll { $0 == url }
			return
		}

		do {
			error = nil
			try applyWallpaper(url: url, to: targetScreens)
			prependToPool(url: url, bucket: bucket)
			currentByBucket[bucket] = url
			lastUpdated = Date()
			print("Applied pool wallpaper for \(bucket): \(url.lastPathComponent)")
		} catch {
			self.error = "Failed to apply wallpaper: \(error.localizedDescription)"
			print("Failed to apply pool wallpaper: \(error)")
		}
	}

	func deleteFromPool(url: URL, bucket: String) {
		poolsByBucket[bucket]?.removeAll { $0 == url }
		if poolsByBucket[bucket]?.isEmpty == true {
			poolsByBucket.removeValue(forKey: bucket)
		}

		try? FileManager.default.removeItem(at: url)

		if currentByBucket[bucket] == url {
			currentByBucket[bucket] = poolsByBucket[bucket]?.first
			if currentByBucket[bucket] == nil {
				currentByBucket.removeValue(forKey: bucket)
			}
		}

		print("Deleted from pool [\(bucket)]: \(url.lastPathComponent)")
	}

	func prependToPool(url: URL, bucket: String) {
		var list = poolsByBucket[bucket] ?? []
		list.removeAll { $0 == url }
		list.insert(url, at: 0)
		poolsByBucket[bucket] = Array(list.prefix(poolSize))
	}

	func revealInFinder(url: URL) {
		NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
	}

	func openStorageDirectoryInFinder() {
		guard let url = try? getWallpaperStorageDirectory() else { return }

		NSWorkspace.shared.open(url)
	}

	func copyWallhavenURL(for url: URL) {
		let id = url.deletingPathExtension().lastPathComponent
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString("https://wallhaven.cc/w/\(id)", forType: .string)
	}

	func cleanupOldWallpapers() {
		do {
			let storageURL = try getWallpaperStorageDirectory()
			let fileManager = FileManager.default

			var toKeep = Set<URL>()
			for list in poolsByBucket.values {
				for url in list { toKeep.insert(url.standardized) }
			}

			for url in currentByBucket.values {
				toKeep.insert(url.standardized)
			}

			for bucket in AspectBucket.allCases {
				let dir = storageURL.appendingPathComponent(bucket.rawValue, isDirectory: true)
				guard
					let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
				else {
					continue
				}

				for file in files where !toKeep.contains(file.standardized) {
					try? fileManager.removeItem(at: file)
					print("Cleaned up old wallpaper: \(file.lastPathComponent)")
				}
			}
		} catch {
			print("Failed to cleanup old wallpapers: \(error)")
		}
	}
}
