import Foundation

/// Strips the wallpaper-store configs that melt WindowServer while the aerial screensaver plays.
///
/// macOS 26.5 has a compositor bug: whenever WallpaperAgent's store holds a Desktop slot with the legacy image provider — the only kind `NSWorkspace.setDesktopImageURL` can write — WindowServer portal-nests its layer tree and pegs a CPU core for as long as the aerial Idle wallpaper renders, dropping it to a slideshow on ProMotion displays.
/// Built-in providers (`choice.sonoma`, `choice.macintosh`, …) and the photo-shuffle provider don't trigger the meltdown, and those slots belong to the user, so the sanitizer removes exactly the legacy image slots and nothing else.
enum WallpaperStoreSanitizer {
	static let legacyImageProvider = "com.apple.wallpaper.choice.image"

	static var defaultStoreURL: URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
	}

	/// Removes every `Desktop` slot whose choices use the legacy image provider, anywhere in the tree, and reports how many were removed.
	static func strippingImageDesktopConfigurations(from root: [String: Any]) -> (result: [String: Any], removedSlotCount: Int) {
		var removedSlotCount = 0

		func sanitizedDictionary(_ dictionary: [String: Any]) -> [String: Any] {
			var result = [String: Any]()
			for (key, value) in dictionary {
				if key == "Desktop", isLegacyImageSlot(value) {
					removedSlotCount += 1
					continue
				}

				result[key] = sanitizedValue(value)
			}

			return result
		}

		func sanitizedValue(_ node: Any) -> Any {
			if let dictionary = node as? [String: Any] {
				return sanitizedDictionary(dictionary)
			} else if let array = node as? [Any] {
				return array.map(sanitizedValue)
			} else {
				return node
			}
		}

		let result = sanitizedDictionary(root)

		return (result, removedSlotCount)
	}

	private static func isLegacyImageSlot(_ value: Any) -> Bool {
		guard
			let slot = value as? [String: Any],
			let content = slot["Content"] as? [String: Any],
			let choices = content["Choices"] as? [[String: Any]]
		else {
			return false
		}

		return choices.contains { $0["Provider"] as? String == legacyImageProvider }
	}

	/// Reads the store, strips the legacy image Desktop slots, and writes it back atomically. Returns whether the file changed.
	@discardableResult
	static func sanitizeStore(at url: URL = defaultStoreURL) throws -> Bool {
		let data = try Data(contentsOf: url)
		guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
			return false
		}

		let (result, removedSlotCount) = strippingImageDesktopConfigurations(from: root)
		guard removedSlotCount > 0 else {
			return false
		}

		let output = try PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0)
		try output.write(to: url, options: .atomic)

		return true
	}

	/// WallpaperAgent only rereads the store on launch, so a strip must be followed by a relaunch; launchd respawns the agent immediately.
	/// Only call this after the sanitizer actually removed something — a relaunch mid-lock with any surviving Desktop slot retriggers the very meltdown this works around.
	static func relaunchWallpaperAgent() {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
		process.arguments = ["WallpaperAgent"]

		do {
			try process.run()
		} catch {
			print("Failed to relaunch WallpaperAgent: \(error)")
		}
	}
}

extension WallpaperManager {
	/// Locked-session guard: nobody sees the desktop while the screen is locked, so dropping the poisonous config costs nothing and buys a smooth aerial.
	func sanitizeWallpaperStoreForLockedSession() {
		do {
			let changed = try WallpaperStoreSanitizer.sanitizeStore()
			if changed {
				didSanitizeWallpaperStoreWhileLocked = true
				WallpaperStoreSanitizer.relaunchWallpaperAgent()
				print("Stripped legacy image wallpaper configs for the locked session.")
			}
		} catch {
			print("Skipping wallpaper-store sanitizing: \(error)")
		}
	}

	/// Undo of the locked-session strip: put the current wallpaper back the moment the user can see the desktop again.
	func restoreWallpaperAfterUnlock() {
		guard didSanitizeWallpaperStoreWhileLocked else {
			return
		}

		didSanitizeWallpaperStoreWhileLocked = false

		guard let screensByBucket = currentScreensByBucket() else {
			return
		}

		for (bucket, screens) in screensByBucket {
			guard let url = currentByBucket[bucket.rawValue] else {
				continue
			}

			do {
				try applyWallpaper(url: url, to: screens)
			} catch {
				print("Failed to restore the wallpaper after unlock: \(error)")
			}
		}
	}
}
