import XCTest
@testable import Wallhavend

@MainActor
final class PrefetchTests: XCTestCase {
	/// A pool URL whose filename stem is the wallhaven id (see `WallpaperManager.wallpaperId(for:)`).
	private func url(_ bucket: String, _ id: String) -> URL {
		URL(fileURLWithPath: "/tmp/\(bucket)/\(id).jpg")
	}

	// MARK: - bucketsNeedingFill: how many non-pinned each active bucket needs to reach poolSize

	func testNeedsFillToReachPoolSizeWhenBelowTarget() {
		let pools = ["16x9": [url("16x9", "a"), url("16x9", "b")]]

		let result = WallpaperManager.bucketsNeedingFill(
			poolsByBucket: pools, pinnedIds: [], poolSize: 5, activeBuckets: ["16x9"]
		)

		XCTAssertEqual(result, ["16x9": 3])
	}

	func testEmptyBucketNeedsFullPoolSize() {
		let result = WallpaperManager.bucketsNeedingFill(
			poolsByBucket: [:], pinnedIds: [], poolSize: 5, activeBuckets: ["16x9"]
		)

		XCTAssertEqual(result, ["16x9": 5])
	}

	func testBucketAtTargetIsOmitted() {
		let pools = ["16x9": [url("16x9", "a"), url("16x9", "b"), url("16x9", "c")]]

		let result = WallpaperManager.bucketsNeedingFill(
			poolsByBucket: pools, pinnedIds: [], poolSize: 3, activeBuckets: ["16x9"]
		)

		XCTAssertTrue(result.isEmpty)
	}

	func testBucketAboveTargetIsOmitted() {
		// More on disk than the target (e.g. poolSize was just lowered): nothing to fetch.
		let pools = ["16x9": [url("16x9", "a"), url("16x9", "b"), url("16x9", "c"), url("16x9", "d")]]

		let result = WallpaperManager.bucketsNeedingFill(
			poolsByBucket: pools, pinnedIds: [], poolSize: 2, activeBuckets: ["16x9"]
		)

		XCTAssertTrue(result.isEmpty)
	}

	func testPinnedDoNotCountTowardTarget() {
		// Pinned files are eviction-exempt extras, so a bucket full of pins still needs a full poolSize of non-pinned.
		let pools = ["16x9": [url("16x9", "p1"), url("16x9", "p2"), url("16x9", "n1")]]

		let result = WallpaperManager.bucketsNeedingFill(
			poolsByBucket: pools, pinnedIds: ["p1", "p2"], poolSize: 3, activeBuckets: ["16x9"]
		)

		// One non-pinned present (n1), target 3 → needs 2 more.
		XCTAssertEqual(result, ["16x9": 2])
	}

	func testInactiveBucketIsOmittedEvenWhenBelowTarget() {
		// A bucket with no screen attached right now shouldn't be filled; an active-but-absent bucket needs the full size.
		let pools = ["9x16": [url("9x16", "a")]]

		let result = WallpaperManager.bucketsNeedingFill(
			poolsByBucket: pools, pinnedIds: [], poolSize: 5, activeBuckets: ["16x9"]
		)

		XCTAssertEqual(result, ["16x9": 5])
	}

	func testPoolSizeOneYieldsNothing() {
		// poolSize 1 is "Current only" — no gallery worth pre-filling.
		let result = WallpaperManager.bucketsNeedingFill(
			poolsByBucket: [:], pinnedIds: [], poolSize: 1, activeBuckets: ["16x9"]
		)

		XCTAssertTrue(result.isEmpty)
	}

	func testPoolSizeZeroYieldsNothing() {
		// poolSize 0 is "apply and forget".
		let result = WallpaperManager.bucketsNeedingFill(
			poolsByBucket: [:], pinnedIds: [], poolSize: 0, activeBuckets: ["16x9"]
		)

		XCTAssertTrue(result.isEmpty)
	}

	func testMultipleActiveBucketsComputedIndependently() {
		let pools = [
			"16x9": [url("16x9", "a"), url("16x9", "b")],
			"21x9": [url("21x9", "x")]
		]

		let result = WallpaperManager.bucketsNeedingFill(
			poolsByBucket: pools, pinnedIds: [], poolSize: 4, activeBuckets: ["16x9", "21x9"]
		)

		XCTAssertEqual(result, ["16x9": 2, "21x9": 3])
	}
}
