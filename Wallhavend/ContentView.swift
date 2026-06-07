import SwiftUI
import ImageIO

struct ContentView: View {
	@EnvironmentObject
	var wallpaperManager: WallpaperManager

	@EnvironmentObject
	var wallhavenService: WallhavenService

	@AppStorage("updateInterval")
	private var updateInterval: TimeInterval = 60

	@State private var selectedTab = 0
	private let tabs = ["Content", "Schedule", "Advanced", "Gallery"]

	var body: some View {
		VStack(spacing: 0) {
			Picker("", selection: $selectedTab) {
				ForEach(tabs.indices, id: \.self) { index in
					Text(tabs[index]).tag(index)
				}
			}
			.pickerStyle(.segmented)
			.padding([.horizontal, .top])
			.padding(.bottom, 8)

			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					switch selectedTab {
					case 0: ContentTab()
					case 1: ScheduleTab()
					case 2: AdvancedTab()
					default: GalleryTab()
					}
				}
				.padding(.horizontal)
				.padding(.bottom, 16)
			}
			.frame(maxWidth: .infinity)
			.background(Color(NSColor.controlBackgroundColor))

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

private struct ContentTab: View {
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
		GroupBox {
			TextField("Search query (optional; delimit with a comma)", text: searchQueryBinding)
				.textFieldStyle(.roundedBorder)
				.padding(.vertical, 4)
		} label: {
			Text("Search").font(.system(size: 15, weight: .semibold))
		}

		GroupBox {
			VStack(alignment: .leading, spacing: 8) {
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
			.padding(.vertical, 4)
		} label: {
			Text("Content Filters").font(.system(size: 15, weight: .semibold))
		}
	}
}

private struct ScheduleTab: View {
	@EnvironmentObject var wallpaperManager: WallpaperManager

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
		GroupBox {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Text("Update interval")
					Spacer()
					Picker("", selection: $updateInterval) {
						ForEach(intervals, id: \.seconds) { interval in
							Text(interval.label)
								.tag(interval.seconds)
						}
					}
					.labelsHidden()
					.pickerStyle(.menu)
					.fixedSize()
				}

				Toggle("Start automatically on launch", isOn: $startAutoUpdateOnLaunch)
			}
			.padding(.vertical, 4)
		} label: {
			Text("Auto Update").font(.system(size: 15, weight: .semibold))
		}
	}
}

private struct AdvancedTab: View {
	@EnvironmentObject var wallpaperManager: WallpaperManager
	@EnvironmentObject var wallhavenService: WallhavenService

	private var poolSizeBinding: Binding<Int> {
		Binding(
			get: { wallpaperManager.poolSize },
			set: { wallpaperManager.poolSize = $0 }
		)
	}

	private var apiKeyBinding: Binding<String> {
		Binding(
			get: { wallhavenService.apiKey },
			set: { wallhavenService.apiKey = $0 }
		)
	}

	var body: some View {
		GroupBox {
			VStack(alignment: .leading, spacing: 4) {
				Picker("Pool size", selection: poolSizeBinding) {
					Text("Current only").tag(0)
					Text("5").tag(5)
					Text("10").tag(10)
					Text("25").tag(25)
				}
				.pickerStyle(.segmented)

				Text("Wallpapers kept on device and shown in Gallery tab")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.padding(.vertical, 4)
		} label: {
			Text("Wallpaper Pool").font(.system(size: 15, weight: .semibold))
		}

		GroupBox {
			SecureField("Your Wallhaven API key (optional)", text: apiKeyBinding)
				.textFieldStyle(.roundedBorder)
				.font(.system(.body, design: .monospaced))
				.padding(.vertical, 4)
		} label: {
			Text("API Key").font(.system(size: 15, weight: .semibold))
		}
	}
}

private struct GalleryTab: View {
	@EnvironmentObject var wallpaperManager: WallpaperManager

	private var nonEmptyBuckets: [AspectBucket] {
		AspectBucket.allCases.filter { bucket in
			(wallpaperManager.poolsByBucket[bucket.rawValue]?.isEmpty == false)
		}
	}

	var body: some View {
		if nonEmptyBuckets.isEmpty {
			VStack(spacing: 8) {
				Image(systemName: "photo.on.rectangle.angled")
					.font(.system(size: 40))
					.foregroundColor(.secondary)

				Text("No wallpapers in pool yet")
					.font(.headline)

				Text("Download a wallpaper to start filling the gallery")
					.font(.caption)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 40)
		} else {
			VStack(alignment: .leading, spacing: 16) {
				ForEach(nonEmptyBuckets, id: \.self) { bucket in
					GalleryBucketSection(bucket: bucket)
				}
			}
		}
	}
}

private struct GalleryBucketSection: View {
	@EnvironmentObject var wallpaperManager: WallpaperManager
	let bucket: AspectBucket

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(bucket.label)
				.font(.headline)

			LazyVGrid(
				columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
				spacing: 4
			) {
				ForEach(wallpaperManager.poolsByBucket[bucket.rawValue] ?? [], id: \.self) { url in
					WallpaperThumbnailView(
						url: url,
						bucket: bucket.rawValue,
						isCurrent: url == wallpaperManager.currentByBucket[bucket.rawValue]
					)
				}
			}
		}
	}
}

private struct WallpaperThumbnailView: View {
	@EnvironmentObject var wallpaperManager: WallpaperManager
	let url: URL
	let bucket: String
	let isCurrent: Bool

	@State private var nsImage: NSImage?

	var body: some View {
		Group {
			if let nsImage {
				Image(nsImage: nsImage)
					.resizable()
					.scaledToFill()
			} else {
				Color(NSColor.windowBackgroundColor)
			}
		}
		.frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
		.clipShape(RoundedRectangle(cornerRadius: 4))
		.overlay(
			RoundedRectangle(cornerRadius: 4)
				.stroke(Color.red, lineWidth: isCurrent ? 2 : 0)
		)
		.contentShape(Rectangle())
		.onTapGesture {
			Task { await wallpaperManager.applyFromPool(url: url, bucket: bucket) }
		}
		.contextMenu {
			Button("Locate in Finder") {
				wallpaperManager.revealInFinder(url: url)
			}

			Button("Copy Wallhaven URL") {
				wallpaperManager.copyWallhavenURL(for: url)
			}

			Divider()

			Button("Delete from pool", role: .destructive) {
				wallpaperManager.deleteFromPool(url: url, bucket: bucket)
			}
		}
		.task(id: url) {
			let loadTask = Task.detached(priority: .userInitiated) {
				let options: [CFString: Any] = [
					kCGImageSourceCreateThumbnailFromImageAlways: true,
					kCGImageSourceThumbnailMaxPixelSize: 300,
					kCGImageSourceCreateThumbnailWithTransform: true
				]

				guard
					let source = CGImageSourceCreateWithURL(url as CFURL, nil),
					let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
				else {
					return nil as NSImage?
				}

				return NSImage(cgImage: cgImage, size: .zero)
			}

			nsImage = await loadTask.value
		}
	}
}
