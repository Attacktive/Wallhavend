import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Wallhavend

/// Writing a credit into an image and reading it back out.
///
/// The whole approach rests on one claim — that the writers insert a block and move no pixel — so that is what most of this asserts, byte for byte, rather than trusting that a stamped file still happens to open.
final class WallpaperCreditTests: XCTestCase {
	private var temporaryFiles: [URL] = []

	private let sample = WallpaperCredit(
		creator: "Startup Stock Photos",
		statement: "\"Team Meeting\" by Startup Stock Photos is marked with CC0 1.0. To view the terms, visit https://creativecommons.org/publicdomain/zero/1.0/.",
		licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
	)

	override func tearDownWithError() throws {
		for url in temporaryFiles {
			try? FileManager.default.removeItem(at: url)
		}

		temporaryFiles = []
	}

	// MARK: - the load-bearing claim: a block goes in and nothing else moves

	func testJPEGWriterOnlyInserts() throws {
		let original = try sampleData(utType: .jpeg)
		let stamped = try XCTUnwrap(WallpaperCredit.embedding(packet: WallpaperCredit.xmpPacket(for: sample), inJPEG: original))

		assertOnlyAnInsertion(from: original, to: stamped)
	}

	func testPNGWriterOnlyInserts() throws {
		let original = try sampleData(utType: .png)
		let stamped = try XCTUnwrap(WallpaperCredit.embedding(packet: WallpaperCredit.xmpPacket(for: sample), inPNG: original))

		assertOnlyAnInsertion(from: original, to: stamped)
	}

	func testStampingCostsUnderAKilobyte() throws {
		// A wallpaper carries this on every fetch, so a regression that started re-encoding would show up here first as a size explosion.
		let original = try sampleData(utType: .jpeg)
		let stamped = sample.embedded(in: original, fileExtension: "jpg")

		XCTAssertLessThan(stamped.count - original.count, 1024)
	}

	// MARK: - round trips through ImageIO, which is what the Gallery reads with

	func testJPEGRoundTripsThroughImageIO() throws {
		let url = try stampedFile(utType: .jpeg, fileExtension: "jpg", credit: sample)
		let recovered = try XCTUnwrap(WallpaperCredit.read(from: url))

		XCTAssertEqual(recovered, sample)
	}

	func testPNGRoundTripsThroughImageIO() throws {
		let url = try stampedFile(utType: .png, fileExtension: "png", credit: sample)
		let recovered = try XCTUnwrap(WallpaperCredit.read(from: url))

		XCTAssertEqual(recovered, sample)
	}

	func testStampedImageStillDecodes() throws {
		let url = try stampedFile(utType: .jpeg, fileExtension: "jpg", credit: sample)
		let dimensions = try XCTUnwrap(WallpaperManager.readImagePixelDimensions(at: url))

		XCTAssertEqual(dimensions.0, 8)
		XCTAssertEqual(dimensions.1, 8)
	}

	func testAnUnstampedFileReadsAsNoCredit() throws {
		// Every Wallhaven wallpaper, and everything already in the pool before this shipped.
		let url = try temporaryFile(try sampleData(utType: .jpeg), fileExtension: "jpg")

		XCTAssertNil(WallpaperCredit.read(from: url))
	}

	// MARK: - creator names are arbitrary strings from an open index

	func testCreatorWithMarkupSurvivesVerbatim() throws {
		let awkward = WallpaperCredit(
			creator: "Ben & Co <\"Photos\">",
			statement: "Shot by Ben & Co — 5 < 6 & \"quoted\".",
			licenseURL: "https://example.org/terms?a=1&b=2"
		)

		let url = try stampedFile(utType: .jpeg, fileExtension: "jpg", credit: awkward)
		let recovered = try XCTUnwrap(WallpaperCredit.read(from: url))

		XCTAssertEqual(recovered, awkward)
	}

	func testControlCharactersAreDroppedRatherThanBreakingThePacket() throws {
		// XML 1.0 admits no bare control characters, and one of them would otherwise cost the credit on every image by that creator.
		let awkward = WallpaperCredit(creator: "Ben\u{07}Co", statement: "A\u{0C}statement", licenseURL: nil)
		let url = try stampedFile(utType: .jpeg, fileExtension: "jpg", credit: awkward)
		let recovered = try XCTUnwrap(WallpaperCredit.read(from: url))

		XCTAssertEqual(recovered.creator, "BenCo")
		XCTAssertEqual(recovered.statement, "Astatement")
	}

	func testMissingCreatorAndLicenseStillProduceAReadableCredit() throws {
		// Openverse leaves `creator` empty for a good share of rawpixel's index, and its own sentence already reads correctly without it.
		let bare = WallpaperCredit(creator: nil, statement: "\"Free siberian husky dog image\" is marked with CC0 1.0.", licenseURL: nil)
		let url = try stampedFile(utType: .jpeg, fileExtension: "jpg", credit: bare)
		let recovered = try XCTUnwrap(WallpaperCredit.read(from: url))

		XCTAssertEqual(recovered, bare)
	}

	// MARK: - the PNG chunk walk

