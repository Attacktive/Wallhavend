import SwiftUI

struct ContentTab: View {
	@EnvironmentObject var wallhavenService: WallhavenService

	private var searchQueryBinding: Binding<String> {
		Binding(
			get: { wallhavenService.searchQuery },
			set: { wallhavenService.searchQuery = $0 }
		)
	}

	private var sfwBinding: Binding<Bool> {
		Binding(
			get: { wallhavenService.includeSFW },
			set: { wallhavenService.includeSFW = $0 }
		)
	}

	private var sketchyBinding: Binding<Bool> {
		Binding(
			get: { wallhavenService.includeSketchy },
			set: { wallhavenService.includeSketchy = $0 }
		)
	}

	private var nsfwBinding: Binding<Bool> {
		Binding(
			get: { wallhavenService.includeNSFW },
			set: { wallhavenService.includeNSFW = $0 }
		)
	}

	private func categoryBinding(_ category: WallhavenCategory) -> Binding<Bool> {
		Binding(
			get: { wallhavenService.selectedCategories.contains(category) },
			set: { isSelected in
				var categories = wallhavenService.selectedCategories
				if isSelected {
					categories.insert(category)
				} else {
					categories.remove(category)
				}

				wallhavenService.selectedCategories = categories
			}
		)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Search")
				.font(.headline)

			TextField("Search query (optional; delimit with a comma)", text: searchQueryBinding)
				.textFieldStyle(.roundedBorder)
		}

		HStack(alignment: .top, spacing: 32) {
			VStack(alignment: .leading, spacing: 8) {
				Text("Content Rating")
					.font(.headline)

				Toggle("SFW", isOn: sfwBinding)
				Toggle("Sketchy", isOn: sketchyBinding)
				Toggle("NSFW", isOn: nsfwBinding)
			}

			VStack(alignment: .leading, spacing: 8) {
				Text("Categories")
					.font(.headline)

				ForEach(WallhavenCategory.allCases, id: \.self) { category in
					Toggle(
						category.rawValue.capitalized,
						isOn: categoryBinding(category)
					)
				}
			}
		}
	}
}
