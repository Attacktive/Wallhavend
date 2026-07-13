import XCTest
@testable import Wallhavend

/// The sanitizer guards the aerial screensaver against the macOS 26.5 WindowServer meltdown: any Desktop slot using the legacy image provider in WallpaperAgent's store makes the compositor portal-nest its layer tree and peg a core while the aerial Idle wallpaper renders.
/// These tests pin the ownership rule: strip exactly the legacy image slots (the kind `setDesktopImageURL` writes), never the user's built-in or photo-shuffle choices, and report whether anything changed so the caller can skip the WallpaperAgent relaunch when the store was already safe.
final class WallpaperStoreSanitizerTests: XCTestCase {
	private let displayUUID = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
	private let spaceUUID = "66ABA353-E405-47F7-B1EB-BE97A0551DDD"

	// MARK: - Fixtures mirroring the real store shapes captured on macOS 26.5.2

	private func slot(provider: String) -> [String: Any] {
		[
			"Content": [
				"Choices": [
					[
						"Provider": provider,
						"Configuration": Data([0x62, 0x70]),
						"Files": [Any]()
					]
				],
				"EncodedOptionValues": Data([0x62, 0x70]),
				"Shuffle": "$null"
			],
			"LastSet": Date(timeIntervalSince1970: 1_752_000_000),
			"LastUse": Date(timeIntervalSince1970: 1_752_000_100)
		]
	}

	private func idleAerialsSlot() -> [String: Any] {
		slot(provider: "com.apple.wallpaper.choice.aerials")
	}

	/// The four-scope shape the legacy `setDesktopImageURL` path writes: the same image Desktop slot at SystemDefault, the Space default, the per-Space display override, and the display scope.
	private func legacyPoisonedStore() -> [String: Any] {
		[
			"AllSpacesAndDisplays": [
				"Idle": idleAerialsSlot(),
				"Type": "idle"
			],
			"SystemDefault": [
				"Desktop": slot(provider: WallpaperStoreSanitizer.legacyImageProvider),
				"Idle": idleAerialsSlot(),
				"Type": "individual"
			],
			"Spaces": [
				spaceUUID: [
					"Default": [
						"Desktop": slot(provider: WallpaperStoreSanitizer.legacyImageProvider),
						"Idle": idleAerialsSlot(),
						"Type": "individual"
					],
					"Displays": [
						displayUUID: [
							"Desktop": slot(provider: WallpaperStoreSanitizer.legacyImageProvider),
							"Type": "individual"
						]
					]
				]
			],
			"Displays": [
				displayUUID: [
					"Desktop": slot(provider: WallpaperStoreSanitizer.legacyImageProvider),
					"Idle": idleAerialsSlot(),
					"Type": "individual"
				]
			]
		]
	}

	private func builtInStore() -> [String: Any] {
		[
			"AllSpacesAndDisplays": [
				"Desktop": slot(provider: "com.apple.wallpaper.choice.sonoma"),
				"Idle": idleAerialsSlot(),
				"Type": "individual"
			],
			"SystemDefault": [
				"Desktop": slot(provider: "com.apple.wallpaper.choice.sonoma"),
				"Idle": idleAerialsSlot(),
				"Type": "individual"
			],
			"Spaces": [String: Any](),
			"Displays": [String: Any]()
		]
	}

	private func desktopSlotCount(in root: [String: Any], provider: String? = nil) -> Int {
		var count = 0

		func walk(_ node: Any) {
			if let dictionary = node as? [String: Any] {
				for (key, value) in dictionary {
					if key == "Desktop", let slot = value as? [String: Any], let content = slot["Content"] as? [String: Any] {
						let choices = content["Choices"] as? [[String: Any]] ?? []
						if provider == nil || choices.contains(where: { $0["Provider"] as? String == provider }) {
							count += 1
						}
					}

					walk(value)
				}
			} else if let array = node as? [Any] {
				for value in array {
					walk(value)
				}
			}
		}

		walk(root)

		return count
	}

	private func idleSlotCount(in root: [String: Any]) -> Int {
		var count = 0

		func walk(_ node: Any) {
			if let dictionary = node as? [String: Any] {
				for (key, value) in dictionary {
					if key == "Idle", let slot = value as? [String: Any], slot["Content"] != nil {
						count += 1
					}

					walk(value)
				}
			} else if let array = node as? [Any] {
				for value in array {
					walk(value)
				}
			}
		}

		walk(root)

		return count
	}

	// MARK: - Pure transform

