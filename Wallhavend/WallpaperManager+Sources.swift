import Foundation

extension WallpaperManager {
	/// A wallpaper's bytes together with the filename stem to save them under.
	///
	/// The stem is bare for Wallhaven and `openverse_`-qualified otherwise, so `saveWallpaper` never needs to know which source produced it.
	struct DownloadedWallpaper {
		let stem: String
		let data: Data
		let fileExtension: String
	}

	/// Fetch a wallpaper from whichever enabled source produces one first, and bring its bytes back with it.
	///
	/// Fetch and download live together on purpose: an Openverse index entry can name a URL that no longer serves an image, and only a caller that sees both steps can fall through to Wallhaven when that happens.
	func fetchAndDownload(bucket: AspectBucket, atleast: String) async throws -> DownloadedWallpaper {
		let order = Self.sourceOrder(enabled: enabledSources, openverseCoolingDown: OpenverseService.shared.isCoolingDown)

		guard !order.isEmpty else {
			// Openverse was the only enabled source and it's sitting out a 429. With one source there's nothing to fall through to, and silence would be indistinguishable from a broken app.
			throw WallpaperError.rateLimited
		}

		var failures: [Error] = []

		for source in order {
			do {
				let candidate = try await fetchCandidate(from: source, bucket: bucket, atleast: atleast)
				let (data, fileExtension) = try await downloadWallpaper(from: candidate.directURL)

				return DownloadedWallpaper(stem: candidate.stem, data: data, fileExtension: fileExtension)
			} catch let error as CancellationError {
				// Cancellation isn't a source failing; it's the whole fill being called off.
				throw error
			} catch {
				print("\(source.displayName) couldn't supply a wallpaper for \(bucket.rawValue): \(error)")
				failures.append(error)
			}
		}

		throw Self.mostInformative(failures)
	}

	private func fetchCandidate(from source: WallpaperSource, bucket: AspectBucket, atleast: String) async throws -> (stem: String, directURL: String) {
		switch source {
			case .wallhaven:
				let wallpaper = try await WallhavenService.shared.fetchRandomWallpaper(ratios: bucket.rawValue, atleast: atleast)

				// Wallhaven stems stay bare forever, so its id already is the stem (see `WallpaperIdentity`).
				return (wallpaper.id, wallpaper.path)
			case .openverse:
				return try await OpenverseService.shared.fetchCandidate(
					bucket: bucket,
					atleast: atleast,
					blockedStems: WallhavenService.shared.blockedIds
				)
		}
	}

	/// The order to try sources in for one bucket fetch.
	///
	/// Shuffled rather than ranked, so with both enabled neither one dominates the pool.
	/// Openverse drops out entirely while it's cooling down from a 429 — trying it would only burn a request to be told the same thing again.
	nonisolated static func sourceOrder(enabled: Set<WallpaperSource>, openverseCoolingDown: Bool) -> [WallpaperSource] {
		enabled
			.filter { source in
				source != .openverse || !openverseCoolingDown
			}
			.shuffled()
	}

	/// Pick the error worth surfacing when every source failed.
	///
	/// "No wallpapers found" is the least informative outcome — it's what an over-narrow search looks like, and it hides a real failure standing behind it — so any other error wins.
	nonisolated static func mostInformative(_ errors: [Error]) -> Error {
		let informative = errors.first { error in
			guard let wallpaperError = error as? WallpaperError else {
				return true
			}

			return wallpaperError != .noResults
		}

		return informative ?? errors.first ?? WallpaperError.noResults
	}
}
