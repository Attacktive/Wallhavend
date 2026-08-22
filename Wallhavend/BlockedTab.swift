import SwiftUI

struct BlockedTab: View {
	@EnvironmentObject var wallhavenService: WallhavenService

	private var blockedIds: [String] {
		wallhavenService.blockedIds.sorted()
	}

	var body: some View {
		if blockedIds.isEmpty {
			VStack(spacing: 8) {
				Image(systemName: "hand.raised")
					.font(.system(size: 40))
					.foregroundColor(.secondary)

				Text("No blocked wallpapers")
					.font(.headline)

				Text("Block a wallpaper from the Gallery to keep it from coming back")
					.font(.caption)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 40)
		} else {
			VStack(alignment: .leading, spacing: 8) {
				ForEach(blockedIds, id: \.self) { id in
					BlockedRow(id: id)
				}
			}
		}
	}
}

private struct BlockedRow: View {
	@EnvironmentObject var wallhavenService: WallhavenService
	let id: String

	@State private var revealed = false

	/// The blocked id is a bare filename stem, so the source and its URLs come from parsing it rather than from any stored field.
	private var identity: WallpaperIdentity {
		WallpaperIdentity.parse(stem: id)
	}

	var body: some View {
		HStack(spacing: 12) {
			thumbnail
				.frame(width: 80, height: 50)
				.clipShape(RoundedRectangle(cornerRadius: 4))
				.contentShape(Rectangle())
				.onTapGesture {
					revealed = true
				}

			// The bare id rather than the stored stem: `openverse_` in front of a 36-character UUID crowds the row and repeats what the source line already says.
			VStack(alignment: .leading, spacing: 2) {
				if let pageURL = identity.pageURL {
					Link(identity.id, destination: pageURL)
						.font(.system(.body, design: .monospaced))
				} else {
					Text(identity.id)
						.font(.system(.body, design: .monospaced))
				}

				Text(identity.source.displayName)
					.font(.caption)
					.foregroundColor(.secondary)
			}

			Spacer()

			Button("Unblock") {
				wallhavenService.unblock(id)
			}
		}
		.padding(.vertical, 4)
	}

	@ViewBuilder
	private var thumbnail: some View {
		// Tap-to-reveal: blocking is often driven by revulsion, so never re-expose the image until the user explicitly asks for it.
		if revealed, let thumbnailURL = identity.thumbnailURL {
			AsyncImage(url: thumbnailURL) { image in
				image
					.resizable()
					.scaledToFill()
			} placeholder: {
				ProgressView()
			}
		} else {
			ZStack {
				Color(NSColor.windowBackgroundColor)
				Image(systemName: "eye.slash")
					.foregroundColor(.secondary)
			}
		}
	}
}
