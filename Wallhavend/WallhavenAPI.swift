import Foundation
import SwiftUI

struct WallhavenResponse: Decodable {
	let data: [Wallpaper]
	let meta: Meta
}

struct Wallpaper: Decodable {
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

struct Meta: Decodable {
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
			Set(selectedCategoriesRaw.split(separator: ",")
				.compactMap {
					WallhavenCategory(rawValue: String($0))
				}
			)
		}
		set {
			selectedCategoriesRaw = newValue.map {
					$0.rawValue
				}
				.joined(separator: ",")
		}
	}

	var blockedIds: Set<String> {
		get {
			Set(blockedIdsRaw.split(separator: ",")
				.map {
					String($0)
				}
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
			Set(pinnedIdsRaw.split(separator: ",")
				.map {
					String($0)
				}
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
	}

	private var cachedWallpapers: [String: [Wallpaper]] = [:]
	private var lastGlobalParams: GlobalParams?

	private func clearCacheIfGlobalParamsChanged() {
		let current = GlobalParams(
			categories: selectedCategories,
			purity: purityString,
			searchQuery: searchQuery,
			apiKey: apiKey
		)

		if lastGlobalParams != current {
			cachedWallpapers.removeAll()
			lastGlobalParams = current
			print("Wallhaven cache invalidated (global params changed).")
		}
	}

	func fetchRandomWallpaper(ratios: String, atleast: String) async throws -> Wallpaper {
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

	private func cacheKey(ratios: String, atleast: String) -> String {
		"\(ratios)|\(atleast)"
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
		let categories = selectedCategories.isEmpty ? [.general] : selectedCategories
		let categoriesString = buildCategoriesString(categories)

		let keywords: [String?] = {
			let parts = searchQuery
				.components(separatedBy: CharacterSet(charactersIn: ",;| ").union(.whitespacesAndNewlines))
				.filter { !$0.isEmpty }

			return parts.isEmpty ? [nil] : parts.map { Optional($0) }
		}()

		let requests: [URLRequest] = try keywords.map { keyword in
			var components = URLComponents(string: "\(baseURL)/search")!
			components.queryItems = buildQueryItems(keyword: keyword, categoriesString: categoriesString, ratios: ratios, atleast: atleast)

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

		try await withThrowingTaskGroup(of: [Wallpaper].self) { group in
			for request in requests {
				group.addTask {
					let (data, response) = try await URLSession.shared.data(for: request)

					if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
						throw WallpaperError.httpError(httpResponse.statusCode)
					}

					return try JSONDecoder().decode(WallhavenResponse.self, from: data).data
				}
			}

			for try await wallpapers in group {
				allWallpapers.append(contentsOf: wallpapers)
			}
		}

		return allWallpapers
	}

	private func buildCategoriesString(_ categories: Set<WallhavenCategory>) -> String {
		WallhavenCategory.allCases.map {
				categories.contains($0) ? "1" : "0"
		}
		.joined()
	}

	private func buildQueryItems(keyword: String?, categoriesString: String, ratios: String, atleast: String) -> [URLQueryItem] {
		var items: [URLQueryItem] = []

		if let keyword {
			items.append(URLQueryItem(name: "q", value: keyword))
		}

		items.append(contentsOf: [
			URLQueryItem(name: "categories", value: categoriesString),
			URLQueryItem(name: "purity", value: purityString),
			URLQueryItem(name: "sorting", value: "random"),
			URLQueryItem(name: "seed", value: UUID().uuidString),
			URLQueryItem(name: "atleast", value: atleast),
			URLQueryItem(name: "ratios", value: ratios)
		])

		if !apiKey.isEmpty {
			items.append(URLQueryItem(name: "apikey", value: apiKey))
		}

		return items
	}
}
