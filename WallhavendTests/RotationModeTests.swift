import XCTest
@testable import Wallhavend

@MainActor
final class RotationModeTests: XCTestCase {
	// MARK: - pinnedRotationPausedMessage: scheduled updates pause instead of downloading when Pinned only has nothing pinned

	func testPausedMessageWhenPinnedOnlyAndNothingPinned() {
		let result = WallpaperManager.pinnedRotationPausedMessage(mode: .pinnedOnly, pinnedIds: [])

		XCTAssertEqual(result, "Nothing is pinned — automatic updates are paused. Pin a wallpaper or switch to Fresh.")
	}

	func testNoPausedMessageWhenPinnedOnlyHasPins() {
		let result = WallpaperManager.pinnedRotationPausedMessage(mode: .pinnedOnly, pinnedIds: ["abc123"])

		XCTAssertNil(result)
	}

	func testNoPausedMessageInFreshModeEvenWithNothingPinned() {
		let result = WallpaperManager.pinnedRotationPausedMessage(mode: .fresh, pinnedIds: [])

		XCTAssertNil(result)
	}

	// MARK: - rotationCaption: the Advanced tab caption tracks the pinned-idle state

	func testCaptionExplainsBothModesWheneverPinsExist() {
		let expected = "Fresh downloads new wallpapers (and rotates your pool when offline). Pinned only never downloads — it cycles just your pinned wallpapers. “Update Now” always fetches a fresh one."

		XCTAssertEqual(AdvancedTab.rotationCaption(storedMode: .fresh, hasPins: true), expected)
		XCTAssertEqual(AdvancedTab.rotationCaption(storedMode: .pinnedOnly, hasPins: true), expected)
	}

	func testCaptionHintsToEnablePinnedOnlyWhenFreshWithNothingPinned() {
		let result = AdvancedTab.rotationCaption(storedMode: .fresh, hasPins: false)

		XCTAssertEqual(result, "Fresh downloads new wallpapers (and rotates your pool when offline). Pin a wallpaper to enable Pinned only.")
	}

	func testCaptionWarnsPausedWhenPinnedOnlyWithNothingPinned() {
		let result = AdvancedTab.rotationCaption(storedMode: .pinnedOnly, hasPins: false)

		XCTAssertEqual(result, "Pinned only never downloads, and nothing is pinned — automatic updates are paused. Pin a wallpaper or switch to Fresh. “Update Now” still fetches a fresh one.")
	}

	// MARK: - canUpdateNow: the manual fetch is gated on being online and on no update already holding the slot

	func testCanUpdateNowWhenOnlineAndIdle() {
		XCTAssertTrue(WallpaperManager.canUpdateNow(isOnline: true, isUpdating: false))
	}

	func testCannotUpdateNowWhileAnUpdateIsRunning() {
		XCTAssertFalse(WallpaperManager.canUpdateNow(isOnline: true, isUpdating: true))
	}

	func testCannotUpdateNowWhileOffline() {
		XCTAssertFalse(WallpaperManager.canUpdateNow(isOnline: false, isUpdating: false))
	}

	func testCannotUpdateNowWhileOfflineAndUpdating() {
		XCTAssertFalse(WallpaperManager.canUpdateNow(isOnline: false, isUpdating: true))
	}

	// MARK: - delayAfterTick: a tick that couldn't take the slot comes back soon instead of waiting out the interval

	func testHandledTickWaitsTheFullInterval() {
		XCTAssertEqual(WallpaperManager.delayAfterTick(outcome: .handled, interval: 3600), 3600)
	}

	func testDeferredTickRetriesLongBeforeTheNextInterval() {
		let result = WallpaperManager.delayAfterTick(outcome: .deferred, interval: 3600)

		XCTAssertEqual(result, WallpaperManager.deferredTickRetryInterval)
	}

	func testDeferredTickNeverWaitsLongerThanTheIntervalItself() {
		XCTAssertEqual(WallpaperManager.delayAfterTick(outcome: .deferred, interval: 10), 10)
	}
}
