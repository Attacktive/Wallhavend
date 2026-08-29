import Foundation
import SwiftUI

struct WallhavenResponse: Decodable, Sendable {
	let data: [Wallpaper]
	let meta: Meta
}

/// Deliberately narrower than Wallhaven's response, which also carries `resolution`, `file_size`, `file_type` and `purity`; `Decodable` ignores a key with no matching property, so leaving them out costs nothing.
/// `category` looks just as unused from the app's side, but `WallhavendTests.testCategories` reads it to prove the category filter reached the API — don't sweep it away with the others.
struct Wallpaper: Decodable, Sendable {
	let id: String
	let url: String
	let path: String
	let category: String
}

struct Meta: Decodable, Sendable {
	let currentPage: Int
	let lastPage: Int
	let total: Int

	enum CodingKeys: String, CodingKey {
		case currentPage = "current_page"
		case lastPage = "last_page"
		case perPage = "per_page"
		case total
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		currentPage = try container.decode(Int.self, forKey: .currentPage)
		lastPage = try container.decode(Int.self, forKey: .lastPage)
		total = try container.decode(Int.self, forKey: .total)
	}
}

enum WallhavenCategory: String, CaseIterable {
	case general
	case anime
	case people
}

@MainActor
class WallhavenService: ObservableObject {
	static let shared = WallhavenService()
	let baseURL = "https://wallhaven.cc/api/v1"

	@AppStorage("searchQuery")
	var searchQuery: String = ""

	@AppStorage("sorting")
	private var sortingRaw: String = WallhavenSorting.random.rawValue

	@AppStorage("toplistRange")
	private var toplistRangeRaw: String = WallhavenToplistRange.oneMonth.rawValue

	@AppStorage("filterColor")
	private var filterColorRaw: String = ""

	@AppStorage("selectedCategories")
	private var selectedCategoriesRaw: String = "general"

	@AppStorage("apiKey")
	var apiKey: String = ""

	@AppStorage("includeSFW")
	var includeSFW: Bool = true

	@AppStorage("includeSketchy")
	var includeSketchy: Bool = false

	@AppStorage("includeNSFW")
	var includeNSFW: Bool = false

	@AppStorage("blockedIds")
	private var blockedIdsRaw: String = ""

	@AppStorage("pinnedIds")
	private var pinnedIdsRaw: String = ""

	/*
		The three settings below wrap their `@AppStorage` in a computed property that publishes, rather than being `@AppStorage` outright.
		`@AppStorage` only drives re-renders when it's declared inside a `View` — on an `ObservableObject` it's a plain UserDefaults read/write with no `objectWillChange`.
		Anything the UI *branches* on therefore has to announce itself by hand, the way `licenseFilter`, `blockedIds`, and `pinnedIds` already do: the Toplist Range picker appears only while sorting is `.toplist`, and the swatch grid draws its checkmarks from `filterColor`.
	*/

	var sorting: WallhavenSorting {
		get {
			WallhavenSorting(rawValue: sortingRaw) ?? .random
		}
		set {
			objectWillChange.send()
			sortingRaw = newValue.rawValue
		}
	}

	var toplistRange: WallhavenToplistRange {
		get {
			WallhavenToplistRange(rawValue: toplistRangeRaw) ?? .oneMonth
		}
		set {
			objectWillChange.send()
			toplistRangeRaw = newValue.rawValue
		}
	}

	var filterColor: String {
		get {
			filterColorRaw
		}
		set {
			objectWillChange.send()
			filterColorRaw = newValue
		}
	}

	var selectedCategories: Set<WallhavenCategory> {
		get {
			Set(
				selectedCategoriesRaw.split(separator: ",")
					.compactMap { WallhavenCategory(rawValue: String($0)) }
			)
		}
		set {
			selectedCategoriesRaw = newValue.map { $0.rawValue }
				.joined(separator: ",")
		}
	}

	var blockedIds: Set<String> {
		get {
			Set(
				blockedIdsRaw.split(separator: ",")
					.map { String($0) }
			)
		}
		set {
			objectWillChange.send()
			blockedIdsRaw = newValue.sorted().joined(separator: ",")
		}
	}

