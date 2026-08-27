import Foundation

/// The order Wallhaven returns search results in.
///
/// Raw values are both the API's `sorting` values and what gets persisted, so changing one would silently reset a user's choice.
/// Only `random` is stateless; the other four walk a result list page by page, which is why `WallhavenService` keeps a page cursor.
enum WallhavenSorting: String, CaseIterable, Identifiable {
	case random
	case dateAdded = "date_added"
	case views
	case favorites
	case toplist

	var id: String { rawValue }

	var label: String {
		switch self {
			case .random: return "Random"
			case .dateAdded: return "Date Added"
			case .views: return "Views"
			case .favorites: return "Favorites"
			case .toplist: return "Toplist"
		}
	}
}

/// How far back Wallhaven's toplist reaches. Sent as `topRange`, and only meaningful while sorting is `.toplist`.
///
/// Raw values are persisted as well as sent, so they can't change. Note the case-sensitive `M` for months against `m` for minutes elsewhere in Wallhaven's API.
enum WallhavenToplistRange: String, CaseIterable, Identifiable {
	case oneDay = "1d"
	case threeDays = "3d"
	case oneWeek = "1w"
	case oneMonth = "1M"
	case threeMonths = "3M"
	case sixMonths = "6M"
	case oneYear = "1y"

	var id: String { rawValue }

	var label: String {
		switch self {
			case .oneDay: return "1 Day"
			case .threeDays: return "3 Days"
			case .oneWeek: return "1 Week"
			case .oneMonth: return "1 Month"
			case .threeMonths: return "3 Months"
			case .sixMonths: return "6 Months"
			case .oneYear: return "1 Year"
		}
	}
}

/// Wallhaven's `colors` filter, which matches against a fixed palette rather than arbitrary hex.
///
/// An off-palette value isn't rejected — the API answers 200 with zero results (measured 2026-08-27: `colors=000000` returns 248,613 wallpapers, `colors=123456` returns none), so a typo is indistinguishable from an over-narrow search.
/// That's why the picker offers the palette rather than trusting free text, and why `sanitized(_:)` exists for the text field that remains.
enum WallhavenColor {
	/// The 29 swatches Wallhaven itself offers, in its own display order. Lowercase because the API is case-sensitive: `colors=CC0000` matches nothing.
	nonisolated static let palette = [
		"660000", "990000", "cc0000", "cc3333", "ea4c88", "993399", "663399",
		"333399", "0066cc", "0099cc", "66cccc", "77cc33", "669900", "336600",
		"666600", "999900", "cccc33", "ffff00", "ffcc33", "ff9900", "ff6600",
		"cc6633", "996633", "663300", "000000", "999999", "cccccc", "ffffff", "424153"
	]

	/// The colours a stored `filterColor` selects, for the picker to render as checked.
	nonisolated static func selection(from stored: String) -> Set<String> {
		Set(
			stored.split(separator: ",")
				.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
				.filter { !$0.isEmpty }
		)
	}

	/// Add or remove one swatch, returning the new stored value.
	/// Sorted so the same selection always produces the same string — otherwise `GlobalParams` would see a change and wipe the cache on every re-render.
	nonisolated static func toggled(_ hex: String, in stored: String) -> String {
		var selected = selection(from: stored)
		if selected.contains(hex) {
			selected.remove(hex)
		} else {
			selected.insert(hex)
		}

		return selected.sorted()
			.joined(separator: ",")
	}

	/// Coerce typed text toward something Wallhaven can match: drop the `#` people habitually type, lowercase it, and keep only hex digits and the separator.
	/// Deliberately not a validity check — the palette is, and typing is a work in progress until the field loses focus.
	nonisolated static func sanitized(_ text: String) -> String {
		let allowed = Set("0123456789abcdef,")

		return text.lowercased()
			.filter { allowed.contains($0) }
	}

	/// The channel values for rendering a swatch, or `nil` if the hex isn't six digits.
	nonisolated static func channels(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
		guard hex.count == 6, let value = Int(hex, radix: 16) else {
			return nil
		}

		let red = Double((value >> 16) & 0xFF) / 255
		let green = Double((value >> 8) & 0xFF) / 255
		let blue = Double(value & 0xFF) / 255

		return (red, green, blue)
	}
}
