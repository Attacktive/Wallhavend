import XCTest
@testable import Wallhavend

@MainActor
final class BlocklistTests: XCTestCase {
	private func makeWallpaper(id: String) -> Wallpaper {
		Wallpaper(
			id: id,
			url: "https://wallhaven.cc/w/\(id)",
			path: "https://w.wallhaven.cc/full/\(id.prefix(2))/wallhaven-\(id).jpg",
			resolution: "1920x1080",
			fileSize: 1024,
			fileType: "image/jpeg",
			category: "general",
			purity: "sfw"
		)
	}

	// MARK: - Pure selection step

	func testSelectDropsBlockedAndPicksNext() {
		let wallpapers = [makeWallpaper(id: "aaa"), makeWallpaper(id: "bbb"), makeWallpaper(id: "ccc")]

		let result = WallhavenService.selectWallpaper(from: wallpapers, blocked: ["aaa"])

		let unwrapped = try? XCTUnwrap(result)
		XCTAssertEqual(unwrapped?.selected.id, "bbb")
		XCTAssertEqual(unwrapped?.remaining.map(\.id), ["ccc"])
	}

	func testSelectSkipsLeadingBlockedRun() {
		let wallpapers = [makeWallpaper(id: "aaa"), makeWallpaper(id: "bbb"), makeWallpaper(id: "ccc")]

		let result = WallhavenService.selectWallpaper(from: wallpapers, blocked: ["aaa", "bbb"])

		XCTAssertEqual(result?.selected.id, "ccc")
		XCTAssertTrue(result?.remaining.isEmpty == true)
	}

	func testSelectReturnsNilWhenAllBlocked() {
		let wallpapers = [makeWallpaper(id: "aaa"), makeWallpaper(id: "bbb")]

		let result = WallhavenService.selectWallpaper(from: wallpapers, blocked: ["aaa", "bbb"])

		XCTAssertNil(result)
	}

	func testSelectReturnsNilForEmptyInput() {
		let result = WallhavenService.selectWallpaper(from: [], blocked: [])

		XCTAssertNil(result)
	}

	func testSelectKeepsEverythingWhenNothingBlocked() {
		let wallpapers = [makeWallpaper(id: "aaa"), makeWallpaper(id: "bbb"), makeWallpaper(id: "ccc")]

		let result = WallhavenService.selectWallpaper(from: wallpapers, blocked: [])

		XCTAssertEqual(result?.selected.id, "aaa")
		XCTAssertEqual(result?.remaining.map(\.id), ["bbb", "ccc"])
	}

	// MARK: - Persistence round-tripping through UserDefaults

	func testBlockUnblockRoundTripsThroughUserDefaults() {
		let service = WallhavenService.shared
		let saved = UserDefaults.standard.string(forKey: "blockedIds")
		defer { UserDefaults.standard.set(saved, forKey: "blockedIds") }

		service.blockedIds = []
		service.block("abc123")
		service.block("def456")

		XCTAssertEqual(service.blockedIds, ["abc123", "def456"])

		// The raw string in UserDefaults is comma-joined and survives a fresh read.
		let raw = UserDefaults.standard.string(forKey: "blockedIds")
		XCTAssertEqual(raw, "abc123,def456")

		service.unblock("abc123")
		XCTAssertEqual(service.blockedIds, ["def456"])
		XCTAssertEqual(UserDefaults.standard.string(forKey: "blockedIds"), "def456")
	}

	func testBlockingSameIdTwiceIsIdempotent() {
		let service = WallhavenService.shared
		let saved = UserDefaults.standard.string(forKey: "blockedIds")
		defer { UserDefaults.standard.set(saved, forKey: "blockedIds") }

		service.blockedIds = []
		service.block("dupe")
		service.block("dupe")

		XCTAssertEqual(service.blockedIds, ["dupe"])
	}
}
