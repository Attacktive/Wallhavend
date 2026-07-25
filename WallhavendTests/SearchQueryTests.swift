import XCTest
@testable import Wallhavend

final class SearchQueryTests: XCTestCase {
	func testEmptyAndWhitespaceYieldNoKeywords() {
		XCTAssertEqual(WallhavenService.keywords(from: ""), [])
		XCTAssertEqual(WallhavenService.keywords(from: "   "), [])
		XCTAssertEqual(WallhavenService.keywords(from: "\n\t"), [])
	}

	func testSingleKeyword() {
		XCTAssertEqual(WallhavenService.keywords(from: "mountain"), ["mountain"])
	}

	func testSpacesAreNotDelimiters() {
		XCTAssertEqual(WallhavenService.keywords(from: "mountain landscape"), ["mountain landscape"])
	}

	func testWallhavenAndSyntaxIsPreserved() {
		XCTAssertEqual(WallhavenService.keywords(from: "+nature +city"), ["+nature +city"])
	}

	func testCommaSemicolonAndPipeDelimit() {
		XCTAssertEqual(WallhavenService.keywords(from: "mountain, landscape"), ["mountain", "landscape"])
		XCTAssertEqual(WallhavenService.keywords(from: "mountain; landscape"), ["mountain", "landscape"])
		XCTAssertEqual(WallhavenService.keywords(from: "mountain| landscape"), ["mountain", "landscape"])
	}

	func testTrimsAroundDelimiters() {
		XCTAssertEqual(WallhavenService.keywords(from: " mountain , landscape "), ["mountain", "landscape"])
	}

	func testEmptyPartsAreDropped() {
		XCTAssertEqual(WallhavenService.keywords(from: "a,,b"), ["a", "b"])
		XCTAssertEqual(WallhavenService.keywords(from: ",,,"), [])
	}

	func testMixedDelimiters() {
		XCTAssertEqual(WallhavenService.keywords(from: "a,b;c|d"), ["a", "b", "c", "d"])
	}
}
