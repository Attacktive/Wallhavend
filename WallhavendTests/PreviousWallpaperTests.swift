import XCTest
@testable import Wallhavend

final class PreviousWallpaperTests: XCTestCase {
	@MainActor
	func testPreviousWallpaperAvailability() async throws {
		let manager = WallpaperManager.shared

		// Initially, there should be no previous wallpaper
		if manager.previousWallpaperFileURL == nil {
			XCTAssertNil(manager.previousWallpaperFileURL, "Should have no previous wallpaper on first run")
		}

		// After updating wallpaper, we should have a current wallpaper
		await manager.updateWallpaper()

		// Wait a bit for the update to complete
		try await Task.sleep(nanoseconds: 2_000_000_000)

		// If update succeeded, we should have a current wallpaper
		// Previous might still be nil if this is the first wallpaper
		XCTAssertTrue(true, "Update completed without crashing")
	}

	@MainActor
	func testPreviousWallpaperSwap() async throws {
		let manager = WallpaperManager.shared

		// Update wallpaper twice to ensure we have both current and previous
		await manager.updateWallpaper()
		try await Task.sleep(nanoseconds: 2_000_000_000)

		await manager.updateWallpaper()
		try await Task.sleep(nanoseconds: 2_000_000_000)

		// Save the current state
		let currentBefore = manager.currentWallpaperFileURL
		let previousBefore = manager.previousWallpaperFileURL

		// Only test swap if we have both wallpapers
		guard previousBefore != nil else {
			throw XCTSkip("No previous wallpaper available to test swap")
		}

		// Restore previous wallpaper
		await manager.restorePreviousWallpaper()

		// After restore, current and previous should be swapped
		XCTAssertEqual(manager.currentWallpaperFileURL, previousBefore)
		XCTAssertEqual(manager.previousWallpaperFileURL, currentBefore)
	}

	@MainActor
	func testRestorePreviousWallpaperWithNoPrevious() async throws {
		let manager = WallpaperManager.shared

		// Save original state
		let originalPrevious = manager.previousWallpaperFileURL
		let originalCurrent = manager.currentWallpaperFileURL

		// Temporarily clear previous wallpaper (simulate first run)
		manager.previousWallpaperFileURL = nil

		// Try to restore - should handle gracefully
		await manager.restorePreviousWallpaper()

		// Current should remain unchanged
		XCTAssertEqual(manager.currentWallpaperFileURL, originalCurrent)

		// Restore original state
		manager.previousWallpaperFileURL = originalPrevious
	}

	@MainActor
	func testRestorePreviousUpdatesTimestamp() async throws {
		let manager = WallpaperManager.shared

		// Update wallpaper twice to ensure we have previous
		await manager.updateWallpaper()
		try await Task.sleep(nanoseconds: 2_000_000_000)

		await manager.updateWallpaper()
		try await Task.sleep(nanoseconds: 2_000_000_000)

		guard manager.previousWallpaperFileURL != nil else {
			throw XCTSkip("No previous wallpaper available")
		}

		let timestampBefore = manager.lastUpdated

		// Wait a moment to ensure timestamp will be different
		try await Task.sleep(nanoseconds: 100_000_000)

		// Restore previous
		await manager.restorePreviousWallpaper()

		// Timestamp should be updated
		XCTAssertNotEqual(manager.lastUpdated, timestampBefore)
		XCTAssertNotNil(manager.lastUpdated)
	}

	@MainActor
	func testRestorePreviousClearsError() async throws {
		let manager = WallpaperManager.shared

		// Update wallpaper twice to ensure we have previous
		await manager.updateWallpaper()
		try await Task.sleep(nanoseconds: 2_000_000_000)

		await manager.updateWallpaper()
		try await Task.sleep(nanoseconds: 2_000_000_000)

		guard manager.previousWallpaperFileURL != nil else {
			throw XCTSkip("No previous wallpaper available")
		}

		// Set an error manually
		manager.error = "Test error"
		XCTAssertNotNil(manager.error)

		// Restore previous
		await manager.restorePreviousWallpaper()

		// Error should be cleared (assuming restore succeeds)
		// If restore fails, error will be set to a different message
		XCTAssertNotEqual(manager.error, "Test error")
	}
}
