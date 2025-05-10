import SwiftUI

struct ContentView: View {
	private var autoScalingBinding: Binding<Bool> {
		Binding(
			get: { wallpaperManager.autoScaling },
			set: { wallpaperManager.autoScaling = $0 }
		)
	}
	@EnvironmentObject
	var wallpaperManager: WallpaperManager

	@EnvironmentObject
	var wallhavenService: WallhavenService

	@AppStorage("updateInterval")
	private var updateInterval: TimeInterval = 60

	@AppStorage("startAutoUpdateOnLaunch")
	private var startAutoUpdateOnLaunch: Bool = false

	var body: some View {
		VStack(spacing: 20) {
			Text("Wallhavend")
				.font(.largeTitle)
				.padding()

			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					GroupBox("Search") {
						TextField("Search query (optional; delimit with a comma)", text: searchQueryBinding)
							.textFieldStyle(.roundedBorder)
							.padding(.vertical, 4)
					}

					GroupBox("Content Filters") {
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
						.padding(.vertical, 4)
					}

					GroupBox("Settings") {
						VStack(alignment: .leading, spacing: 12) {
							Text("Wallpaper Scaling")
								.font(.headline)

							VStack(alignment: .leading, spacing: 8) {
								Toggle("Automatic", isOn: autoScalingBinding)
								if !wallpaperManager.autoScaling {
									Picker("Scaling Mode", selection: $wallpaperManager.manualScaling) {
										Text("Fill Screen").tag(NSImageScaling.scaleAxesIndependently)
										Text("Fit to Screen").tag(NSImageScaling.scaleProportionallyUpOrDown)
									}
									.pickerStyle(.radioGroup)
									.padding(.leading)
								}
							}
							.padding(.bottom, 8)

							TextField(
								"Aspect Ratio (e.g. 16x9)",
								text: ratiosBinding
							)
							.textFieldStyle(.roundedBorder)
							.font(.system(.body, design: .monospaced))

							SecureField(
								"API Key (optional)",
								text: apiKeyBinding
							)
							.textFieldStyle(.roundedBorder)
							.font(.system(.body, design: .monospaced))
						}
						.padding(.vertical, 4)
					}

					GroupBox("Auto Update") {
						Picker("Update interval", selection: $updateInterval) {
							ForEach(intervals, id: \.seconds) { interval in
								Text(interval.label)
									.tag(interval.seconds)
							}
						}
						.pickerStyle(.menu)
						.padding(.vertical, 4)

						Toggle("Start automatically on launch", isOn: $startAutoUpdateOnLaunch)
							.padding(.vertical, 4)
					}
				}
				.padding(.horizontal)
			}
			.frame(maxWidth: .infinity)
			.background(Color(NSColor.controlBackgroundColor))

			if let error = wallpaperManager.error {
				Text(error)
					.foregroundColor(.red)
					.font(.caption)
					.lineLimit(2)
					.multilineTextAlignment(.center)
			}

			HStack(spacing: 20) {
				Button(wallpaperManager.isRunning ? "Stop Auto Update" : "Start Auto Update") {
					if wallpaperManager.isRunning {
						wallpaperManager.stopAutoUpdate()
					} else {
						wallpaperManager.startAutoUpdate(interval: updateInterval)
					}
				}
				.buttonStyle(.borderedProminent)

				Button("Update Now") {
					Task {
						await wallpaperManager.updateWallpaper()
					}
				}
				.buttonStyle(.borderedProminent)
			}

			if wallpaperManager.lastUpdated != nil {
				Text("Last updated: \(wallpaperManager.formattedLastUpdated)")
					.font(.caption)
			}

			if let url = wallpaperManager.currentWallpaperURL {
				Button {
					NSWorkspace.shared.open(url)
				} label: {
					HStack(spacing: 4) {
						Text("Current wallpaper:")
							.foregroundColor(.secondary)

						Text(url.absoluteString)
							.foregroundColor(.accentColor)
					}
					.font(.caption)
					.lineLimit(1)
					.truncationMode(.middle)
					.multilineTextAlignment(.leading)
				}
				.buttonStyle(.link)
				.disabled(!wallpaperManager.hasCurrentWallpaper)
				.onHover { inside in
					if inside {
						NSCursor.pointingHand.push()
					} else {
						NSCursor.pop()
					}
				}

				Button("Locate in Finder") {
					wallpaperManager.revealCurrentWallpaperInFinder()
				}
				.disabled(!wallpaperManager.hasCurrentWallpaper)
			}
		}
		.frame(minWidth: 240, minHeight: 650)
		.padding()
	}

	private let intervals: [(label: String, seconds: TimeInterval)] = [
		("1 minute", 60),
		("5 minutes", 300),
		("15 minutes", 900),
		("30 minutes", 1800),
		("1 hour", 3600),
		("2 hours", 7200),
		("6 hours", 21600),
		("12 hours", 43200),
		("24 hours", 86400)
	]

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

	private var ratiosBinding: Binding<String> {
		Binding(
			get: { wallhavenService.ratios },
			set: { wallhavenService.ratios = $0 }
		)
	}

	private var apiKeyBinding: Binding<String> {
		Binding(
			get: { wallhavenService.apiKey },
			set: { wallhavenService.apiKey = $0 }
		)
	}
}
