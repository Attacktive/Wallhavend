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

	private var sortingBinding: Binding<WallhavenSorting> {
		Binding(
			get: { wallhavenService.sorting },
			set: { wallhavenService.sorting = $0 }
		)
	}

	private var toplistRangeBinding: Binding<WallhavenToplistRange> {
		Binding(
			get: { wallhavenService.toplistRange },
			set: { wallhavenService.toplistRange = $0 }
		)
	}

	/// Sanitises on the way in rather than validating: the palette picker below is what says which values Wallhaven actually matches.
	private var filterColorBinding: Binding<String> {
		Binding(
			get: { wallhavenService.filterColor },
			set: { wallhavenService.filterColor = WallhavenColor.sanitized($0) }
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

	private var selectedColors: Set<String> {
		WallhavenColor.selection(from: wallhavenService.filterColor)
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

	/// One palette swatch. Tapping toggles it within the stored comma-joined list, so several colours can be active at once.
	private func swatch(_ hex: String) -> some View {
		let isSelected = selectedColors.contains(hex)
		let borderColor = if isSelected { Color.accentColor } else { Color.secondary.opacity(0.4) }
		let borderWidth: CGFloat = if isSelected { 3 } else { 1 }

		return Circle()
			.fill(Self.color(for: hex))
			.frame(width: 22, height: 22)
			.overlay(
				Circle()
					.strokeBorder(borderColor, lineWidth: borderWidth)
			)
			.contentShape(Circle())
			.onTapGesture {
				wallhavenService.filterColor = WallhavenColor.toggled(hex, in: wallhavenService.filterColor)
			}
			.help(hex)
	}

	private static func color(for hex: String) -> Color {
		guard let channels = WallhavenColor.channels(hex) else {
			return .clear
		}

		return Color(red: channels.red, green: channels.green, blue: channels.blue)
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
			VStack(alignment: .leading, spacing: 6) {
				Text("Sorting")
					.font(.headline)

				Picker("Sorting", selection: sortingBinding) {
					ForEach(WallhavenSorting.allCases) { sorting in
						Text(sorting.label)
							.tag(sorting)
					}
				}
				.labelsHidden()

				if wallhavenService.sorting == .toplist {
					Picker("Toplist Range", selection: toplistRangeBinding) {
						ForEach(WallhavenToplistRange.allCases) { range in
							Text(range.label)
								.tag(range)
						}
					}
					.labelsHidden()
				}
			}

			VStack(alignment: .leading, spacing: 6) {
				Text("Filter Color")
					.font(.headline)

				LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: 6)], alignment: .leading, spacing: 6) {
					ForEach(WallhavenColor.palette, id: \.self) { hex in
						swatch(hex)
					}
				}

				TextField("e.g. 000000 or 0066cc,ffffff (optional)", text: filterColorBinding)
					.textFieldStyle(.roundedBorder)

				Text("Wallhaven matches its own palette only, so an off-palette color quietly returns nothing. Pick swatches, or leave this blank to skip color filtering.")
					.font(.caption)
					.foregroundColor(.secondary)
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
