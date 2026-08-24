import Foundation
import SwiftUI

struct OpenverseSearchResponse: Decodable {
	let pageCount: Int
	let results: [OpenverseImage]

	enum CodingKeys: String, CodingKey {
		case pageCount = "page_count"
		case results
	}
}

struct OpenverseImage: Decodable {
	let id: String
	let url: String?
	let width: Int?
	let height: Int?
}

/// How permissive an Openverse result's license may be, narrowest first.
///
/// Each tier names its licenses outright instead of leaning on Openverse's `license_type` grouping, so the tiers stay strictly nested — widening the filter can only ever add licenses, never swap one out.
/// Raw values are persisted, so changing one would silently reset a user's choice.
enum OpenverseLicenseFilter: String, CaseIterable, Identifiable {
	/// No attribution obligation at all, which is why it's the default.
	case publicDomain = "public_domain"
	case permissive
	case anyCommercial = "any_commercial"

	var id: String { rawValue }

	var apiValue: String {
		switch self {
			case .publicDomain:
				return "cc0,pdm"
			case .permissive:
				return "cc0,pdm,by"
			case .anyCommercial:
				return "cc0,pdm,by,by-sa,by-nd"
		}
	}

	var label: String {
		switch self {
			case .publicDomain:
				return "Public domain"
			case .permissive:
				return "Permissive"
			case .anyCommercial:
				return "Any commercial use"
		}
	}
}

/// Everything Openverse, kept entirely apart from `WallhavenService` so neither source's quirks leak into the other.
///
/// The shape differs from Wallhaven's in two ways that both come from Openverse being an unauthenticated community API: requests are spaced rather than burst, and results are cached per aspect parameter instead of per bucket, because one `wide` page can feed four of our five buckets.
@MainActor
final class OpenverseService: ObservableObject {
	static let shared = OpenverseService()

	/// The trailing slash is load-bearing: without it Openverse answers with a 301 that `URLSession` follows as a GET but the API treats as a different route.
	private static let baseURL = "https://api.openverse.org/v1/images/"

	/// Openverse indexes 52 sources and most are archival — herbarium sheets and scanned postcards make poor wallpapers — so a search only ever names one of these.
	///
	/// Measured 2026-08-22: `flickr` and `nasa` return nothing while `size=large` is in play, because Openverse derives that filter from filesize and their index rows carry none.
	/// They stay in the list anyway: the live-source strike-off prunes them at runtime for the cost of one request each, and they start contributing again for free if Openverse ever fills that gap.
	/// `spacex` is absent because it returns nothing under *any* filter combination, including none at all — a dead source rather than a gapped one.
	nonisolated static let curatedSources = ["flickr", "wikimedia", "nasa", "rawpixel", "stocksnap"]

	/// `saveWallpaper` only accepts JPEG and PNG, so anything else is ruled out server-side instead of downloaded and thrown away.
	private static let extensions = "jpg,png"

	/// Anonymous requests may ask for 20 results at a time and reach 240 results deep.
	/// An API key lifts only the first: authenticated callers face the same ceiling on total works per query and merely reach it in fewer round trips, so carrying one would buy no extra wallpapers.
	private static let pageSize = 20
	private static let maximumDepth = 240
	private static let maximumPages = maximumDepth / pageSize

	/// A page can come back full and still admit nothing, so one `fetchCandidate` gets a bounded number of refetches before giving up and letting the router fall through.
	private static let maximumRefetches = 5

	/// Wallhaven fetches a page and caches it; Openverse's pages are shallower, so a pool fill reaches the network far more often. Spacing is what keeps that burst from earning a 429.
	private static let minimumRequestSpacing: TimeInterval = 1.5

	/// How long to sit out after Openverse rate-limits us anyway.
	private static let coolDownDuration: TimeInterval = 600

	/// Results that admit for no active bucket would otherwise pile up until the search key changes.
	private static let maximumCachedPerAspect = 120

	@AppStorage("openverseLicenseFilter")
	private var licenseFilterRaw: String = OpenverseLicenseFilter.publicDomain.rawValue

	var licenseFilter: OpenverseLicenseFilter {
		get {
			OpenverseLicenseFilter(rawValue: licenseFilterRaw) ?? .publicDomain
		}
		set {
			objectWillChange.send()
			licenseFilterRaw = newValue.rawValue
		}
	}

	/// The query inputs that define a result set. When they change, everything derived from the old ones is stale — including which sources looked dead.
	private struct SearchKey: Equatable {
		let keywords: [String]
		let license: String
		let mature: Bool
	}

	/// The 240-result depth cap applies per query, so each keyword, source, and aspect pairing is its own window with its own depth.
	/// Tracking the page count per pairing is what keeps a shallow window from deciding how deep a deep one may go.
	private struct PageWindow: Hashable {
		let keyword: String?
		let source: String
		let aspect: String
	}

	private var lastSearchKey: SearchKey?
	private var candidatesByAspect: [String: [OpenverseImage]] = [:]
	private var pageCounts: [PageWindow: Int] = [:]
	private var liveSources = OpenverseService.curatedSources
	private var lastRequestAt: Date?
	private var coolDownUntil: Date?

