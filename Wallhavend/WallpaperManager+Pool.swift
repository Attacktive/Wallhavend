import AppKit
import ImageIO

extension WallpaperManager {
	func loadPoolFromDisk() {
		guard let storageURL = try? getWallpaperStorageDirectory() else { return }

		migrateFlatFilesToBuckets(in: storageURL)

		let fileManager = FileManager.default
		let blockedIds = WallhavenService.shared.blockedIds
		let pinnedIds = WallhavenService.shared.pinnedIds
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

			// Don't re-adopt a blocked wallpaper that's still sitting on disk.
			let usable = files.filter { !blockedIds.contains(wallpaperId(for: $0)) }
			let sorted = usable.sorted { left, right in
				let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
				let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

				return leftDate > rightDate
			}

			if !sorted.isEmpty {
				loadedPools[bucket.rawValue] = Self.poolEntries(sorted: sorted, pinnedIds: pinnedIds, poolSize: poolSize)
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
		guard !WallhavenService.shared.blockedIds.contains(wallpaperId(for: url)) else {
			print("Refusing to apply blocked wallpaper: \(url.lastPathComponent)")
			return
		}

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
		poolsByBucket[bucket] = Self.poolEntries(sorted: list, pinnedIds: WallhavenService.shared.pinnedIds, poolSize: poolSize)
	}

	func revealInFinder(url: URL) {
		NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
	}

	func openStorageDirectoryInFinder() {
		guard let url = try? getWallpaperStorageDirectory() else { return }

		NSWorkspace.shared.open(url)
	}

	/// Wallhaven IDs are the local filename stem (see `saveWallpaper`).
	func wallpaperId(for url: URL) -> String {
		url.deletingPathExtension().lastPathComponent
	}

	/// Build the in-memory pool list for a bucket: keep every pinned file, plus the newest `poolSize` non-pinned files.
	/// Pinned files do not count toward `poolSize` — the target governs only the rotating, non-pinned buffer — so they survive regardless of how small `poolSize` is. `sorted` must be newest-first; the returned list preserves that order.
	nonisolated static func poolEntries(sorted: [URL], pinnedIds: Set<String>, poolSize: Int) -> [URL] {
		var nonPinnedKept = 0
		var result: [URL] = []

		for url in sorted {
			let id = url.deletingPathExtension().lastPathComponent
			if pinnedIds.contains(id) {
				result.append(url)
			} else if nonPinnedKept < poolSize {
				result.append(url)
				nonPinnedKept += 1
			}
		}

		return result
	}

	/// Pick the next pinned wallpaper to apply in Pinned-only mode: the oldest pinned, non-blocked entry. Pools are newest-first, so that's the last match; applying it moves it to the front, so successive ticks walk the whole pinned set. Returns nil when the bucket has no usable pinned file.
	nonisolated static func nextPinnedToRotate(pool: [URL], pinnedIds: Set<String>, blockedIds: Set<String>) -> URL? {
		pool.last {
			let id = $0.deletingPathExtension().lastPathComponent

			return pinnedIds.contains(id) && !blockedIds.contains(id)
		}
	}

	func copyWallhavenURL(for url: URL) {
		let id = wallpaperId(for: url)
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString("https://wallhaven.cc/w/\(id)", forType: .string)
	}

	/// Flip a wallpaper's pinned state. Pinning protects it from pool eviction and adds it to the Pinned-only rotation set.
	func togglePin(url: URL) {
		let id = wallpaperId(for: url)
		if WallhavenService.shared.pinnedIds.contains(id) {
			WallhavenService.shared.unpin(id)
		} else {
			WallhavenService.shared.pin(id)
		}
	}

	/// The menu-bar pin toggle's three states, derived from the wallpaper(s) actually on screen, restricted to gallery (pool) members.
	enum CurrentPinAction: Equatable {
		/// Nothing on screen is a managed gallery wallpaper — the menu item is shown disabled.
		case unavailable
		/// At least one on-screen gallery wallpaper isn't pinned — the item reads "Pin Current Wallpaper" and pins them all.
		case pin
		/// Every on-screen gallery wallpaper is already pinned — the item reads "Unpin Current Wallpaper" and unpins them all.
		case unpin
	}

	/// Decide what the "Pin Current Wallpaper" menu item should do, given the ids on screen, the gallery's pool ids, and the pinned set.
	/// Only pool members are pinnable, so an on-screen wallpaper this instance doesn't manage (or hasn't loaded) is ignored — a stale or foreign desktop image can't be pinned.
	/// Unpin only when *every* pinnable current is already pinned.
	nonisolated static func pinAction(currentIds: [String], poolIds: Set<String>, pinnedIds: Set<String>) -> CurrentPinAction {
		let pinnable = currentIds.filter { poolIds.contains($0) }

		guard !pinnable.isEmpty else {
			return .unavailable
		}

		return if pinnable.allSatisfy({ pinnedIds.contains($0) }) {
			.unpin
		} else {
			.pin
		}
	}

	/// The wallpapers actually on screen right now, read from the system per display, de-duplicated across screens.
	/// This is the live desktop — not the app's internal record, which can be stale or reflect a wallpaper set by another instance.
	var currentWallpaperURLs: [URL] {
		var seen = Set<URL>()

		return NSScreen.screens
			.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }
			.filter { seen.insert($0).inserted }
	}

