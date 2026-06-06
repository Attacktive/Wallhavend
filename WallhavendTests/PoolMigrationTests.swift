import XCTest
import AppKit
import ImageIO
@testable import Wallhavend

final class PoolMigrationTests: XCTestCase {
	private func writePNG(width: Int, height: Int, to url: URL) throws {
		guard let rep = NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: width,
			pixelsHigh: height,
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		) else {
			throw XCTSkip("Could not create bitmap rep")
		}

		guard let data = rep.representation(using: .png, properties: [:]) else {
			throw XCTSkip("Could not encode PNG")
		}

		try data.write(to: url)
	}

	func testMigratesFlatSixteenNineFile() throws {
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wallhavend-mig-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tmp) }

		let flat = tmp.appendingPathComponent("abc123.png")
		try writePNG(width: 1600, height: 900, to: flat)

		let moved = WallpaperManager.migrateFlatFilesToBuckets(in: tmp)
		XCTAssertEqual(moved, 1)

		let dest = tmp.appendingPathComponent("16x9").appendingPathComponent("abc123.png")
		XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: flat.path))
	}

	func testMigratesFlatPortraitFile() throws {
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wallhavend-mig-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tmp) }

		let flat = tmp.appendingPathComponent("def456.png")
		try writePNG(width: 900, height: 1600, to: flat)

		_ = WallpaperManager.migrateFlatFilesToBuckets(in: tmp)

		let dest = tmp.appendingPathComponent("9x16").appendingPathComponent("def456.png")
		XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
	}

	func testDeletesUnreadableFlatFile() throws {
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wallhavend-mig-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tmp) }

		let junk = tmp.appendingPathComponent("garbage.jpg")
		try "not an image".write(to: junk, atomically: true, encoding: .utf8)

		_ = WallpaperManager.migrateFlatFilesToBuckets(in: tmp)

		XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path))
	}

	func testLeavesBucketSubdirectoriesAlone() throws {
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wallhavend-mig-\(UUID().uuidString)", isDirectory: true)
		let existingBucket = tmp.appendingPathComponent("16x9", isDirectory: true)
		try FileManager.default.createDirectory(at: existingBucket, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tmp) }

		let existingFile = existingBucket.appendingPathComponent("existing.png")
		try writePNG(width: 1920, height: 1080, to: existingFile)

		_ = WallpaperManager.migrateFlatFilesToBuckets(in: tmp)

		XCTAssertTrue(FileManager.default.fileExists(atPath: existingFile.path))
	}
}