	/// True while a 429 is still being respected. The router skips Openverse outright rather than queueing behind it.
	var isCoolingDown: Bool {
		guard let coolDownUntil else {
			return false
		}

		return coolDownUntil > Date()
	}

	/// Openverse's aspect filter is coarse: three buckets against our five.
	/// `square` is never requested — no screen snaps to it — and all four landscape buckets have to share `wide`, which is the whole reason the client-side admit gate exists.
	nonisolated static func aspectParameter(for bucket: AspectBucket) -> String {
		switch bucket {
			case .portrait:
				return "tall"
			case .ultrawide, .landscape16x9, .landscape16x10, .landscape4x3:
				return "wide"
		}
	}

	/// Whether a result may be saved under `bucket`.
	///
	/// Neither of Openverse's own filters is trustworthy here: `wide` covers four of our buckets, and `size` is a coarse small/medium/large bucket derived from filesize.
	/// Wallpapers are filed by bucket, so the snap check is what makes the requested bucket equal the measured one — a stronger guarantee than Wallhaven's `ratios` filter gives today.
	/// A result that never reported its dimensions can't prove it qualifies.
	nonisolated static func admits(width: Int?, height: Int?, minimumWidth: Int, minimumHeight: Int, bucket: AspectBucket) -> Bool {
		guard let width, let height, width > 0, height > 0 else {
			return false
		}

		guard width >= minimumWidth, height >= minimumHeight else {
			return false
		}

		return AspectBucket.snap(aspectRatio: Double(width) / Double(height)) == bucket
	}

	/// Openverse has no random sort, so variety comes from where in the result set a fetch lands.
	/// The first fetch of a window has to be page 1 — nothing yet says how deep that window goes — and every one after it picks at random within reach.
	nonisolated static func pageRange(knownPageCount: Int?) -> ClosedRange<Int> {
		guard let knownPageCount else {
			return 1...1
		}

		return 1...max(1, min(knownPageCount, maximumPages))
	}

	/// Find one Openverse image that fits `bucket`, downloading nothing.
	/// Returns the filename stem to save it under and the direct image URL for the caller to download.
	func fetchCandidate(bucket: AspectBucket, atleast: String, blockedStems: Set<String>) async throws -> (stem: String, directURL: String) {
		clearCachesIfSearchKeyChanged()

		let avoidBlurryWallpapers = WallhavenService.shared.avoidBlurryWallpapers

		// `atleast` is produced by `AspectBucket.atleastString(for:)`, so this only fails if that contract breaks. Reporting no results lets the router fall through to Wallhaven instead of failing the whole tick.
		guard let minimum = AspectBucket.minimumDimensions(atleast: atleast) else {
			throw WallpaperError.noResults
		}

		let aspect = Self.aspectParameter(for: bucket)
		var refetches = 0

		let resolvedMinimum = avoidBlurryWallpapers ? minimum : (width: 0, height: 0)

		while refetches < Self.maximumRefetches {
			if let candidate = drainCandidate(aspect: aspect, bucket: bucket, minimum: resolvedMinimum, blockedStems: blockedStems) {
				return candidate
			}

			guard !liveSources.isEmpty else {
				// Every curated source came back empty for these settings; another request would just repeat one of them.
				break
			}

			let received = try await refill(aspect: aspect)

			// An empty source is struck off rather than charged to the budget — discovering a dead source shouldn't cost a real attempt.
			if received > 0 {
				refetches += 1
			}
		}

		throw WallpaperError.noResults
	}

	/// Take the first cached result that fits this bucket, removing only that one.
	/// A result that fails here may still fit another bucket sharing the same aspect parameter, so the rest of the cache stays put.
	private func drainCandidate(
		aspect: String,
		bucket: AspectBucket,
		minimum: (width: Int, height: Int),
		blockedStems: Set<String>
	) -> (stem: String, directURL: String)? {
		guard var cached = candidatesByAspect[aspect] else {
			return nil
		}

		for (index, image) in cached.enumerated() {
			guard let directURL = image.url, !directURL.isEmpty else {
				continue
			}

			let stem = WallpaperIdentity(source: .openverse, id: image.id).qualifiedStem
			guard !blockedStems.contains(stem) else {
				continue
			}

			guard Self.admits(width: image.width, height: image.height, minimumWidth: minimum.width, minimumHeight: minimum.height, bucket: bucket) else {
				continue
			}

			cached.remove(at: index)
			candidatesByAspect[aspect] = cached

			return (stem, directURL)
		}

		return nil
	}

