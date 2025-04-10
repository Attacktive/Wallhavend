import Foundation
import SwiftUI

struct WallhavenResponse: Codable {
	let data: [Wallpaper]
	let meta: Meta
}

struct Wallpaper: Codable {
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

struct Meta: Codable {
	let currentPage: Int
	let lastPage: Int
	let perPage: String
	let total: Int
	let query: String?

	enum CodingKeys: String, CodingKey {
		case currentPage = "current_page"
		case lastPage = "last_page"
		case perPage = "per_page"
		case total, query
	}

	var perPageInt: Int {
		Int(perPage) ?? 1
	}
}

enum WallhavenCategory: String, CaseIterable {
	case general
	case anime
	case people

	var code: String {
		switch self {
			case .general: return "1"
			case .anime: return "0"
			case .people: return "0"
		}
	}
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
	var ratios: String = "16x9"

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
			return "1920x1080" // Fallback if no screen is available
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
		if aspectRatio > 1 {
			// Landscape: fix height to screen height and calculate width
			let height = screenHeight
			let width = height * aspectRatio
			return "\(Int(width))x\(Int(height))"
		} else {
			// Portrait: fix width to screen width and calculate height
			let width = screenWidth
			let height = width / aspectRatio
			return "\(Int(width))x\(Int(height))"
		}
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
			let wallpaper = cachedWallpapers.removeFirst()
			print("Using cached wallpaper: ID=\(wallpaper.id), Resolution=\(wallpaper.resolution), Category=\(wallpaper.category), Type=\(wallpaper.fileType)")
			return wallpaper
		}

		// If we've used all cached wallpapers or have none, fetch new ones
		let categories = selectedCategories.isEmpty ? [.general] : selectedCategories
		let categoriesString = WallhavenCategory.allCases.map {
				categories.contains($0) ? "1" : "0"
			}
			.joined()

		let fullUUID = UUID().uuidString
		let seed = String(fullUUID.prefix(6))

		let keywords = searchQuery.split(separator: ",")
		let tagname = String(keywords[Int.random(in: 0..<keywords.count)])

		var queryItems = [
			"q": tagname.trimmingCharacters(in: .whitespacesAndNewlines),
			"categories": categoriesString,
			"purity": purityString,
			"sorting": "random",
			"seed": seed,
			"atleast": ratioResolution
		]

		if !ratios.isEmpty {
			queryItems["ratios"] = ratios
		}

		if !apiKey.isEmpty {
			queryItems["apikey"] = apiKey
		}

		var components = URLComponents(string: "\(baseURL)/search")!
		components.queryItems = queryItems.map {
			URLQueryItem(name: $0.key, value: $0.value)
		}

		print("Requesting URL: \(components.url!.absoluteString)")
		let (data, urlResponse) = try await URLSession(configuration: .ephemeral)
			.data(from: components.url!)

		guard let httpResponse = urlResponse as? HTTPURLResponse else {
			throw NSError(domain: "WallhavenService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response type"])
		}

		guard httpResponse.statusCode == 200 else {
			throw NSError(
				domain: "WallhavenService",
				code: httpResponse.statusCode,
				userInfo: [
					NSLocalizedDescriptionKey: "API request failed with status code \(httpResponse.statusCode)"
				]
			)
		}

		let apiResponse = try JSONDecoder().decode(WallhavenResponse.self, from: data)
		print("Got \(apiResponse.data.count) wallpapers")

		guard !apiResponse.data.isEmpty else {
			throw NSError(domain: "WallhavenService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No wallpapers found"])
		}

		// Cache the new wallpapers
		cachedWallpapers = apiResponse.data

		let wallpaper = cachedWallpapers.removeFirst()
		print("Selected wallpaper: ID=\(wallpaper.id), Resolution=\(wallpaper.resolution), Category=\(wallpaper.category), Type=\(wallpaper.fileType)")
		return wallpaper
	}
}
