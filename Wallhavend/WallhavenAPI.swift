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
		if var cached = cachedWallpapers[key], !cached.isEmpty {
			let next = cached.removeFirst()
			cachedWallpapers[key] = cached
			print("Using cached wallpaper for \(key): ID=\(next.id)")
			return next
		}

		return try await fetchNewWallpapers(ratios: ratios, atleast: atleast, cacheKey: key)
	}

	private func cacheKey(ratios: String, atleast: String) -> String {
		"\(ratios)|\(atleast)"
	}

	private func fetchNewWallpapers(ratios: String, atleast: String, cacheKey: String) async throws -> Wallpaper {
		let categories = selectedCategories.isEmpty ? [.general] : selectedCategories
		let categoriesString = buildCategoriesString(categories)

		var components = URLComponents(string: "\(baseURL)/search")!
		components.queryItems = buildQueryItems(
			categoriesString: categoriesString,
			ratios: ratios,
			atleast: atleast
		)

		guard let url = components.url else {
			throw WallpaperError.invalidURL
		}

		var request = URLRequest(url: url)
		if !apiKey.isEmpty {
			request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
		}

		let (data, response) = try await URLSession.shared.data(for: request)

		if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
			throw WallpaperError.httpError(httpResponse.statusCode)
		}

		let apiResponse = try JSONDecoder().decode(WallhavenResponse.self, from: data)

		if apiResponse.data.isEmpty {
			throw WallpaperError.noResults
		}

		var pool = apiResponse.data
		let first = pool.removeFirst()
		cachedWallpapers[cacheKey] = pool
		return first
	}

	private func buildCategoriesString(_ categories: Set<WallhavenCategory>) -> String {
		WallhavenCategory.allCases.map {
				categories.contains($0) ? "1" : "0"
		}
		.joined()
	}

	private func buildQueryItems(categoriesString: String, ratios: String, atleast: String) -> [URLQueryItem] {
		var items = [
			URLQueryItem(name: "q", value: searchQuery),
			URLQueryItem(name: "categories", value: categoriesString),
			URLQueryItem(name: "purity", value: purityString),
			URLQueryItem(name: "sorting", value: "random"),
			URLQueryItem(name: "seed", value: UUID().uuidString),
			URLQueryItem(name: "atleast", value: atleast),
			URLQueryItem(name: "ratios", value: ratios)
		]

		if !apiKey.isEmpty {
			items.append(URLQueryItem(name: "apikey", value: apiKey))
		}

		return items
	}
}
