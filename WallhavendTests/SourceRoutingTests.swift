import XCTest
@testable import Wallhavend

/// The routing decisions that sit between "a bucket needs a wallpaper" and "some source produced one".
final class SourceRoutingTests: XCTestCase {
	// MARK: - sourceOrder: who gets asked, in what order

	func testWallhavenOnlyYieldsWallhaven() {
		XCTAssertEqual(
			WallpaperManager.sourceOrder(enabled: [.wallhaven], openverseCoolingDown: false),
			[.wallhaven]
		)
	}

	func testBothEnabledYieldsBothInSomeOrder() {
		let order = WallpaperManager.sourceOrder(enabled: [.wallhaven, .openverse], openverseCoolingDown: false)

		XCTAssertEqual(order.count, 2)
		XCTAssertEqual(Set(order), [.wallhaven, .openverse])
	}

	func testCoolingDownOpenverseIsSkipped() {
		// Asking a source that just rate-limited us only spends a request to hear the same answer.
		XCTAssertEqual(
			WallpaperManager.sourceOrder(enabled: [.wallhaven, .openverse], openverseCoolingDown: true),
			[.wallhaven]
		)
	}

	func testCoolingDownIrrelevantToWallhaven() {
		XCTAssertEqual(
			WallpaperManager.sourceOrder(enabled: [.wallhaven], openverseCoolingDown: true),
			[.wallhaven]
		)
	}

	func testOpenverseAloneAndCoolingDownLeavesNobodyToAsk() {
		// The router turns this empty order into a rate-limited error rather than a silent no-op — with one source there's nothing to fall through to.
		XCTAssertTrue(
			WallpaperManager.sourceOrder(enabled: [.openverse], openverseCoolingDown: true).isEmpty
		)
	}

	// MARK: - mostInformative: which failure is worth showing

	func testRealErrorBeatsNoResults() {
		let picked = WallpaperManager.mostInformative([WallpaperError.noResults, WallpaperError.httpError(503)])

		XCTAssertEqual(picked as? WallpaperError, .httpError(503))
	}

	func testRealErrorWinsEvenWhenItComesSecond() {
		let picked = WallpaperManager.mostInformative([WallpaperError.noResults, WallpaperError.rateLimited])

		XCTAssertEqual(picked as? WallpaperError, .rateLimited)
	}

	func testAllNoResultsStaysNoResults() {
		let picked = WallpaperManager.mostInformative([WallpaperError.noResults, WallpaperError.noResults])

		XCTAssertEqual(picked as? WallpaperError, .noResults)
	}

	func testNoFailuresAtAllStillProducesAnError() {
		// Only reachable if the order was non-empty but nothing ran; the caller still needs something to throw.
		XCTAssertEqual(WallpaperManager.mostInformative([]) as? WallpaperError, .noResults)
	}

	func testForeignErrorsCountAsInformative() {
		let picked = WallpaperManager.mostInformative([WallpaperError.noResults, URLError(.timedOut)])

		XCTAssertEqual(picked as? URLError, URLError(.timedOut))
	}

	// MARK: - enabledSources persistence

	func testEncodeIsSortedAndCommaJoined() {
		XCTAssertEqual(WallpaperManager.encodeSources([.openverse, .wallhaven]), "openverse,wallhaven")
		XCTAssertEqual(WallpaperManager.encodeSources([.wallhaven]), "wallhaven")
	}

	func testRoundTripsThroughStorage() {
		for sources in [Set<WallpaperSource>([.wallhaven]), [.openverse], [.wallhaven, .openverse]] {
			XCTAssertEqual(WallpaperManager.decodeSources(WallpaperManager.encodeSources(sources)), sources)
		}
	}

	func testUnwrittenSettingFallsBackToWallhaven() {
		// A fresh install has nothing stored, and it must behave exactly as it did before sources existed.
		XCTAssertEqual(WallpaperManager.decodeSources(nil), [.wallhaven])
	}

	func testUnusableStoredValuesFallBackToWallhaven() {
		// Everything downstream assumes at least one source is enabled, so an empty or garbled set can't be taken at face value.
		XCTAssertEqual(WallpaperManager.decodeSources(""), [.wallhaven])
		XCTAssertEqual(WallpaperManager.decodeSources("flickr,unsplash"), [.wallhaven])
	}

	func testUnknownKeysAreDroppedButKnownOnesSurvive() {
		XCTAssertEqual(WallpaperManager.decodeSources("openverse,pexels"), [.openverse])
	}
}
