import SwiftUI

struct ContentView: View {
	@EnvironmentObject
	var wallpaperManager: WallpaperManager

	@EnvironmentObject
	var wallhavenService: WallhavenService

	@AppStorage("updateInterval")
	private var updateInterval: TimeInterval = 60

	@State private var selectedTab = 0

	var body: some View {
		VStack(spacing: 0) {
			Picker("", selection: $selectedTab) {
				Label("Content", systemImage: "magnifyingglass").tag(0)
				Label("Schedule", systemImage: "clock").tag(1)
				Label("Advanced", systemImage: "gearshape").tag(2)
				Label("Gallery", systemImage: "photo.on.rectangle").tag(3)
				Label("Blocked", systemImage: "hand.raised").tag(4)
			}
			.pickerStyle(.segmented)
			.padding()

			Divider()

			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					switch selectedTab {
						case 0: ContentTab()
						case 1: ScheduleTab()
						case 2: AdvancedTab()
						case 3: GalleryTab()
						default: BlockedTab()
					}
				}
				.padding()
			}
			.frame(maxWidth: .infinity)

			Divider()

			VStack(spacing: 8) {
				if !wallpaperManager.isOnline {
					Label("Offline", systemImage: "wifi.slash")
						.foregroundColor(.secondary)
						.font(.caption)
				}

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
					.disabled(!wallpaperManager.isOnline && !wallpaperManager.isRunning)

					Button("Update Now") {
						Task {
							await wallpaperManager.updateWallpaper()
						}
					}
					.buttonStyle(.borderedProminent)
					.disabled(!wallpaperManager.isOnline)

					Button("Show in Finder") {
						wallpaperManager.openStorageDirectoryInFinder()
					}
					.buttonStyle(.bordered)
				}

				if wallpaperManager.lastUpdated != nil {
					Text("Last updated: \(wallpaperManager.formattedLastUpdated)")
						.font(.caption)
				}
			}
			.padding()
		}
		.frame(minWidth: 320, minHeight: 300)
	}
}
