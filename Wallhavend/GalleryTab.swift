import SwiftUI
import ImageIO

struct GalleryTab: View {
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
	@EnvironmentObject var wallhavenService: WallhavenService

	let url: URL
	let bucket: String
	let isCurrent: Bool

	@State private var nsImage: NSImage?

	private var isPinned: Bool {
		wallhavenService.pinnedIds.contains(wallpaperManager.wallpaperId(for: url))
	}

	var body: some View {
		Group {
			if let nsImage {
				Image(nsImage: nsImage)
					.resizable()
					.scaledToFill()
			} else {
				Color(NSColor.controlBackgroundColor)
			}
		}
		.frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
		.clipShape(RoundedRectangle(cornerRadius: 4))
		.overlay(
			RoundedRectangle(cornerRadius: 4)
				.stroke(Color.red, lineWidth: isCurrent ? 2 : 0)
		)
		.overlay(alignment: .topTrailing) {
			if isPinned {
				Image(systemName: "pin.fill")
					.font(.system(size: 9, weight: .bold))
					.foregroundColor(.white)
					.padding(3)
					.background(Circle().fill(Color.accentColor))
					.padding(3)
			}
		}
		.contentShape(Rectangle())
		.onTapGesture {
			Task { await wallpaperManager.applyFromPool(url: url, bucket: bucket) }
		}
		.contextMenu {
			Button(isPinned ? "Unpin" : "Pin") {
				wallpaperManager.togglePin(url: url)
			}

			Divider()

			Button("Locate in Finder") {
				wallpaperManager.revealInFinder(url: url)
			}

			Button("Copy Wallhaven URL") {
				wallpaperManager.copyWallhavenURL(for: url)
			}

			Divider()

			Button("Block this wallpaper", role: .destructive) {
				Task { await wallpaperManager.blockWallpaper(url: url) }
			}

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
