import Foundation

/// Where a saved wallpaper came from.
/// Raw values are the persisted keys — they appear in filename stems, and in stored settings once a second source becomes selectable — so changing one would orphan every file and preference already written under it.
enum WallpaperSource: String, CaseIterable {
	case wallhaven
	case openverse

	var displayName: String {
		switch self {
			case .wallhaven:
				return "Wallhaven"
			case .openverse:
				return "Openverse"
		}
	}
}

/// A wallpaper's source plus its id on that source, recovered from the local filename stem.
///
/// Wallhaven stems stay bare forever; only Openverse files carry a qualifying prefix.
/// That keeps pin, block, and pool membership as exact string equality on the stem — no dual-form matching, no migration of files or stored ids.
///
/// The scheme is unambiguous in both directions: Wallhaven ids are short alphanumerics, so no existing stem can start with `openverse_`, and Openverse ids are UUIDs, which contain no commas, so the comma-joined settings sets stay parseable.
struct WallpaperIdentity: Equatable {
	let source: WallpaperSource
	let id: String

	/// Recover the identity from a filename stem (see `WallpaperManager.wallpaperId(for:)`).
	/// A known `<key>_` prefix with a non-empty tail names the source; anything else is Wallhaven with the whole stem as the id.
	/// That fallback is deliberate rather than lenient — every file saved before this type existed is bare, so a stem that merely looks prefixed must keep its stem intact instead of being reinterpreted.
	nonisolated static func parse(stem: String) -> WallpaperIdentity {
		for source in WallpaperSource.allCases where source != .wallhaven {
			let prefix = "\(source.rawValue)_"
			guard stem.hasPrefix(prefix) else { continue }

			let id = String(stem.dropFirst(prefix.count))
			guard !id.isEmpty else { continue }

			return WallpaperIdentity(source: source, id: id)
		}

		return WallpaperIdentity(source: .wallhaven, id: stem)
	}

	/// The filename stem this identity is saved under — the inverse of `parse(stem:)`.
	var qualifiedStem: String {
		switch source {
			case .wallhaven:
				return id
			case .openverse:
				return "\(source.rawValue)_\(id)"
		}
	}

	/// The wallpaper's page on its source site.
	var pageURL: URL? {
		switch source {
			case .wallhaven:
				return URL(string: "https://wallhaven.cc/w/\(id)")
			case .openverse:
				return URL(string: "https://openverse.org/image/\(id)")
		}
	}

	/// A remotely hosted thumbnail, for the places that have an id but no local file (the Blocked tab).
	var thumbnailURL: URL? {
		switch source {
			case .wallhaven:
				// th.wallhaven.cc shards by the first two characters of the id, so a shorter id has no thumbnail path at all.
				guard id.count >= 2 else {
					return nil
				}

				return URL(string: "https://th.wallhaven.cc/lg/\(id.prefix(2))/\(id).jpg")
			case .openverse:
				return URL(string: "https://api.openverse.org/v1/images/\(id)/thumb/")
		}
	}
}
