import Foundation
import SwiftUI

struct WallhavenResponse: Decodable {
	let data: [Wallpaper]
	let meta: Meta
}

struct Wallpaper: Decodable, Sendable {
	let id: String
	let url: String
	let path: String
	let resolution: String
	let fileSize: Int
	let fileType: String
	let category: String
	let purity: String

	enum CodingKeys: String, CodingKey {
		case id, url, path, resolution, category, purity
		case fileSize = "file_size"
		case fileType = "file_type"
	}
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
	var sorting: WallhavenSorting = .random

	@AppStorage("toplistRange")
	var toplistRange: WallhavenToplistRange = .oneMonth

	@AppStorage("filterColor")
	var filterColor: String = ""

	@AppStorage("avoidBlurryWallpapers")
	var avoidBlurryWallpapers: Bool = false

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
		let avoidBlurryWallpapers: Bool
	}

	private var cachedWallpapers: [String: [Wallpaper]] = [:]
	private var lastGlobalParams: GlobalParams?

	private func clearCacheIfGlobalParamsChanged() {
		let current = GlobalParams(
			categories: selectedCategories,
			purity: purityString,
			searchQuery: searchQuery,
			apiKey: apiKey,
			sorting: sorting,
			toplistRange: toplistRange,
			filterColor: filterColor,
			avoidBlurryWallpapers: avoidBlurryWallpapers
		)

		if lastGlobalParams != current {
			cachedWallpapers.removeAll()
			lastGlobalParams = current
			print("Wallhaven cache invalidated (global params changed).")
		}
	}

	private var currentPage = 1
	private var lastPage = 1

	func fetchRandomWallpaper(ratios: String, atleast: String) async throws -> Wallpaper {
		clearCacheIfGlobalParamsChanged()

		let resolvedAtleast = avoidBlurryWallpapers ? atleast : ""
		let key = cacheKey(ratios: ratios, atleast: resolvedAtleast)
		let cached = cachedWallpapers[key] ?? []
		if let result = Self.selectWallpaper(from: cached, blocked: blockedIds) {
			cachedWallpapers[key] = result.remaining
			print("Using cached wallpaper for \(key): ID=\(result.selected.id)")
			return result.selected
		}

		return try await fetchNewWallpapers(ratios: ratios, atleast: resolvedAtleast, cacheKey: key)
	}

	private func cacheKey(ratios: String, atleast: String) -> String {
		"\(ratios)|\(atleast)|\(sorting.rawValue)|\(toplistRange.rawValue)|\(filterColor)|\(avoidBlurryWallpapers)"
	}

	private static let maxReseedAttempts = 5

	private func fetchNewWallpapers(ratios: String, atleast: String, cacheKey: String) async throws -> Wallpaper {
		/*
			Blocked wallpapers are filtered out *after* the fetch, so an entire page can come back fully blocked.
			Re-seed with a fresh seed a bounded number of times before giving up.
		*/
		for _ in 0..<Self.maxReseedAttempts {
			var fetched = try await rawFetch(ratios: ratios, atleast: atleast)

			// A raw fetch returning nothing is the genuine empty case — surface it immediately rather than burning re-seed attempts.
			if fetched.isEmpty {
				throw WallpaperError.noResults
			}

			fetched.shuffle()

			if let result = Self.selectWallpaper(from: fetched, blocked: blockedIds) {
				cachedWallpapers[cacheKey] = result.remaining
				return result.selected
			}

			print("All \(fetched.count) candidates for \(cacheKey) are blocked; re-seeding.")
		}

		throw WallpaperError.noResults
	}

	private func rawFetch(ratios: String, atleast: String) async throws -> [Wallpaper] {
		let categories: Set<WallhavenCategory> = if selectedCategories.isEmpty { [.general] } else { selectedCategories }

		let categoriesString = buildCategoriesString(categories)

		let parts = Self.keywords(from: searchQuery)
		let keywords: [String?] = if parts.isEmpty {
			[nil]
		} else {
			parts.map { Optional($0) }
		}

		let pageToFetch: Int
		if sorting == .random {
			pageToFetch = 1
		} else {
			if currentPage > lastPage {
				currentPage = 1
				pageToFetch = 1
			} else {
				pageToFetch = currentPage
			}
		}

		let requests: [URLRequest] = try keywords.map { keyword in
			var components = URLComponents(string: "\(baseURL)/search")!
			components.queryItems = buildQueryItems(keyword: keyword, categoriesString: categoriesString, ratios: ratios, atleast: atleast, page: pageToFetch)

			guard let url = components.url else {
				throw WallpaperError.invalidURL
			}

			var request = URLRequest(url: url)
			if !apiKey.isEmpty {
				request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
			}

			return request
		}

		var allWallpapers: [Wallpaper] = []
		struct TaskResult: Sendable { let data: [Wallpaper]; let meta: Meta }

		try await withThrowingTaskGroup(of: TaskResult.self) { group in
			for request in requests {
				group.addTask {
					let (data, response) = try await URLSession.shared.data(for: request)

					if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
						throw WallpaperError.httpError(httpResponse.statusCode)
					}

					let decoder = JSONDecoder()
					let wallhavenResponse = try decoder.decode(WallhavenResponse.self, from: data)

					return TaskResult(data: wallhavenResponse.data, meta: wallhavenResponse.meta)
				}
			}

			for try await result in group {
				allWallpapers.append(contentsOf: result.data)
				self.lastPage = result.meta.lastPage
			}
		}

		if sorting != .random {
			currentPage += 1
		}

		return allWallpapers
	}

	private func buildCategoriesString(_ categories: Set<WallhavenCategory>) -> String {
		WallhavenCategory.allCases.map { categories.contains($0) ? "1" : "0" }
			.joined()
	}

	private func buildQueryItems(keyword: String?, categoriesString: String, ratios: String, atleast: String, page: Int) -> [URLQueryItem] {
		var items: [URLQueryItem] = []

		if let keyword {
			items.append(URLQueryItem(name: "q", value: keyword))
		}

		items.append(contentsOf: [
			URLQueryItem(name: "categories", value: categoriesString),
			URLQueryItem(name: "purity", value: purityString),
			URLQueryItem(name: "sorting", value: sorting.rawValue),
			URLQueryItem(name: "page", value: String(page)),
			URLQueryItem(name: "ratios", value: ratios)
		])

		if sorting == .random {
			items.append(URLQueryItem(name: "seed", value: UUID().uuidString))
		}

		if sorting == .toplist {
			items.append(URLQueryItem(name: "topRange", value: toplistRange.rawValue))
		}

		if atleast != "" {
			items.append(URLQueryItem(name: "atleast", value: atleast))
		}

		if filterColor != "" {
			items.append(URLQueryItem(name: "colors", value: filterColor))
		}

		if !apiKey.isEmpty {
			items.append(URLQueryItem(name: "apikey", value: apiKey))
		}

		return items
	}
}
enum WallhavenSorting: String, CaseIterable, Identifiable {
	case random
	case date_added
	case views
	case favorites
	case toplist

	var id: String { rawValue }

	var label: String {
		switch self {
			case .random: return "Random"
			case .date_added: return "Date Added"
			case .views: return "Views"
			case .favorites: return "Favorites"
			case .toplist: return "Toplist"
		}
	}
}

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
