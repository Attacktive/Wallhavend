import Foundation
import ImageIO

/// Who made a wallpaper and under what terms, in its source's own words.
///
/// `statement` is the load-bearing field. Openverse composes a license-correct sentence itself — including dropping the "by …" clause when it holds no creator — so assembling one here out of the parts would only reintroduce a case it has already handled.
/// `creator` rides along because XMP wants the bare name in a field of its own, where a photo tool can index it. Sampled 2026-08-29, it was absent for 11 of 20 rawpixel results while `statement` was never absent.
struct WallpaperCredit: Equatable, Sendable {
	let creator: String?
	let statement: String
	let licenseURL: String?
}

/// Carrying a credit inside the image file itself, as standard XMP.
///
/// The file is the store, which is the whole reason to do it this way: nothing needs pruning when a wallpaper is deleted, blocked, or cleaned up, and the credit survives the file being dragged out of the pool — the one thing "Copy Openverse URL" can't do.
///
/// Both writers insert a block and copy every other byte through untouched, which is what rules out the obvious shortcut.
/// `CGImageDestinationAddImageFromSource` re-encodes rather than restamping: measured 2026-08-29 on a 108 KB JPEG at +21% and a rebuilt set of Huffman tables, which is the wrong trade in an app that offers to avoid blurry wallpapers.
extension WallpaperCredit {
	private static let jpegSignature: [UInt8] = [0xFF, 0xD8]
	private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

	/// The namespace an APP1 segment has to lead with before a reader will take the payload for XMP.
	private static let xmpSegmentHeader = Data("http://ns.adobe.com/xap/1.0/".utf8) + Data([0x00])

	/// The keyword a PNG text chunk has to carry, for the same reason.
	private static let xmpChunkKeyword = "XML:com.adobe.xmp"

	/// This credit written into `data`, or `data` untouched when the bytes aren't a container we can write to.
	/// Failing open is deliberate: a wallpaper missing its credit is a small loss, and one that won't decode is a broken rotation.
	func embedded(in data: Data, fileExtension: String) -> Data {
		let packet = Self.xmpPacket(for: self)

		let stamped: Data? = switch fileExtension.lowercased() {
			case "jpg", "jpeg":
				Self.embedding(packet: packet, inJPEG: data)
			case "png":
				Self.embedding(packet: packet, inPNG: data)
			default:
				nil
		}

		return stamped ?? data
	}

	/// The credit a saved wallpaper carries, or `nil` for one saved without it — every Wallhaven file, and everything already in the pool before this shipped.
	static func read(from url: URL) -> WallpaperCredit? {
		guard
			let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
			let statement = CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:rights" as CFString) as String?,
			!statement.isEmpty
		else {
			return nil
		}

		return WallpaperCredit(
			creator: CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:creator" as CFString) as String?,
			statement: statement,
			licenseURL: CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmpRights:WebStatement" as CFString) as String?
		)
	}

	/// The XMP packet, deliberately unindented — every byte of it rides along on every wallpaper, and no reader cares how it looks.
	static func xmpPacket(for credit: WallpaperCredit) -> Data {
		let creatorElement = if let creator = credit.creator, !creator.isEmpty {
			"<dc:creator><rdf:Seq><rdf:li>\(escapedForXML(creator))</rdf:li></rdf:Seq></dc:creator>"
		} else {
			""
		}

		let webStatement = if let licenseURL = credit.licenseURL, !licenseURL.isEmpty {
			"<xmpRights:WebStatement>\(escapedForXML(licenseURL))</xmpRights:WebStatement>"
		} else {
			""
		}

		let rights = "<dc:rights><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escapedForXML(credit.statement))</rdf:li></rdf:Alt></dc:rights>"

		let xml = """
		<?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
		<x:xmpmeta xmlns:x="adobe:ns:meta/">
		<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
		<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/">
		\(creatorElement)\(rights)\(webStatement)
		</rdf:Description>
		</rdf:RDF>
		</x:xmpmeta>
		<?xpacket end="w"?>
		"""

		return Data(xml.utf8)
	}

