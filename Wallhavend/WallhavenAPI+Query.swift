import Foundation

extension WallhavenService {
	/// How far through one result list a sorting has walked.
	///
	/// Only the deterministic sortings use it — `random` re-seeds instead, and a fresh seed's page 1 is already a fresh sample.
	/// One cursor per cache key, because each ratio-and-size combination is a different list with a different depth: a 21x9 display's toplist is nowhere near as deep as a 16x9 one's.
	struct PageCursor: Equatable {
		/// The page the next fetch should ask for.
		var next = 1

		/// The deepest page this list is known to have. Starts optimistic at 1 and is corrected by the first response.
		var last = 1
	}

	/// Which page to ask for, given where the cursor stands.
	///
	/// Random always takes page 1 — its variety comes from the seed, and walking pages would only bias it toward the front of a random ordering.
	/// Everything else resumes where it left off, wrapping once it runs off the end so a short list keeps cycling instead of returning nothing forever.
	nonisolated static func pageToFetch(sorting: WallhavenSorting, cursor: PageCursor) -> Int {
		return if sorting == .random {
			1
		} else if cursor.next > cursor.last {
			1
		} else {
			cursor.next
		}
	}

	/// The cursor with `page` taken, recorded *before* the request goes out.
	///
	/// Claiming up front is what keeps an update tick and a pool fill on the same bucket from downloading the same page: they share a cache key, and both suspend on the network.
	nonisolated static func claiming(_ cursor: PageCursor, page: Int) -> PageCursor {
		PageCursor(next: page + 1, last: cursor.last)
	}

	/// The cursor once the responses have reported how deep their lists go, one `lastPage` per keyword request.
	///
	/// `max` rather than the first response's value: keywords have wildly different result counts, and letting a three-page keyword set the depth would wrap the cursor before a hundred-page one had been walked.
	/// The position is left alone — by the time this runs another fetch may have claimed a page, and that claim has to survive.
	nonisolated static func learning(_ cursor: PageCursor, lastPages: [Int]) -> PageCursor {
		PageCursor(next: cursor.next, last: lastPages.max() ?? cursor.last)
	}

	/// One request per keyword, every one of them aimed at the same page so the results line up as a single slice of the list.
	func buildRequests(ratios: String, atleast: String?, page: Int) throws -> [URLRequest] {
		let categories: Set<WallhavenCategory> = if selectedCategories.isEmpty { [.general] } else { selectedCategories }

		let categoriesString = buildCategoriesString(categories)

		let parts = Self.keywords(from: searchQuery)
		let keywords: [String?] = if parts.isEmpty {
			[nil]
		} else {
			parts.map { Optional($0) }
		}

		return try keywords.map { keyword in
			var components = URLComponents(string: "\(baseURL)/search")!
			components.queryItems = buildQueryItems(keyword: keyword, categoriesString: categoriesString, ratios: ratios, atleast: atleast, page: page)

			guard let url = components.url else {
				throw WallpaperError.invalidURL
			}

			var request = URLRequest(url: url)
			if !apiKey.isEmpty {
				request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
			}

			return request
		}
	}

	func buildCategoriesString(_ categories: Set<WallhavenCategory>) -> String {
		WallhavenCategory.allCases.map { categories.contains($0) ? "1" : "0" }
			.joined()
	}

	/// A `nil` `atleast` means the user turned off "Avoid blurry wallpapers", so the size floor is omitted rather than sent as an empty string.
	func buildQueryItems(keyword: String?, categoriesString: String, ratios: String, atleast: String?, page: Int) -> [URLQueryItem] {
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

		// A seed only means anything to random sorting, where it's what makes one page-1 fetch differ from the next.
		if sorting == .random {
			items.append(URLQueryItem(name: "seed", value: UUID().uuidString))
		}

		if sorting == .toplist {
			items.append(URLQueryItem(name: "topRange", value: toplistRange.rawValue))
		}

		if let atleast, !atleast.isEmpty {
			items.append(URLQueryItem(name: "atleast", value: atleast))
		}

		if !filterColor.isEmpty {
			items.append(URLQueryItem(name: "colors", value: filterColor))
		}

		if !apiKey.isEmpty {
			items.append(URLQueryItem(name: "apikey", value: apiKey))
		}

		return items
	}
}