	/// Fetch one page from one randomly chosen live source and add what it returns to the aspect's cache.
	/// Returns how many results came back; zero means the source has nothing for the current search key and is struck from the live set.
	private func refill(aspect: String) async throws -> Int {
		guard let source = liveSources.randomElement() else {
			return 0
		}

		/*
			One keyword per request, picked at random, rather than the Android sibling's parallel fan-out across every keyword.
			A pool fill already bursts up to `poolSize * 2 + 2` attempts per bucket, and multiplying that by the keyword count is how an unauthenticated API says no.
		*/
		let keyword = WallhavenService.keywords(from: WallhavenService.shared.searchQuery).randomElement()
		let window = PageWindow(keyword: keyword, source: source, aspect: aspect)
		let page = Int.random(in: Self.pageRange(knownPageCount: pageCounts[window]))

		let response = try await search(keyword: keyword, source: source, aspect: aspect, page: page)

		pageCounts[window] = response.pageCount

		guard !response.results.isEmpty else {
			liveSources.removeAll { $0 == source }
			print("Openverse source \(source) returned nothing for the current settings; skipping it until they change.")

			return 0
		}

		// The index occasionally carries a plain-http direct URL, which App Transport Security would block partway through the download.
		let usable = response.results
			.filter { ($0.url ?? "").hasPrefix("https://") }
			.shuffled()

		var cached = candidatesByAspect[aspect] ?? []
		cached.append(contentsOf: usable)

		if cached.count > Self.maximumCachedPerAspect {
			cached.removeFirst(cached.count - Self.maximumCachedPerAspect)
		}

		candidatesByAspect[aspect] = cached
		print("Openverse fetched page \(page) of \(source) for \(aspect): \(response.results.count) results, \(usable.count) usable.")

		return response.results.count
	}

	private func search(keyword: String?, source: String, aspect: String, page: Int) async throws -> OpenverseSearchResponse {
		guard !isCoolingDown else {
			throw WallpaperError.rateLimited
		}

		var components = URLComponents(string: Self.baseURL)!
		var items = [
			URLQueryItem(name: "license", value: licenseFilter.apiValue),
			URLQueryItem(name: "extension", value: Self.extensions),
			URLQueryItem(name: "aspect_ratio", value: aspect),
			URLQueryItem(name: "source", value: source),
			URLQueryItem(name: "page", value: String(page)),
			URLQueryItem(name: "page_size", value: String(Self.pageSize))
		]

		if WallhavenService.shared.avoidBlurryWallpapers {
			items.append(URLQueryItem(name: "size", value: "large"))
		}

		if let keyword {
			items.append(URLQueryItem(name: "q", value: keyword))
		}

		// Openverse's `mature` widens the results rather than restricting them to explicit ones, so it follows the one purity flag that means the same thing.
		if WallhavenService.shared.includeNSFW {
			items.append(URLQueryItem(name: "mature", value: "true"))
		}

		components.queryItems = items

		guard let url = components.url else {
			throw WallpaperError.invalidURL
		}

		return try await perform(url: url)
	}

	/// One HTTP round trip, spaced from the last and retried once if Openverse asks us to wait.
	private func perform(url: URL) async throws -> OpenverseSearchResponse {
		for attempt in 0...1 {
			try await waitForRequestSlot()

			let (data, response) = try await URLSession.shared.data(from: url)

			guard let httpResponse = response as? HTTPURLResponse else {
				throw WallpaperError.invalidResponse
			}

			if httpResponse.statusCode == 429 {
				// Honor one `Retry-After`, then stop asking: a second 429 means the spacing isn't enough right now, and hammering a free community API to find out is the wrong move.
				if attempt == 0, let delay = Self.retryDelay(from: httpResponse) {
					print("Openverse asked for \(delay)s before the next request; honoring it once.")
					try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

					continue
				}

				coolDownUntil = Date().addingTimeInterval(Self.coolDownDuration)
				print("Openverse rate-limited us; sitting out for \(Int(Self.coolDownDuration / 60)) minutes while Wallhaven covers.")

				throw WallpaperError.rateLimited
			}

			guard httpResponse.statusCode == 200 else {
				throw WallpaperError.httpError(httpResponse.statusCode)
			}

			return try JSONDecoder().decode(OpenverseSearchResponse.self, from: data)
		}

		throw WallpaperError.rateLimited
	}

	/// Openverse's `Retry-After` in seconds, clamped so an unreasonable one can't stall a pool fill.
	private nonisolated static func retryDelay(from response: HTTPURLResponse) -> TimeInterval? {
		guard
			let header = response.value(forHTTPHeaderField: "Retry-After"),
			let seconds = TimeInterval(header)
		else {
			return nil
		}

		return min(max(seconds, 0), 10)
	}

	private func waitForRequestSlot() async throws {
		if let lastRequestAt {
			let remaining = Self.minimumRequestSpacing - Date().timeIntervalSince(lastRequestAt)
			if remaining > 0 {
				try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
			}
		}

		lastRequestAt = Date()
	}

	/// Mirrors `WallhavenService.clearCacheIfGlobalParamsChanged()`.
	/// Resetting `liveSources` matters as much as clearing the cache: a source with nothing for one keyword may be the best one for the next.
	private func clearCachesIfSearchKeyChanged() {
		let service = WallhavenService.shared
		let current = SearchKey(
			keywords: WallhavenService.keywords(from: service.searchQuery),
			license: licenseFilter.apiValue,
			mature: service.includeNSFW
		)

		if lastSearchKey != current {
			candidatesByAspect.removeAll()
			pageCounts.removeAll()
			liveSources = Self.curatedSources
			lastSearchKey = current
			print("Openverse cache invalidated (search key changed).")
		}
	}
}