	/// Every wallpaper id present in the in-memory pool (i.e. shown in the Gallery), across all buckets.
	var poolWallpaperIds: Set<String> {
		Set(poolsByBucket.values.flatMap { $0 }.map { wallpaperId(for: $0) })
	}

	/// The pin action for whatever is actually on screen now, restricted to gallery members — drives the menu item's title, enabled state, and behavior.
	var currentPinAction: CurrentPinAction {
		Self.pinAction(
			currentIds: currentWallpaperURLs.map { wallpaperId(for: $0) },
			poolIds: poolWallpaperIds,
			pinnedIds: WallhavenService.shared.pinnedIds
		)
	}

	/// Pin every on-screen gallery wallpaper, or unpin them all when they're already pinned — the menu-bar counterpart to the Gallery's per-item pin.
	/// On-screen wallpapers not in the gallery are ignored; it's a no-op when none are.
	func toggleCurrentWallpaperPin() {
		let poolIds = poolWallpaperIds
		let currentIds = currentWallpaperURLs.map { wallpaperId(for: $0) }
		let pinnable = currentIds.filter { poolIds.contains($0) }
		let action = Self.pinAction(currentIds: currentIds, poolIds: poolIds, pinnedIds: WallhavenService.shared.pinnedIds)

		guard action != .unavailable else {
			return
		}

		for id in pinnable {
			if action == .unpin {
				WallhavenService.shared.unpin(id)
			} else {
				WallhavenService.shared.pin(id)
			}
		}
	}

	/// What to do after a wallpaper is blocked, given whether it was the current one and what's left in the bucket's pool.
	enum BlockReplacementAction: Equatable {
		case doNothing
		case applyFromPool(URL)
		case fetch
	}

	/// Decide how to replace a just-blocked wallpaper for one bucket: nothing when it wasn't current, the oldest
	/// remaining non-blocked pool entry when one exists, otherwise a fetch. `blockedIds` already includes the just-blocked id.
	nonisolated static func replacementAction(wasCurrent: Bool, pool: [URL], blockedIds: Set<String>) -> BlockReplacementAction {
		guard wasCurrent else {
			return .doNothing
		}

		let oldestUsable = pool.last { !blockedIds.contains($0.deletingPathExtension().lastPathComponent) }

		guard let oldestUsable else {
			return .fetch
		}

		return .applyFromPool(oldestUsable)
	}

	/// Block a wallpaper so it's never applied again, and evict any on-disk copy immediately — the user wants it gone now, not just on the next fetch.
	/// If it was the wallpaper currently on screen, replace it right away (pool-first, fetch as fallback) so the user stops looking at what they just blocked.
	func blockWallpaper(url: URL) async {
		let id = wallpaperId(for: url)

		// Capture the buckets currently showing this wallpaper before eviction repoints currentByBucket and erases the signal.
		let affectedBuckets = AspectBucket.allCases.filter { bucket in
			guard let current = currentByBucket[bucket.rawValue] else {
				return false
			}

			return wallpaperId(for: current) == id
		}

		WallhavenService.shared.block(id)
		WallhavenService.shared.unpin(id)
		evictFromPool(id: id)

		for bucket in affectedBuckets {
			await replaceBlockedCurrent(in: bucket)
		}
	}

	/// Replace a bucket's just-blocked current wallpaper: prefer a remaining pool item, otherwise fall back to a normal update (fetch online, no-op offline with an empty pool).
	private func replaceBlockedCurrent(in bucket: AspectBucket) async {
		let action = Self.replacementAction(wasCurrent: true, pool: poolsByBucket[bucket.rawValue] ?? [], blockedIds: WallhavenService.shared.blockedIds)

		switch action {
			case .doNothing:
				return
			case .applyFromPool(let replacement):
				await applyFromPool(url: replacement, bucket: bucket.rawValue)
			case .fetch:
				let screens = NSScreen.screens.filter { AspectBucket.forScreen($0).rawValue == bucket.rawValue }
				guard !screens.isEmpty else {
					return
				}

				await updateBucket(bucket, screens: screens)
		}
	}

	/// Remove every copy of `id` from the pool and disk, across all buckets — the same image can be saved under more than one bucket.
	func evictFromPool(id: String) {
		let matches: [(url: URL, bucket: String)] = AspectBucket.allCases.flatMap { bucket -> [(URL, String)] in
			let urls = poolsByBucket[bucket.rawValue] ?? []

			return urls
				.filter { wallpaperId(for: $0) == id }
				.map { ($0, bucket.rawValue) }
		}

		for match in matches {
			deleteFromPool(url: match.url, bucket: match.bucket)
		}
	}

	func cleanupOldWallpapers() {
		do {
			let storageURL = try getWallpaperStorageDirectory()
			let fileManager = FileManager.default
			let pinnedIds = WallhavenService.shared.pinnedIds

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

				for file in files where pinnedIds.contains(wallpaperId(for: file)) {
					// Pinned files are exempt from cleanup, even at the minimum pool size ("apply and forget").
					toKeep.insert(file.standardized)
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
