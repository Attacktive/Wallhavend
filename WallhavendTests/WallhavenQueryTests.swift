import XCTest
@testable import Wallhavend

/// The decisions behind a Wallhaven query: where in a result list the next fetch lands, and what the color filter will accept.
/// None of it touches the network — the paging arithmetic is exactly the part that was silently wrong before, and it is knowable without asking Wallhaven anything.
final class WallhavenQueryTests: XCTestCase {
	typealias PageCursor = WallhavenService.PageCursor

	// MARK: - pageToFetch: random re-seeds, everything else walks

	func testRandomAlwaysTakesTheFirstPage() {
		// A fresh seed makes page 1 a fresh sample, and walking pages would bias it toward the front of a random ordering.
		let deep = PageCursor(next: 30, last: 100)

		XCTAssertEqual(WallhavenService.pageToFetch(sorting: .random, cursor: deep), 1)
	}

	func testDeterministicSortingResumesWhereItLeftOff() {
		let cursor = PageCursor(next: 7, last: 49)

		XCTAssertEqual(WallhavenService.pageToFetch(sorting: .toplist, cursor: cursor), 7)
		XCTAssertEqual(WallhavenService.pageToFetch(sorting: .dateAdded, cursor: cursor), 7)
		XCTAssertEqual(WallhavenService.pageToFetch(sorting: .views, cursor: cursor), 7)
		XCTAssertEqual(WallhavenService.pageToFetch(sorting: .favorites, cursor: cursor), 7)
	}

	func testWrapsBackToTheFirstPageAtTheEndOfTheList() {
		// A short list has to keep cycling; asking for page 6 of 5 returns nothing forever.
		let exhausted = PageCursor(next: 6, last: 5)

		XCTAssertEqual(WallhavenService.pageToFetch(sorting: .views, cursor: exhausted), 1)
	}

	func testTheLastPageItselfIsStillFetched() {
		let onTheLastPage = PageCursor(next: 5, last: 5)

		XCTAssertEqual(WallhavenService.pageToFetch(sorting: .views, cursor: onTheLastPage), 5)
	}

	func testAFreshCursorStartsAtTheFirstPage() {
		XCTAssertEqual(WallhavenService.pageToFetch(sorting: .views, cursor: PageCursor()), 1)
	}

	// MARK: - claiming: taking a page before the request goes out

	func testClaimingMovesPastThePageTaken() {
		let claimed = WallhavenService.claiming(PageCursor(), page: 3)

		XCTAssertEqual(claimed.next, 4)
	}

	func testClaimingLearnsNothingAboutDepth() {
		// It happens before any response, so the known depth has to carry over untouched.
		let claimed = WallhavenService.claiming(PageCursor(next: 4, last: 49), page: 4)

		XCTAssertEqual(claimed.last, 49)
	}

	func testTwoFetchesInFlightAtOnceTakeDifferentPages() {
		/*
			An update tick and a pool fill can work the same bucket simultaneously, and they share a cache key.
			Whichever claims second must not be handed the page the first is still downloading.
		*/
		let start = PageCursor(next: 1, last: 49)

		let first = WallhavenService.pageToFetch(sorting: .views, cursor: start)
		let afterFirstClaim = WallhavenService.claiming(start, page: first)
		let second = WallhavenService.pageToFetch(sorting: .views, cursor: afterFirstClaim)

		XCTAssertEqual(first, 1)
		XCTAssertEqual(second, 2)
	}

	// MARK: - learning: what the responses teach the cursor

	func testTheDeepestKeywordSetsTheDepth() {
		/*
			Keywords have wildly different result counts.
			Taking the shallowest — or whichever response happened to arrive last — would wrap the cursor before the deep list had been walked.
		*/
		let learned = WallhavenService.learning(PageCursor(next: 2, last: 1), lastPages: [3, 100, 12])

		XCTAssertEqual(learned.last, 100)
	}

	func testLearningNothingKeepsTheKnownDepth() {
		let learned = WallhavenService.learning(PageCursor(next: 5, last: 49), lastPages: [])

		XCTAssertEqual(learned.last, 49)
	}

	func testAResponseNeverUndoesALaterClaim() {
		/*
			The first of two concurrent fetches can finish after the second has already claimed its page.
			Reporting its depth must leave the position where the second put it, or that page gets handed out twice.
		*/
		let afterTheSecondClaim = PageCursor(next: 3, last: 1)

		let learned = WallhavenService.learning(afterTheSecondClaim, lastPages: [49])

		XCTAssertEqual(learned.next, 3)
		XCTAssertEqual(learned.last, 49)
	}

