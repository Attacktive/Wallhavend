import XCTest
@testable import Wallhavend

final class WallpaperIdentityTests: XCTestCase {
	// MARK: - parse

	func testBareStemIsWallhaven() {
		let identity = WallpaperIdentity.parse(stem: "abc123")

		XCTAssertEqual(identity.source, .wallhaven)
		XCTAssertEqual(identity.id, "abc123")
	}

	func testOpenversePrefixIsStripped() {
		let identity = WallpaperIdentity.parse(stem: "openverse_3f2b1a9c-0000-4000-8000-abcdefabcdef")

		XCTAssertEqual(identity.source, .openverse)
		XCTAssertEqual(identity.id, "3f2b1a9c-0000-4000-8000-abcdefabcdef")
	}

	/// A prefix with nothing after it is not an identity — keep the stem whole rather than inventing an empty id.
	func testOpenversePrefixWithEmptyTailFallsBackToWallhaven() {
		let identity = WallpaperIdentity.parse(stem: "openverse_")

		XCTAssertEqual(identity.source, .wallhaven)
		XCTAssertEqual(identity.id, "openverse_")
	}

	/// Wallhaven files are bare forever, so a literal `wallhaven_` prefix is part of the id, not a qualifier.
	func testWallhavenPrefixIsNotTreatedAsAQualifier() {
		let identity = WallpaperIdentity.parse(stem: "wallhaven_x")

		XCTAssertEqual(identity.source, .wallhaven)
		XCTAssertEqual(identity.id, "wallhaven_x")
	}

	func testUnknownPrefixFallsBackToWallhaven() {
		let identity = WallpaperIdentity.parse(stem: "unsplash_abc")

		XCTAssertEqual(identity.source, .wallhaven)
		XCTAssertEqual(identity.id, "unsplash_abc")
	}

	// MARK: - qualifiedStem round-trips

	func testWallhavenStemStaysBare() {
		let identity = WallpaperIdentity(source: .wallhaven, id: "abc123")

		XCTAssertEqual(identity.qualifiedStem, "abc123")
		XCTAssertEqual(WallpaperIdentity.parse(stem: identity.qualifiedStem), identity)
	}

	func testOpenverseStemIsQualified() {
		let identity = WallpaperIdentity(source: .openverse, id: "3f2b1a9c")

		XCTAssertEqual(identity.qualifiedStem, "openverse_3f2b1a9c")
		XCTAssertEqual(WallpaperIdentity.parse(stem: identity.qualifiedStem), identity)
	}

	// MARK: - URLs

	func testWallhavenURLs() {
		let identity = WallpaperIdentity(source: .wallhaven, id: "abc123")

		XCTAssertEqual(identity.pageURL?.absoluteString, "https://wallhaven.cc/w/abc123")
		XCTAssertEqual(identity.thumbnailURL?.absoluteString, "https://th.wallhaven.cc/lg/ab/abc123.jpg")
	}

	func testOpenverseURLs() {
		let identity = WallpaperIdentity(source: .openverse, id: "3f2b1a9c")

		XCTAssertEqual(identity.pageURL?.absoluteString, "https://openverse.org/image/3f2b1a9c")
		XCTAssertEqual(identity.thumbnailURL?.absoluteString, "https://api.openverse.org/v1/images/3f2b1a9c/thumb/")
	}

	/// The thumbnail path is sharded by the id's first two characters, so a one-character id has no thumbnail — but it still has a page.
	func testShortWallhavenIdHasNoThumbnailButStillHasAPage() {
		let identity = WallpaperIdentity(source: .wallhaven, id: "a")

		XCTAssertNil(identity.thumbnailURL)
		XCTAssertEqual(identity.pageURL?.absoluteString, "https://wallhaven.cc/w/a")
	}

	// MARK: - Source keys

	/// Raw values are persisted in filename stems, so they are part of the on-disk format.
	func testRawValuesAreThePersistedKeys() {
		XCTAssertEqual(WallpaperSource.wallhaven.rawValue, "wallhaven")
		XCTAssertEqual(WallpaperSource.openverse.rawValue, "openverse")
	}

	func testDisplayNamesAreHumanReadable() {
		XCTAssertEqual(WallpaperSource.wallhaven.displayName, "Wallhaven")
		XCTAssertEqual(WallpaperSource.openverse.displayName, "Openverse")
	}
}
