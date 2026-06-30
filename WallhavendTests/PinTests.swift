import XCTest
@testable import Wallhavend

@MainActor
final class PinTests: XCTestCase {
	/// A pool URL whose filename stem is the wallhaven id (see `WallpaperManager.wallpaperId(for:)`).
	private func url(_ id: String) -> URL {
		URL(fileURLWithPath: "/tmp/16x9/\(id).jpg")
	}

	// MARK: - poolEntries: pinned files survive trimming

	func testPoolEntriesCapsNonPinnedToPoolSize() {
		let sorted = [url("a"), url("b"), url("c"), url("d")]

		let result = WallpaperManager.poolEntries(sorted: sorted, pinnedIds: [], poolSize: 2)

		XCTAssertEqual(result, [url("a"), url("b")])
	}

	func testPoolEntriesKeepsOnlyNewestWhenPoolSizeOne() {
		// "Current only" is poolSize 1: keep just the newest (current) non-pinned wallpaper.
		let sorted = [url("a"), url("b"), url("c")]

		let result = WallpaperManager.poolEntries(sorted: sorted, pinnedIds: [], poolSize: 1)

		XCTAssertEqual(result, [url("a")])
	}

	func testPoolEntriesKeepsPinnedBeyondPoolSizeAndPreservesOrder() {
		// Newest-first, with two pinned entries past the non-pinned window.
		let sorted = [url("n1"), url("p1"), url("n2"), url("n3"), url("p2")]

		let result = WallpaperManager.poolEntries(sorted: sorted, pinnedIds: ["p1", "p2"], poolSize: 1)

		// Keeps the single newest non-pinned (n1) plus both pinned, in their original order.
		XCTAssertEqual(result, [url("n1"), url("p1"), url("p2")])
	}

	func testPoolEntriesKeepsPinnedWhenPoolSizeZero() {
		let sorted = [url("n1"), url("p1"), url("n2")]

		let result = WallpaperManager.poolEntries(sorted: sorted, pinnedIds: ["p1"], poolSize: 0)

		XCTAssertEqual(result, [url("p1")])
	}

	func testPoolEntriesEmptyWhenNothingPinnedAndPoolSizeZero() {
		let sorted = [url("n1"), url("n2")]

		let result = WallpaperManager.poolEntries(sorted: sorted, pinnedIds: [], poolSize: 0)

		XCTAssertTrue(result.isEmpty)
	}

	// MARK: - nextPinnedToRotate: cycle only the pinned set

	func testNextPinnedPicksOldestPinned() {
		// Pools are newest-first, so "oldest pinned" is the last pinned entry.
		let pool = [url("pNew"), url("nonPinned"), url("pOld")]

		let result = WallpaperManager.nextPinnedToRotate(pool: pool, pinnedIds: ["pNew", "pOld"], blockedIds: [])

		XCTAssertEqual(result, url("pOld"))
	}

	func testNextPinnedSkipsBlockedPinnedStraggler() {
		// The oldest pinned entry is also blocked, so the next-newest usable pinned one wins.
		let pool = [url("pUsable"), url("pBlocked")]

		let result = WallpaperManager.nextPinnedToRotate(pool: pool, pinnedIds: ["pUsable", "pBlocked"], blockedIds: ["pBlocked"])

		XCTAssertEqual(result, url("pUsable"))
	}

	func testNextPinnedIgnoresNonPinnedEntries() {
		let pool = [url("a"), url("pinned"), url("b")]

		let result = WallpaperManager.nextPinnedToRotate(pool: pool, pinnedIds: ["pinned"], blockedIds: [])

		XCTAssertEqual(result, url("pinned"))
	}

	func testNextPinnedReturnsNilWhenNoneArePinned() {
		let pool = [url("a"), url("b")]

		let result = WallpaperManager.nextPinnedToRotate(pool: pool, pinnedIds: [], blockedIds: [])

		XCTAssertNil(result)
	}

