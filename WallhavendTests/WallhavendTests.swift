import XCTest
@testable import Wallhavend

@MainActor
final class WallhavendTests: XCTestCase {
	var service: WallhavenService!

	override func setUpWithError() throws {
		service = WallhavenService.shared
	}

	override func tearDownWithError() throws {
		service = nil
	}

	func testCategoryBitString() async throws {
		// Test with no categories
		service.selectedCategories = []
		let wallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertNotNil(wallpaper)

		// Test with general category
		service.selectedCategories = [.general]
		let generalWallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertNotNil(generalWallpaper)

		// Test with anime category
		service.selectedCategories = [.anime]
		let animeWallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertNotNil(animeWallpaper)

		// Test with people category
		service.selectedCategories = [.people]
		let peopleWallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertNotNil(peopleWallpaper)

		// Test with multiple categories
		service.selectedCategories = [.general, .anime]
		let multipleWallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertNotNil(multipleWallpaper)

		// Test with all categories
		service.selectedCategories = [.general, .anime, .people]
		let allWallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertNotNil(allWallpaper)
	}

	func testPurityString() throws {
		// Test with no purity options
		service.includeSFW = false
		service.includeSketchy = false
		service.includeNSFW = false
		XCTAssertEqual(service.purityString, "000")

		// Test with SFW only
		service.includeSFW = true
		service.includeSketchy = false
		service.includeNSFW = false
		XCTAssertEqual(service.purityString, "100")

		// Test with Sketchy only
		service.includeSFW = false
		service.includeSketchy = true
		service.includeNSFW = false
		XCTAssertEqual(service.purityString, "010")

		// Test with NSFW only
		service.includeSFW = false
		service.includeSketchy = false
		service.includeNSFW = true
		XCTAssertEqual(service.purityString, "001")

		// Test with multiple options
		service.includeSFW = true
		service.includeSketchy = true
		service.includeNSFW = false
		XCTAssertEqual(service.purityString, "110")

		// Test with all options
		service.includeSFW = true
		service.includeSketchy = true
		service.includeNSFW = true
		XCTAssertEqual(service.purityString, "111")
	}

	func testCategories() async throws {
		// Test with general category
		service.selectedCategories = [.general]
		let generalWallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertEqual(generalWallpaper.category, "general")

		// Test with anime category
		service.selectedCategories = [.anime]
		let animeWallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertEqual(animeWallpaper.category, "anime")

		// Test with people category
		service.selectedCategories = [.people]
		let peopleWallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertEqual(peopleWallpaper.category, "people")
	}

	func testSearchQueryEncoding() async throws {
		service.searchQuery = "mountain landscape"

		let wallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertNotNil(wallpaper)
	}

	func testFetchRandomWallpaper() async throws {
		let wallpaper = try await service.fetchRandomWallpaper(ratios: "16x9", atleast: "1920x1080")
		XCTAssertNotNil(wallpaper)
		XCTAssertFalse(wallpaper.path.isEmpty)
		XCTAssertFalse(wallpaper.url.isEmpty)
	}
}
