import XCTest
@testable import Wallhavend

@MainActor
final class AutoReplaceOnBlockTests: XCTestCase {
	/// A pool URL whose filename stem is the wallhaven id (see `WallpaperManager.wallpaperId(for:)`).
	private func url(_ id: String) -> URL {
		URL(fileURLWithPath: "/tmp/16x9/\(id).jpg")
	}

	// Pools are stored newest-first, so "oldest remaining" is the last non-blocked entry.

	func testCurrentWithNonEmptyPoolAppliesOldestRemaining() {
		let action = WallpaperManager.replacementAction(
			wasCurrent: true,
			pool: [url("newest"), url("middle"), url("oldest")],
			blockedIds: ["blockedId"]
		)

		XCTAssertEqual(action, .applyFromPool(url("oldest")))
	}

	func testCurrentWithEmptyPoolFallsBackToFetch() {
		let action = WallpaperManager.replacementAction(
			wasCurrent: true,
			pool: [],
			blockedIds: ["blockedId"]
		)

		XCTAssertEqual(action, .fetch)
	}

	func testCurrentWithOnlyBlockedEntriesFallsBackToFetch() {
		// Defensive: a blocked straggler must never be applied — fall through to a fetch.
		let action = WallpaperManager.replacementAction(
			wasCurrent: true,
			pool: [url("blockedId")],
			blockedIds: ["blockedId"]
		)

		XCTAssertEqual(action, .fetch)
	}

	func testReplacementSkipsBlockedStragglerAndPicksNextOldest() {
		// The oldest entry (last) is blocked, so the next-oldest usable one wins.
		let action = WallpaperManager.replacementAction(
			wasCurrent: true,
			pool: [url("usable"), url("blockedId")],
			blockedIds: ["blockedId"]
		)

		XCTAssertEqual(action, .applyFromPool(url("usable")))
	}

	func testNonCurrentBlockReplacesNothing() {
		let action = WallpaperManager.replacementAction(
			wasCurrent: false,
			pool: [url("anything")],
			blockedIds: ["blockedId"]
		)

		XCTAssertEqual(action, .doNothing)
	}
}
