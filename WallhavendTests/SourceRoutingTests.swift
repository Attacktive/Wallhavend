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

	// MARK: - toggleKeepingOne: the only sets the UI is allowed to write

	func testTogglingAnAbsentSourceAddsIt() {
		XCTAssertEqual(
			WallpaperSource.toggleKeepingOne(.openverse, in: [.wallhaven]),
			[.wallhaven, .openverse]
		)
	}

	func testTogglingOneOfTwoRemovesIt() {
		XCTAssertEqual(
			WallpaperSource.toggleKeepingOne(.wallhaven, in: [.wallhaven, .openverse]),
			[.openverse]
		)
	}

	func testTheLastSourceCannotBeTurnedOff() {
		// An empty set would leave every tick quietly doing nothing, which from the outside is indistinguishable from a broken app.
		for source in WallpaperSource.allCases {
			XCTAssertEqual(WallpaperSource.toggleKeepingOne(source, in: [source]), [source])
		}
	}

	func testTogglingStaysReversibleWhileTwoRemain() {
		let both: Set<WallpaperSource> = [.wallhaven, .openverse]
		let reduced = WallpaperSource.toggleKeepingOne(.openverse, in: both)

		XCTAssertEqual(WallpaperSource.toggleKeepingOne(.openverse, in: reduced), both)
	}

	// MARK: - contentRatingCaption: which toggles the enabled sources actually read

	func testNoCaptionWithoutOpenverse() {
		// A Wallhaven-only install has to see exactly the screen it saw before sources existed.
		XCTAssertNil(ContentTab.contentRatingCaption(enabled: [.wallhaven]))
	}

	func testCaptionSplitsTheTogglesWhenBothAreEnabled() {
		let caption = ContentTab.contentRatingCaption(enabled: [.wallhaven, .openverse])

		XCTAssertEqual(caption, "Wallhaven honors all three. Openverse reads only NSFW, which lets mature results through.")
	}

	func testCaptionNamesTheInertTogglesWhenOpenverseIsAlone() {
		// SFW and Sketchy still render, and with Wallhaven off they do nothing — saying so is the whole point of the caption.
		let caption = ContentTab.contentRatingCaption(enabled: [.openverse])

		XCTAssertEqual(caption, "Openverse reads only NSFW, which lets mature results through — SFW and Sketchy apply to Wallhaven alone.")
	}

	// MARK: - source credits

	func testEverySourceHasACreditAndSomewhereToLinkIt() {
		for source in WallpaperSource.allCases {
			XCTAssertFalse(source.attribution.isEmpty, "\(source.rawValue) has no credit line")
			XCTAssertNotNil(source.homeURL, "\(source.rawValue) has no home URL")
		}
	}

	func testOpenverseCreditCarriesTheWordingItsTermsRequire() {
		// Openverse asks to be credited with a disclaimer of endorsement; paraphrasing it would break the terms its wallpapers arrive under.
		XCTAssertEqual(
			WallpaperSource.openverse.attribution,
			"Made using Openverse — not endorsed or certified by Openverse"
		)
	}
}
