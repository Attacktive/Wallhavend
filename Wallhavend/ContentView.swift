import SwiftUI

struct ContentView: View {
	@EnvironmentObject var wallpaperManager: WallpaperManager
	@EnvironmentObject var wallhavenService: WallhavenService

	@AppStorage("updateInterval")
	private var updateInterval: TimeInterval = 60

	@State private var selectedTab = 0

	/// Auto-update can run offline in Pinned-only mode (it never downloads), so don't gate it on connectivity there.
	private var canStartAutoUpdate: Bool {
		wallpaperManager.isOnline || wallpaperManager.isRunning || wallpaperManager.rotationMode == .pinnedOnly
	}

	/// Credits for the sources wallpapers can currently arrive from, in a fixed order so they don't reshuffle as the set changes.
	/// Openverse's terms require its line for as long as its wallpapers can show up, which is exactly while it's enabled.
	private var attributedSources: [WallpaperSource] {
		WallpaperSource.allCases.filter { wallpaperManager.enabledSources.contains($0) }
	}

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
							wallpaperManager.stopAutoUpdateExplicitly()
						} else {
							wallpaperManager.startAutoUpdateExplicitly(interval: updateInterval)
						}
					}
					.buttonStyle(.borderedProminent)
					.disabled(!canStartAutoUpdate)

					Button {
						wallpaperManager.requestManualUpdate()
					} label: {
						if wallpaperManager.isUpdating {
							HStack(spacing: 6) {
								ProgressView().controlSize(.small)
								Text("Updating…")
							}
						} else {
							Text("Update Wallpaper Now")
						}
					}
					.buttonStyle(.borderedProminent)
					.disabled(!wallpaperManager.canUpdateNow)

					Button("Show in Finder") {
						wallpaperManager.openStorageDirectoryInFinder()
					}
					.buttonStyle(.bordered)
				}

				if wallpaperManager.lastUpdated != nil {
					Text("Last updated: \(wallpaperManager.formattedLastUpdated)")
						.font(.caption)
				}

				ForEach(attributedSources, id: \.self) { source in
					if let homeURL = source.homeURL {
						Link(source.attribution, destination: homeURL)
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}
			.padding()
		}
		.frame(minWidth: 500, minHeight: 480)
	}
}
