import XCTest
@testable import Wallhavend

/// The pure mapping layer between our buckets and Openverse's query vocabulary.
/// Nothing here touches the network: the request-shaping decisions are the part worth pinning down, and Openverse is a shared community API that CI's three-OS matrix has no business hammering on every push.
final class OpenverseMappingTests: XCTestCase {
	// MARK: - aspectParameter: five buckets onto Openverse's coarser filter

	func testPortraitAsksForTall() {
		XCTAssertEqual(OpenverseService.aspectParameter(for: .portrait), "tall")
	}

	func testEveryLandscapeBucketSharesWide() {
		XCTAssertEqual(OpenverseService.aspectParameter(for: .ultrawide), "wide")
		XCTAssertEqual(OpenverseService.aspectParameter(for: .landscape16x9), "wide")
		XCTAssertEqual(OpenverseService.aspectParameter(for: .landscape16x10), "wide")
		XCTAssertEqual(OpenverseService.aspectParameter(for: .landscape4x3), "wide")
	}

	func testSquareIsNeverRequested() {
		// No screen snaps to square, so asking for it would only spend requests on results nothing can use.
		for bucket in AspectBucket.allCases {
			XCTAssertNotEqual(OpenverseService.aspectParameter(for: bucket), "square")
		}
	}

	// MARK: - admits: the client-side gate that `wide` and `size=large` are too coarse to be

	func testAdmitsWhenBucketAndSizeBothMatch() {
		XCTAssertTrue(
			OpenverseService.admits(width: 3840, height: 2400, minimumWidth: 3024, minimumHeight: 1964, bucket: .landscape16x10)
		)
	}

	func testRejectsRightSizeButWrongBucket() {
		// 3840x2160 is comfortably large enough, but it snaps to 16x9 — filed under 16x10 it would letterbox.
		XCTAssertFalse(
			OpenverseService.admits(width: 3840, height: 2160, minimumWidth: 3024, minimumHeight: 1964, bucket: .landscape16x10)
		)
	}

	func testRejectsRightBucketButTooSmall() {
		XCTAssertFalse(
			OpenverseService.admits(width: 2560, height: 1600, minimumWidth: 3024, minimumHeight: 1964, bucket: .landscape16x10)
		)
	}

	func testRejectsWhenOnlyOneDimensionClears() {
		XCTAssertFalse(
			OpenverseService.admits(width: 4000, height: 1200, minimumWidth: 1920, minimumHeight: 1080, bucket: .landscape16x9)
		)
	}

	func testRejectsMissingDimensions() {
		// A result that never reported its size can't prove it qualifies.
		XCTAssertFalse(
			OpenverseService.admits(width: nil, height: 2160, minimumWidth: 1920, minimumHeight: 1080, bucket: .landscape16x9)
		)

		XCTAssertFalse(
			OpenverseService.admits(width: 3840, height: nil, minimumWidth: 1920, minimumHeight: 1080, bucket: .landscape16x9)
		)
	}

	func testRejectsZeroDimensions() {
		XCTAssertFalse(
			OpenverseService.admits(width: 0, height: 0, minimumWidth: 0, minimumHeight: 0, bucket: .landscape16x9)
		)
	}

	func testAdmitsPortrait() {
		XCTAssertTrue(
			OpenverseService.admits(width: 2160, height: 3840, minimumWidth: 1080, minimumHeight: 1920, bucket: .portrait)
		)
	}

	// MARK: - pageRange: where in a result window a fetch may land

	func testFirstFetchOfAWindowMustBePageOne() {
		// Nothing yet says how deep the window goes, so page 1 is the only page known to exist.
		XCTAssertEqual(OpenverseService.pageRange(knownPageCount: nil), 1...1)
	}

	func testKnownPageCountOpensTheWholeWindow() {
		XCTAssertEqual(OpenverseService.pageRange(knownPageCount: 12), 1...12)
		XCTAssertEqual(OpenverseService.pageRange(knownPageCount: 5), 1...5)
	}

	func testDeeperWindowsAreCappedAtTheAnonymousCeiling() {
		// Anonymous access reaches 240 results at 20 per page, whatever the response claims.
		XCTAssertEqual(OpenverseService.pageRange(knownPageCount: 30), 1...12)
	}

	func testEmptyWindowStillYieldsAValidRange() {
		XCTAssertEqual(OpenverseService.pageRange(knownPageCount: 0), 1...1)
	}

	// MARK: - license tiers

	func testApiValuesAreExact() {
		XCTAssertEqual(OpenverseLicenseFilter.publicDomain.apiValue, "cc0,pdm")
		XCTAssertEqual(OpenverseLicenseFilter.permissive.apiValue, "cc0,pdm,by")
		XCTAssertEqual(OpenverseLicenseFilter.anyCommercial.apiValue, "cc0,pdm,by,by-sa,by-nd")
	}

	func testTiersAreStrictlyNested() {
		// Widening the filter must only ever add licenses. If a tier ever swapped one out, a user widening their choice would silently lose results they already had.
		let tiers = OpenverseLicenseFilter.allCases.map { Set($0.apiValue.split(separator: ",")) }

		for (narrower, wider) in zip(tiers, tiers.dropFirst()) {
			XCTAssertTrue(narrower.isStrictSubset(of: wider))
		}
	}

	func testDefaultTierCarriesNoAttributionObligation() {
		XCTAssertEqual(OpenverseLicenseFilter.allCases.first, .publicDomain)
	}

	// MARK: - the curated source list

	func testCuratedSourcesExcludeSpacex() {
		// Measured 2026-08-22: spacex returns nothing under any filter combination, including none at all.
		XCTAssertFalse(OpenverseService.curatedSources.contains("spacex"))
	}

	func testCuratedSourcesAreTheOnesWorthAsking() {
		XCTAssertEqual(OpenverseService.curatedSources, ["flickr", "wikimedia", "nasa", "rawpixel", "stocksnap"])
	}
}