	/// An APP1 XMP segment inserted immediately after the SOI marker, leaving every following byte exactly where it was.
	/// `nil` when the bytes don't open like a JPEG, or when the packet won't fit a segment's 16-bit length — neither is worth failing a download over.
	static func embedding(packet: Data, inJPEG data: Data) -> Data? {
		let bytes = [UInt8](data)

		guard bytes.starts(with: jpegSignature) else {
			return nil
		}

		let body = xmpSegmentHeader + packet
		let length = body.count + 2

		guard length <= 0xFFFF else {
			return nil
		}

		var result = Data(jpegSignature)
		result.append(contentsOf: [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
		result.append(body)
		result.append(contentsOf: bytes.dropFirst(jpegSignature.count))

		return result
	}

	/// An iTXt chunk carrying the packet, inserted ahead of the first IDAT so no pixel chunk moves or changes.
	static func embedding(packet: Data, inPNG data: Data) -> Data? {
		let bytes = [UInt8](data)

		guard bytes.starts(with: pngSignature), let start = firstIDATOffset(in: bytes) else {
			return nil
		}

		var payload = Data(xmpChunkKeyword.utf8)

		// The keyword's null terminator, then iTXt's compression flag and method, then the two empty strings it requires: a language tag and a translated keyword.
		payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00])
		payload.append(packet)

		let type = Data("iTXt".utf8)
		var chunk = bigEndianBytes(UInt32(payload.count))
		chunk.append(type)
		chunk.append(payload)
		chunk.append(bigEndianBytes(crc32(type + payload)))

		var result = Data(bytes[0..<start])
		result.append(chunk)
		result.append(contentsOf: bytes[start...])

		return result
	}

	/// Where the first IDAT chunk starts, counting from its length prefix.
	///
	/// The chunk list is walked by those length prefixes rather than searched for the bytes `IDAT`, which occur inside compressed pixel data often enough to matter.
	private static func firstIDATOffset(in bytes: [UInt8]) -> Int? {
		let idat = Array("IDAT".utf8)
		var offset = pngSignature.count

		while offset + 8 <= bytes.count {
			if Array(bytes[(offset + 4)..<(offset + 8)]) == idat {
				return offset
			}

			let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }

			// Length prefix, type, payload, CRC. A malformed length just walks off the end and gives up.
			offset += 12 + length
		}

		return nil
	}

	private static func bigEndianBytes(_ value: UInt32) -> Data {
		Data([
			UInt8(truncatingIfNeeded: value >> 24),
			UInt8(truncatingIfNeeded: value >> 16),
			UInt8(truncatingIfNeeded: value >> 8),
			UInt8(truncatingIfNeeded: value)
		])
	}

	/// Every PNG chunk carries a CRC-32 of its type and payload. zlib has one, but reaching for it would mean a module map to save four lines of table arithmetic.
	static func crc32(_ bytes: Data) -> UInt32 {
		var crc: UInt32 = 0xFFFFFFFF

		for byte in bytes {
			crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
		}

		return crc ^ 0xFFFFFFFF
	}

	private static let crcTable: [UInt32] = (0..<256).map { seed in
		(0..<8).reduce(UInt32(seed)) { crc, _ in
			if crc & 1 == 1 {
				return 0xEDB88320 ^ (crc >> 1)
			} else {
				return crc >> 1
			}
		}
	}

	/// Creator names are arbitrary strings from an open index, so a `Ben & Co` would otherwise cost the credit on every image they ever uploaded.
	static func escapedForXML(_ value: String) -> String {
		var escaped = ""

		for character in value {
			switch character {
				case "&":
					escaped += "&amp;"
				case "<":
					escaped += "&lt;"
				case ">":
					escaped += "&gt;"
				case "\"":
					escaped += "&quot;"
				case "'":
					escaped += "&apos;"
				default:
					if isForbiddenInXML(character) {
						continue
					}

					escaped.append(character)
			}
		}

		return escaped
	}

	/// XML 1.0 admits no control character but tab, newline and carriage return, and one stray byte would invalidate the whole packet.
	private static func isForbiddenInXML(_ character: Character) -> Bool {
		guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
			return false
		}

		return scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r"
	}
}
