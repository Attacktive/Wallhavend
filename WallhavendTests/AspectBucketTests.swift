import XCTest
import AppKit
@testable import Wallhavend

final class AspectBucketTests: XCTestCase {
	func testUltrawideSnaps() {
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 32.0 / 9.0), .ultrawide)
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 21.0 / 9.0), .ultrawide)
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 2.4), .ultrawide)
	}

	func testSixteenNineSnaps() {
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 16.0 / 9.0), .landscape16x9)
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 1.78), .landscape16x9)
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 1.70), .landscape16x9)
	}

	func testSixteenTenSnaps() {
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 16.0 / 10.0), .landscape16x10)
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 1.55), .landscape16x10)
	}

	func testFourThreeSnaps() {
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 4.0 / 3.0), .landscape4x3)
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 1.25), .landscape4x3)
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 1.0), .landscape4x3)
	}

	func testPortraitSnaps() {
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 9.0 / 16.0), .portrait)
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 0.75), .portrait)
		XCTAssertEqual(AspectBucket.snap(aspectRatio: 0.5), .portrait)
	}

	func testRawValuesMatchWallhavenRatioStrings() {
		XCTAssertEqual(AspectBucket.ultrawide.rawValue, "21x9")
		XCTAssertEqual(AspectBucket.landscape16x9.rawValue, "16x9")
		XCTAssertEqual(AspectBucket.landscape16x10.rawValue, "16x10")
		XCTAssertEqual(AspectBucket.landscape4x3.rawValue, "4x3")
		XCTAssertEqual(AspectBucket.portrait.rawValue, "9x16")
	}

	func testLabelsAreHumanReadable() {
		XCTAssertEqual(AspectBucket.ultrawide.label, "Ultrawide (21:9)")
		XCTAssertEqual(AspectBucket.landscape16x9.label, "Landscape (16:9)")
		XCTAssertEqual(AspectBucket.landscape16x10.label, "Landscape (16:10)")
		XCTAssertEqual(AspectBucket.landscape4x3.label, "Landscape (4:3)")
		XCTAssertEqual(AspectBucket.portrait.label, "Portrait (9:16)")
	}
}
