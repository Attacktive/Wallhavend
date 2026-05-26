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
		// perPage can be Int or String depending on the API version; skip it
		// query can be String, null, or {"id":…,"tag":…} for tag searches; skip it
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
	private var selectedCategoriesRaw: String = "general" // Store as comma-separated string

	@AppStorage("apiKey")
	var apiKey: String = ""

	@AppStorage("ratios")
	var ratios: String = ""

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

	var ratioResolution: String {
		// Parse ratio like "16x9" or "21:9" into width and height multipliers
		let parts = ratios.lowercased()
			.replacingOccurrences(of: ":", with: "x")
			.split(separator: "x")
			.compactMap {
				Double($0.trimmingCharacters(in: .whitespaces))
			}

		guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
			// If no valid ratio is provided, use the main screen's resolution
			if let screen = NSScreen.main {
				let frame = screen.frame
				return "\(Int(frame.width))x\(Int(frame.height))"
			}

			return "1920x1080"
		}

		let aspectRatio = parts[0] / parts[1]

		// Get the main screen's resolution
		let screenHeight: Double
		let screenWidth: Double
		if let screen = NSScreen.main {
			let frame = screen.frame
			screenWidth = frame.width
			screenHeight = frame.height
		} else {
			screenWidth = 1920
			screenHeight = 1080
		}

		// Use screen resolution as the base, maintaining the user's desired aspect ratio
		let (width, height): (Double, Double)
		if aspectRatio > 1 {
			width = screenHeight * aspectRatio
			height = screenHeight
		} else {
			width = screenWidth
			height = screenWidth / aspectRatio
		}

		return "\(Int(width))x\(Int(height))"
	}

	private var cachedWallpapers: [Wallpaper] = []
	private var lastSearchParams: SearchParams?

	private struct SearchParams: Equatable {
		let categories: Set<WallhavenCategory>
		let purity: String
		let ratios: String
		let searchQuery: String
		let apiKey: String
	}

	private func shouldInvalidateCache() -> Bool {
		let currentParams = SearchParams(
			categories: selectedCategories,
			purity: purityString,
			ratios: ratios,
			searchQuery: searchQuery,
			apiKey: apiKey
		)

		if lastSearchParams != currentParams {
			lastSearchParams = currentParams
			return true
		}

		return false
	}

	func fetchRandomWallpaper() async throws -> Wallpaper {
		// Check if we need to invalidate cache due to parameter changes
		if shouldInvalidateCache() {
			cachedWallpapers.removeAll()
			print("Cache invalidated due to search parameter changes")
		}

		// If we have cached wallpapers, take one from it
		if !cachedWallpapers.isEmpty {
			return getNextCachedWallpaper()
		}

		return try await fetchNewWallpapers()
	}

	private func getNextCachedWallpaper() -> Wallpaper {
		let wallpaper = cachedWallpapers.removeFirst()
		print("Using cached wallpaper: ID=\(wallpaper.id), Resolution=\(wallpaper.resolution), Category=\(wallpaper.category), Type=\(wallpaper.fileType)")
		return wallpaper
	}

	private func fetchNewWallpapers() async throws -> Wallpaper {
		let categories = selectedCategories.isEmpty ? [.general] : selectedCategories
		let categoriesString = buildCategoriesString(categories)

		var components = URLComponents(string: "\(baseURL)/search")!
		components.queryItems = buildQueryItems(categoriesString)

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

		cachedWallpapers = apiResponse.data

		return getNextCachedWallpaper()
	}

	private func buildCategoriesString(_ categories: Set<WallhavenCategory>) -> String {
		WallhavenCategory.allCases.map {
				categories.contains($0) ? "1" : "0"
		}
		.joined()
	}

	func isRatioSelected(_ ratio: String) -> Bool {
		ratios
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.contains(ratio)
	}

	func toggleRatio(_ ratio: String) {
		var parts = ratios
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }

		if let index = parts.firstIndex(of: ratio) {
			parts.remove(at: index)
		} else {
			parts.append(ratio)
		}

		ratios = parts.joined(separator: ",")
	}

	private func buildQueryItems(_ categoriesString: String) -> [URLQueryItem] {
		var items = [
			URLQueryItem(name: "q", value: searchQuery),
			URLQueryItem(name: "categories", value: categoriesString),
			URLQueryItem(name: "purity", value: purityString),
			URLQueryItem(name: "sorting", value: "random"),
			URLQueryItem(name: "seed", value: UUID().uuidString),
			URLQueryItem(name: "atleast", value: ratioResolution)
		]

		if !ratios.isEmpty {
			items.append(URLQueryItem(name: "ratios", value: ratios))
		}

		if !apiKey.isEmpty {
			items.append(URLQueryItem(name: "apikey", value: apiKey))
		}

		return items
	}
}