	func testStripsEveryLegacyImageDesktopSlot() {
		let store = legacyPoisonedStore()
		XCTAssertEqual(desktopSlotCount(in: store), 4)

		let (result, removedSlotCount) = WallpaperStoreSanitizer.strippingImageDesktopConfigurations(from: store)

		XCTAssertEqual(removedSlotCount, 4)
		XCTAssertEqual(desktopSlotCount(in: result), 0)
	}

	func testStrippingPreservesIdleSlotsAndSurroundingKeys() {
		let store = legacyPoisonedStore()

		let (result, _) = WallpaperStoreSanitizer.strippingImageDesktopConfigurations(from: store)

		XCTAssertEqual(idleSlotCount(in: result), idleSlotCount(in: store))
		let systemDefault = result["SystemDefault"] as? [String: Any]
		XCTAssertEqual(systemDefault?["Type"] as? String, "individual")
		let spaces = result["Spaces"] as? [String: Any]
		XCTAssertNotNil(spaces?[spaceUUID], "the Space subtree itself must survive; only its Desktop slot goes")
	}

	func testLeavesBuiltInDesktopSlotsAlone() {
		let store = builtInStore()

		let (result, removedSlotCount) = WallpaperStoreSanitizer.strippingImageDesktopConfigurations(from: store)

		XCTAssertEqual(removedSlotCount, 0)
		XCTAssertTrue((result as NSDictionary).isEqual(to: store))
	}

	func testLeavesPhotoShuffleDesktopSlotsAlone() throws {
		var store = builtInStore()
		var allSpaces = try XCTUnwrap(store["AllSpacesAndDisplays"] as? [String: Any])
		allSpaces["Desktop"] = slot(provider: "com.apple.wallpaper.extension.image")
		store["AllSpacesAndDisplays"] = allSpaces

		let (result, removedSlotCount) = WallpaperStoreSanitizer.strippingImageDesktopConfigurations(from: store)

		XCTAssertEqual(removedSlotCount, 0)
		XCTAssertTrue((result as NSDictionary).isEqual(to: store))
	}

	func testRemovesOnlyImageSlotsInMixedStore() throws {
		var store = legacyPoisonedStore()
		var systemDefault = try XCTUnwrap(store["SystemDefault"] as? [String: Any])
		systemDefault["Desktop"] = slot(provider: "com.apple.wallpaper.choice.sonoma")
		store["SystemDefault"] = systemDefault

		let (result, removedSlotCount) = WallpaperStoreSanitizer.strippingImageDesktopConfigurations(from: store)

		XCTAssertEqual(removedSlotCount, 3)
		XCTAssertEqual(desktopSlotCount(in: result), 1)
		XCTAssertEqual(desktopSlotCount(in: result, provider: "com.apple.wallpaper.choice.sonoma"), 1)
	}

	func testNoOpOnStoreWithoutDesktopSlots() {
		let store: [String: Any] = [
			"AllSpacesAndDisplays": [
				"Idle": idleAerialsSlot(),
				"Type": "idle"
			]
		]

		let (result, removedSlotCount) = WallpaperStoreSanitizer.strippingImageDesktopConfigurations(from: store)

		XCTAssertEqual(removedSlotCount, 0)
		XCTAssertTrue((result as NSDictionary).isEqual(to: store))
	}

	// MARK: - File round trip

	private func temporaryStoreURL() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("WallpaperStoreSanitizerTests-\(UUID().uuidString)", isDirectory: true)
			.appendingPathComponent("Index.plist")
	}

	private func write(_ store: [String: Any], to url: URL) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
		try data.write(to: url)
	}

	func testSanitizeRewritesPoisonedStoreFile() throws {
		let url = temporaryStoreURL()
		try write(legacyPoisonedStore(), to: url)

		let changed = try WallpaperStoreSanitizer.sanitizeStore(at: url)

		XCTAssertTrue(changed)
		let data = try Data(contentsOf: url)
		let reloaded = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
		XCTAssertEqual(desktopSlotCount(in: reloaded), 0)
		XCTAssertEqual(idleSlotCount(in: reloaded), 4)
	}

	func testSanitizeLeavesCleanStoreFileUntouched() throws {
		let url = temporaryStoreURL()
		try write(builtInStore(), to: url)
		let before = try Data(contentsOf: url)

		let changed = try WallpaperStoreSanitizer.sanitizeStore(at: url)

		XCTAssertFalse(changed)
		XCTAssertEqual(try Data(contentsOf: url), before)
	}

	func testSanitizeThrowsOnMissingStoreFile() {
		let url = temporaryStoreURL()

		XCTAssertThrowsError(try WallpaperStoreSanitizer.sanitizeStore(at: url))
	}
}