	func block(_ id: String) {
		var ids = blockedIds
		ids.insert(id)
		blockedIds = ids
	}

	func unblock(_ id: String) {
		var ids = blockedIds
		ids.remove(id)
		blockedIds = ids
	}

	/// Pinned wallpapers are exempt from pool eviction and form the set cycled by the Pinned-only rotation mode.
	/// Stored exactly like `blockedIds`: a comma-joined string-set keyed on the wallhaven id (the local filename stem).
	var pinnedIds: Set<String> {
		get {
			Set(
				pinnedIdsRaw.split(separator: ",")
					.map { String($0) }
			)
		}
		set {
			objectWillChange.send()
			pinnedIdsRaw = newValue.sorted().joined(separator: ",")
		}
	}

	func pin(_ id: String) {
		var ids = pinnedIds
		ids.insert(id)
		pinnedIds = ids
	}

	func unpin(_ id: String) {
		var ids = pinnedIds
		ids.remove(id)
		pinnedIds = ids
	}

	/// Pure selection step shared by the cache and network paths: drop blocked IDs, then pick the next wallpaper.
	/// Returns `nil` when nothing remains.
	static func selectWallpaper(
		from wallpapers: [Wallpaper],
		blocked: Set<String>
	) -> (selected: Wallpaper, remaining: [Wallpaper])? {
		var filtered = wallpapers.filter { !blocked.contains($0.id) }
		guard !filtered.isEmpty else {
			return nil
		}

		let selected = filtered.removeFirst()
		return (selected, filtered)
	}

	/// Splits the user search field into independent Wallhaven `q` values.
	/// Delimiters are `,`, `;`, and `|` only — spaces are preserved for Wallhaven query syntax (e.g. `+tag1 +tag2`).
	/// Returns an empty array when there is no query (caller omits `q`).
	nonisolated static func keywords(from searchQuery: String) -> [String] {
		searchQuery
			.components(separatedBy: CharacterSet(charactersIn: ",;|"))
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}

	var purityString: String {
		var bits = [String]()
		bits.append(includeSFW ? "1" : "0")
		bits.append(includeSketchy ? "1" : "0")
		bits.append(includeNSFW ? "1" : "0")
		return bits.joined()
	}

	private struct GlobalParams: Equatable {
		let categories: Set<WallhavenCategory>
		let purity: String
		let searchQuery: String
		let apiKey: String
		let sorting: WallhavenSorting
		let toplistRange: WallhavenToplistRange
		let filterColor: String
	}

	private var cachedWallpapers: [String: [Wallpaper]] = [:]
	private var lastGlobalParams: GlobalParams?

	/// Where each cache key's deterministic sorting has walked to. See `PageCursor`.
	private var pageCursors: [String: PageCursor] = [:]

	private func clearCacheIfGlobalParamsChanged() {
		let current = GlobalParams(
			categories: selectedCategories,
			purity: purityString,
			searchQuery: searchQuery,
			apiKey: apiKey,
			sorting: sorting,
			toplistRange: toplistRange,
			filterColor: filterColor
		)

		if lastGlobalParams != current {
			cachedWallpapers.removeAll()

			// The cursors go with the cache: a page-30 position in "most viewed" is meaningless in a five-page toplist, and resuming there would ask for a page that doesn't exist.
			pageCursors.removeAll()
			lastGlobalParams = current
			print("Wallhaven cache invalidated (global params changed).")
		}
	}

	/// One wallpaper for `ratios`, from the cache when it still holds a usable one and from the network otherwise.
	///
	/// Not "random" any more — only the `.random` sorting is; the other four walk their result list in order, page by page.
	/// `atleast` is `nil` when the user has turned off "Avoid blurry wallpapers", which drops the size floor from the query entirely.
	func fetchWallpaper(ratios: String, atleast: String?) async throws -> Wallpaper {
		clearCacheIfGlobalParamsChanged()

		let key = cacheKey(ratios: ratios, atleast: atleast)
		let cached = cachedWallpapers[key] ?? []
		if let result = Self.selectWallpaper(from: cached, blocked: blockedIds) {
			cachedWallpapers[key] = result.remaining
			print("Using cached wallpaper for \(key): ID=\(result.selected.id)")
			return result.selected
		}

		return try await fetchNewWallpapers(ratios: ratios, atleast: atleast, cacheKey: key)
	}