	// MARK: - Persisted raw values

	func testSortingRawValuesAreWallhavensOwn() {
		// These are both the API's `sorting` values and what lands in UserDefaults, so a change here silently resets everyone's choice.
		XCTAssertEqual(WallhavenSorting.allCases.map { $0.rawValue }, ["random", "date_added", "views", "favorites", "toplist"])
	}

	func testToplistRangeRawValuesAreWallhavensOwn() {
		// Case matters: `M` is months, and Wallhaven reads a lowercase `m` as minutes.
		XCTAssertEqual(WallhavenToplistRange.allCases.map { $0.rawValue }, ["1d", "3d", "1w", "1M", "3M", "6M", "1y"])
	}

	func testUnknownStoredValuesFallBackRatherThanFailing() {
		XCTAssertNil(WallhavenSorting(rawValue: "dateAdded"))
		XCTAssertNil(WallhavenToplistRange(rawValue: "1m"))
	}

	// MARK: - WallhavenColor: the palette is the validation

	func testTogglingAddsAndRemoves() {
		let added = WallhavenColor.toggled("cc0000", in: "")
		XCTAssertEqual(added, "cc0000")

		XCTAssertEqual(WallhavenColor.toggled("cc0000", in: added), "")
	}

	func testSelectionsAreSortedSoTheSameSetIsAlwaysTheSameString() {
		// An unstable ordering would look like a settings change on every re-render and wipe the wallpaper cache each time.
		XCTAssertEqual(WallhavenColor.toggled("000000", in: "ffffff"), "000000,ffffff")
		XCTAssertEqual(WallhavenColor.toggled("ffffff", in: "000000"), "000000,ffffff")
	}

	func testTogglingLeavesTheOtherSelectionsAlone() {
		XCTAssertEqual(WallhavenColor.toggled("0066cc", in: "000000,ffffff"), "000000,0066cc,ffffff")
	}

	func testSanitizingStripsWhatWallhavenWouldNotMatch() {
		// Wallhaven is case-sensitive and wants no `#`: `colors=CC0000` returns nothing at all.
		XCTAssertEqual(WallhavenColor.sanitized("#CC0000"), "cc0000")
		XCTAssertEqual(WallhavenColor.sanitized(" 00 00 00 "), "000000")
		XCTAssertEqual(WallhavenColor.sanitized("gg0000"), "0000")
		XCTAssertEqual(WallhavenColor.sanitized("#000000, #ffffff"), "000000,ffffff")
	}

	func testEveryPaletteEntryIsAWellFormedLowercaseHex() {
		XCTAssertEqual(WallhavenColor.palette.count, 29)

		for hex in WallhavenColor.palette {
			XCTAssertEqual(WallhavenColor.sanitized(hex), hex, "\(hex) would be altered before it reached Wallhaven")
			XCTAssertNotNil(WallhavenColor.channels(hex), "\(hex) has no renderable swatch")
		}
	}

	func testChannelsRejectsAnythingThatIsNotSixDigits() {
		XCTAssertNil(WallhavenColor.channels("fff"))
		XCTAssertNil(WallhavenColor.channels(""))
		XCTAssertNil(WallhavenColor.channels("gggggg"))
	}

	func testChannelsSplitTheHexIntoTheRightOrder() throws {
		// Three distinct channels, so a transposed pair can't slip through the way it would with a pure red.
		let blue = try XCTUnwrap(WallhavenColor.channels("0066cc"))

		XCTAssertEqual(blue.red, 0, accuracy: 0.001)
		XCTAssertEqual(blue.green, 0.4, accuracy: 0.001)
		XCTAssertEqual(blue.blue, 0.8, accuracy: 0.001)
	}

	// MARK: - The size floor, which is off entirely when "Avoid blurry wallpapers" is

	func testNoFloorAdmitsAnyDimensions() {
		let floor = OpenverseService.floor(atleast: nil)

		XCTAssertEqual(floor?.width, 0)
		XCTAssertEqual(floor?.height, 0)
	}

	func testAFloorIsTheScreensOwnPixels() {
		let floor = OpenverseService.floor(atleast: "3024x1964")

		XCTAssertEqual(floor?.width, 3024)
		XCTAssertEqual(floor?.height, 1964)
	}

	func testAnUnparseableFloorIsABrokenContractRatherThanNoFloor() {
		XCTAssertNil(OpenverseService.floor(atleast: "wide"))
	}
}