	func testDecoyIDATInsideAnEarlierChunkDoesNotFoolTheWalk() throws {
		/*
			The bytes `IDAT` occur inside compressed pixel data often enough to matter, so the writer walks the chunk list by its length prefixes.
			A byte search would splice the new chunk into the middle of the decoy's payload, breaking its length and CRC — which ImageIO would then refuse.
		*/
		let original = try pngWithDecoyIDAT()
		let stamped = sample.embedded(in: original, fileExtension: "png")
		let url = try temporaryFile(stamped, fileExtension: "png")

		assertOnlyAnInsertion(from: original, to: stamped)
		XCTAssertNotNil(WallpaperManager.readImagePixelDimensions(at: url))
		XCTAssertEqual(WallpaperCredit.read(from: url), sample)
	}

	func testCRC32MatchesTheStandardVector() {
		// The check value every CRC-32 implementation is measured against.
		XCTAssertEqual(WallpaperCredit.crc32(Data("123456789".utf8)), 0xCBF4_3926)
	}

	// MARK: - failing open

	func testAnUnwritableFormatLeavesTheBytesAlone() throws {
		let original = try sampleData(utType: .jpeg)

		XCTAssertEqual(sample.embedded(in: original, fileExtension: "gif"), original)
	}

	func testBytesThatArentAnImageAreLeftAlone() {
		// A wallpaper missing its credit is a small loss; one that won't decode is a broken rotation.
		let notAnImage = Data("this is not a JPEG".utf8)

		XCTAssertEqual(sample.embedded(in: notAnImage, fileExtension: "jpg"), notAnImage)
		XCTAssertEqual(sample.embedded(in: notAnImage, fileExtension: "png"), notAnImage)
	}

	func testJPEGExtensionIsMatchedCaseInsensitively() throws {
		let original = try sampleData(utType: .jpeg)

		XCTAssertGreaterThan(sample.embedded(in: original, fileExtension: "JPEG").count, original.count)
	}

	// MARK: - helpers

	/// The writers insert a block and copy everything else through, so deleting one contiguous run from the result has to give the input back exactly.
	private func assertOnlyAnInsertion(from original: Data, to stamped: Data, file: StaticString = #filePath, line: UInt = #line) {
		let originalBytes = [UInt8](original)
		let stampedBytes = [UInt8](stamped)

		XCTAssertGreaterThan(stampedBytes.count, originalBytes.count, "nothing was written", file: file, line: line)

		let commonPrefix = zip(originalBytes, stampedBytes).prefix { $0 == $1 }.count
		let insertedCount = stampedBytes.count - originalBytes.count
		let withoutInsertion = Array(stampedBytes[0..<commonPrefix]) + Array(stampedBytes[(commonPrefix + insertedCount)...])

		XCTAssertEqual(withoutInsertion, originalBytes, "the writer changed bytes it should only have moved", file: file, line: line)
	}

	private func sampleImage() throws -> CGImage {
		let side = 8
		let context = try XCTUnwrap(CGContext(
			data: nil,
			width: side,
			height: side,
			bitsPerComponent: 8,
			bytesPerRow: side * 4,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
		))

		context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: side, height: side))

		return try XCTUnwrap(context.makeImage())
	}

	private func sampleData(utType: UTType) throws -> Data {
		let image = try sampleImage()
		let buffer = NSMutableData()
		let destination = try XCTUnwrap(CGImageDestinationCreateWithData(buffer, utType.identifier as CFString, 1, nil))

		CGImageDestinationAddImage(destination, image, nil)
		XCTAssertTrue(CGImageDestinationFinalize(destination))

		return buffer as Data
	}

	private func stampedFile(utType: UTType, fileExtension: String, credit: WallpaperCredit) throws -> URL {
		let stamped = credit.embedded(in: try sampleData(utType: utType), fileExtension: fileExtension)

		return try temporaryFile(stamped, fileExtension: fileExtension)
	}

	private func temporaryFile(_ data: Data, fileExtension: String) throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("credit-\(UUID().uuidString).\(fileExtension)")
		try data.write(to: url)

		temporaryFiles.append(url)

		return url
	}

	/// A PNG whose first IDAT is preceded by a text chunk that itself contains the bytes `IDAT`.
	/// The signature is 8 bytes and IHDR is always the first chunk at a fixed 25, so the insertion point needs no walking of its own.
	private func pngWithDecoyIDAT() throws -> Data {
		let original = try sampleData(utType: .png)
		let type = Data("tEXt".utf8)
		let payload = Data("Comment\u{00}IDAT IDAT IDAT".utf8)
		let length = UInt32(payload.count)
		let crc = WallpaperCredit.crc32(type + payload)

		var chunk = Data([
			UInt8(truncatingIfNeeded: length >> 24),
			UInt8(truncatingIfNeeded: length >> 16),
			UInt8(truncatingIfNeeded: length >> 8),
			UInt8(truncatingIfNeeded: length)
		])

		chunk.append(type)
		chunk.append(payload)
		chunk.append(contentsOf: [
			UInt8(truncatingIfNeeded: crc >> 24),
			UInt8(truncatingIfNeeded: crc >> 16),
			UInt8(truncatingIfNeeded: crc >> 8),
			UInt8(truncatingIfNeeded: crc)
		])

		let insertionPoint = 8 + 25
		var decoyed = Data(original.prefix(insertionPoint))
		decoyed.append(chunk)
		decoyed.append(contentsOf: original.dropFirst(insertionPoint))

		return decoyed
	}
}