	// MARK: - pinAction: the menu-bar toggle decision (gated to gallery/pool members)

	func testPinActionUnavailableWhenNothingOnScreen() {
		let result = WallpaperManager.pinAction(currentIds: [], poolIds: ["a"], pinnedIds: ["a"])

		XCTAssertEqual(result, .unavailable)
	}

	func testPinActionUnavailableWhenCurrentNotInPool() {
		// The wallpaper on screen isn't in this instance's gallery (e.g. set by another instance), so it can't be pinned.
		let result = WallpaperManager.pinAction(currentIds: ["x"], poolIds: ["a"], pinnedIds: [])

		XCTAssertEqual(result, .unavailable)
	}

	func testPinActionPinsWhenSingleCurrentInPoolNotPinned() {
		let result = WallpaperManager.pinAction(currentIds: ["a"], poolIds: ["a"], pinnedIds: [])

		XCTAssertEqual(result, .pin)
	}

	func testPinActionUnpinsWhenSingleCurrentAlreadyPinned() {
		let result = WallpaperManager.pinAction(currentIds: ["a"], poolIds: ["a"], pinnedIds: ["a"])

		XCTAssertEqual(result, .unpin)
	}

	func testPinActionUnpinsOnlyWhenEveryInPoolCurrentIsPinned() {
		let result = WallpaperManager.pinAction(currentIds: ["a", "b"], poolIds: ["a", "b"], pinnedIds: ["a", "b"])

		XCTAssertEqual(result, .unpin)
	}

	func testPinActionPinsWhenInPoolCurrentsAreMixed() {
		// Both on-screen wallpapers are in the pool but only one is pinned, so the action pins the straggler too.
		let result = WallpaperManager.pinAction(currentIds: ["a", "b"], poolIds: ["a", "b"], pinnedIds: ["a"])

		XCTAssertEqual(result, .pin)
	}

	func testPinActionIgnoresOnScreenWallpapersNotInPool() {
		// "x" is on screen but not in the gallery; only the in-pool "a" counts, and it's unpinned, so the action pins.
		let result = WallpaperManager.pinAction(currentIds: ["a", "x"], poolIds: ["a"], pinnedIds: [])

		XCTAssertEqual(result, .pin)
	}

	func testPinActionUnpinsWhenOnlyInPoolCurrentIsPinnedAndOthersAreForeign() {
		// "x" (not in pool) is ignored; the only pinnable current "a" is already pinned, so the action unpins.
		let result = WallpaperManager.pinAction(currentIds: ["a", "x"], poolIds: ["a"], pinnedIds: ["a"])

		XCTAssertEqual(result, .unpin)
	}

	// MARK: - Persistence round-tripping through UserDefaults

	func testPinUnpinRoundTripsThroughUserDefaults() {
		let service = WallhavenService.shared
		let saved = UserDefaults.standard.string(forKey: "pinnedIds")
		defer { UserDefaults.standard.set(saved, forKey: "pinnedIds") }

		service.pinnedIds = []
		service.pin("abc123")
		service.pin("def456")

		XCTAssertEqual(service.pinnedIds, ["abc123", "def456"])

		// The raw string in UserDefaults is comma-joined and survives a fresh read.
		let raw = UserDefaults.standard.string(forKey: "pinnedIds")
		XCTAssertEqual(raw, "abc123,def456")

		service.unpin("abc123")
		XCTAssertEqual(service.pinnedIds, ["def456"])
		XCTAssertEqual(UserDefaults.standard.string(forKey: "pinnedIds"), "def456")
	}

	func testPinningSameIdTwiceIsIdempotent() {
		let service = WallhavenService.shared
		let saved = UserDefaults.standard.string(forKey: "pinnedIds")
		defer { UserDefaults.standard.set(saved, forKey: "pinnedIds") }

		service.pinnedIds = []
		service.pin("dupe")
		service.pin("dupe")

		XCTAssertEqual(service.pinnedIds, ["dupe"])
	}
}
