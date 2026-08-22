import SwiftUI

struct ContentTab: View {
	@EnvironmentObject var wallpaperManager: WallpaperManager
	@EnvironmentObject var wallhavenService: WallhavenService
	@EnvironmentObject var openverseService: OpenverseService

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

	private var licenseBinding: Binding<OpenverseLicenseFilter> {
		Binding(
			get: { openverseService.licenseFilter },
			set: { openverseService.licenseFilter = $0 }
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

	/// Every flip routes through `toggleKeepingOne`, so a refused removal leaves the stored set — and with it the checkbox — exactly where it was.
	private func sourceBinding(_ source: WallpaperSource) -> Binding<Bool> {
		Binding(
			get: { wallpaperManager.enabledSources.contains(source) },
			set: { _ in
				wallpaperManager.enabledSources = WallpaperSource.toggleKeepingOne(source, in: wallpaperManager.enabledSources)
			}
		)
	}

	private var isWallhavenEnabled: Bool {
		wallpaperManager.enabledSources.contains(.wallhaven)
	}

	private var isOpenverseEnabled: Bool {
		wallpaperManager.enabledSources.contains(.openverse)
	}

	/// The caption under Content Rating.
	///
	/// The three toggles are Wallhaven's purity bits, and Openverse understands only the NSFW one, which it maps onto allowing mature results (`OpenverseAPI.swift`).
	/// So the caption shows up only once Openverse is enabled — a Wallhaven-only install sees exactly the screen it saw before sources existed — and its job is to say which toggles the enabled sources actually read.
	static func contentRatingCaption(enabled: Set<WallpaperSource>) -> String? {
		guard enabled.contains(.openverse) else {
			return nil
		}

		return if enabled.contains(.wallhaven) {
			"Wallhaven honors all three. Openverse reads only NSFW, which lets mature results through."
		} else {
			"Openverse reads only NSFW, which lets mature results through — SFW and Sketchy apply to Wallhaven alone."
		}
	}

	private var contentRatingCaption: String? {
		Self.contentRatingCaption(enabled: wallpaperManager.enabledSources)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Sources")
				.font(.headline)

			ForEach(WallpaperSource.allCases, id: \.self) { source in
				Toggle(source.displayName, isOn: sourceBinding(source))
			}
		}

		VStack(alignment: .leading, spacing: 6) {
			Text("Search")
				.font(.headline)

			TextField("Search query (optional; delimit with , ; or |)", text: searchQueryBinding)
				.textFieldStyle(.roundedBorder)
		}

		if isWallhavenEnabled {
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

		VStack(alignment: .leading, spacing: 8) {
			Text("Content Rating")
				.font(.headline)

			Toggle("SFW", isOn: sfwBinding)
			Toggle("Sketchy", isOn: sketchyBinding)
			Toggle("NSFW", isOn: nsfwBinding)

			if let contentRatingCaption {
				Text(contentRatingCaption)
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}

		if isOpenverseEnabled {
			VStack(alignment: .leading, spacing: 6) {
				Text("License")
					.font(.headline)

				Picker("License", selection: licenseBinding) {
					ForEach(OpenverseLicenseFilter.allCases) { filter in
						Text(filter.label)
							.tag(filter)
					}
				}
				.labelsHidden()
				.pickerStyle(.radioGroup)

				Text("Public domain asks nothing of you. The wider tiers return more wallpapers but expect the creator to be credited if you reuse them.")
					.font(.caption)
					.foregroundColor(.secondary)
			}
		}
	}
}