	/// Everything else that shapes a query is covered by `clearCacheIfGlobalParamsChanged`, which wipes the whole cache, so only the per-call arguments need to be keyed on.
	private func cacheKey(ratios: String, atleast: String?) -> String {
		"\(ratios)|\(atleast ?? "any")"
	}

	private static let maxReseedAttempts = 5

	private func fetchNewWallpapers(ratios: String, atleast: String?, cacheKey: String) async throws -> Wallpaper {
		/*
			Blocked wallpapers are filtered out *after* the fetch, so an entire page can come back fully blocked.
			Re-seed with a fresh seed a bounded number of times before giving up. For the deterministic sortings each attempt also walks a page further, which is what gets past a blocked stretch.
		*/
		for _ in 0..<Self.maxReseedAttempts {
			var fetched = try await rawFetch(ratios: ratios, atleast: atleast, cacheKey: cacheKey)

			// A raw fetch returning nothing is the genuine empty case — surface it immediately rather than burning re-seed attempts.
			if fetched.isEmpty {
				throw WallpaperError.noResults
			}

			// Random sorting has no order worth preserving; every other sorting was picked precisely for its order, so shuffling would undo the setting.
			if sorting == .random {
				fetched.shuffle()
			}

			if let result = Self.selectWallpaper(from: fetched, blocked: blockedIds) {
				cachedWallpapers[cacheKey] = result.remaining
				return result.selected
			}

			print("All \(fetched.count) candidates for \(cacheKey) are blocked; re-seeding.")
		}

		throw WallpaperError.noResults
	}

	private func rawFetch(ratios: String, atleast: String?, cacheKey: String) async throws -> [Wallpaper] {
		let cursor = pageCursors[cacheKey] ?? PageCursor()
		let page = Self.pageToFetch(sorting: sorting, cursor: cursor)
		let requests = try buildRequests(ratios: ratios, atleast: atleast, page: page)

		/*
			Claim the page before the first suspension point.
			This method is `@MainActor` but awaits the network, and an update tick can be in flight while a pool fill works the same bucket — same cache key, so without claiming both read the same cursor, download the same page, and then advance it twice.
		*/
		let claimed = Self.claiming(cursor, page: page)
		pageCursors[cacheKey] = claimed

		do {
			let responses = try await fetchAll(requests)

			// Re-read rather than building on `cursor`: another fetch may have claimed a page in the meantime, and only the depth is this one's to report.
			pageCursors[cacheKey] = Self.learning(pageCursors[cacheKey] ?? claimed, lastPages: responses.map { $0.meta.lastPage })

			let wallpapers = responses.flatMap { $0.data }

			/*
				Several keywords means several separate result lists arriving back to back, in whatever order the task group finished them.
				Interleaving them keeps one keyword from owning the front of the pool; a single keyword's list is left exactly as the sorting returned it.
			*/
			return if requests.count > 1 {
				wallpapers.shuffled()
			} else {
				wallpapers
			}
		} catch {
			// The page taught us nothing, so hand it back — but only while the claim still stands, or the rollback would deal a concurrent fetch's page out a second time.
			if pageCursors[cacheKey] == claimed {
				pageCursors[cacheKey] = cursor
			}

			throw error
		}
	}

	/// Run every keyword's request at once and hand back what each one decoded to.
	private func fetchAll(_ requests: [URLRequest]) async throws -> [WallhavenResponse] {
		try await withThrowingTaskGroup(of: WallhavenResponse.self) { group in
			for request in requests {
				group.addTask {
					let (data, response) = try await URLSession.shared.data(for: request)

					if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
						throw WallpaperError.httpError(httpResponse.statusCode)
					}

					return try JSONDecoder().decode(WallhavenResponse.self, from: data)
				}
			}

			var responses: [WallhavenResponse] = []
			for try await response in group {
				responses.append(response)
			}

			return responses
		}
	}
}
