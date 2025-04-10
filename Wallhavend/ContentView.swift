import SwiftUI

struct ContentView: View {
	@EnvironmentObject
	var wallpaperManager: WallpaperManager

	@EnvironmentObject
	var wallhavenService: WallhavenService

	@AppStorage("updateInterval")
	private var updateInterval: TimeInterval = 60

	@AppStorage("startAutoUpdateOnLaunch")
	private var startAutoUpdateOnLaunch: Bool = false

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

	var body: some View {
		VStack(spacing: 20) {
			Text("Wallhavend")
				.font(.largeTitle)
				.padding()

			ScrollView {
				VStack(spacing: 16) {
					GroupBox("Search") {
						TextField(
							"Search query (optional; delimit with a comma)",
							text: Binding(
								get: { wallhavenService.searchQuery },
								set: { wallhavenService.searchQuery = $0 }
							))
							.textFieldStyle(.roundedBorder)
							.padding(.vertical, 4)
					}

					GroupBox("Content Filters") {
						HStack(alignment: .top, spacing: 32) {
							VStack(alignment: .leading, spacing: 8) {
								Text("Content Rating")
									.font(.headline)

								Toggle(
									"SFW",
									isOn: Binding(
										get: { wallhavenService.includeSFW },
										set: { wallhavenService.includeSFW = $0 }
									))

								Toggle(
									"Sketchy",
									isOn: Binding(
										get: { wallhavenService.includeSketchy },
										set: { wallhavenService.includeSketchy = $0 }
									))

								Toggle(
									"NSFW",
									isOn: Binding(
										get: { wallhavenService.includeNSFW },
										set: { wallhavenService.includeNSFW = $0 }
									))
							}

							VStack(alignment: .leading, spacing: 8) {
								Text("Categories")
									.font(.headline)

								ForEach(WallhavenCategory.allCases, id: \.self) { category in
									Toggle(
										category.rawValue.capitalized,
										isOn: Binding(
											get: { wallhavenService.selectedCategories.contains(category) },
											set: { isSelected in
												if isSelected {
													wallhavenService.selectedCategories.insert(category)
												} else {
													wallhavenService.selectedCategories.remove(category)
												}
											}
										)
									)
								}
							}
						}
						.padding(.vertical, 4)
					}

					GroupBox("Settings") {
						VStack(alignment: .leading, spacing: 12) {
							TextField(
								"Aspect Ratio (e.g. 16x9)",
								text: Binding(
									get: { wallhavenService.ratios },
									set: { wallhavenService.ratios = $0 }
								))
								.textFieldStyle(.roundedBorder)
								.font(.system(.body, design: .monospaced))

							SecureField(
								"API Key (optional)",
								text: Binding(
									get: { wallhavenService.apiKey },
									set: { wallhavenService.apiKey = $0 }
								))
								.textFieldStyle(.roundedBorder)
								.font(.system(.body, design: .monospaced))
						}
						.padding(.vertical, 4)
					}

					GroupBox("Auto Update") {
						Picker("Update interval", selection: $updateInterval) {
							ForEach(intervals, id: \.seconds) { interval in
								Text(interval.label).tag(interval.seconds)
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
}
