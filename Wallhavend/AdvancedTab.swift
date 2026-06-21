import SwiftUI

struct AdvancedTab: View {
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

	private var hasPins: Bool {
		!wallhavenService.pinnedIds.isEmpty
	}

	private var rotationModeBinding: Binding<RotationMode> {
		Binding(
			get: { hasPins ? wallpaperManager.rotationMode : .fresh },
			set: { wallpaperManager.rotationMode = ($0 == .pinnedOnly && !hasPins) ? .fresh : $0 }
		)
	}

	private var rotationCaption: String {
		if hasPins {
			return "Fresh downloads new wallpapers (and rotates your pool when offline). Pinned only never downloads — it cycles just your pinned wallpapers. “Update Now” always fetches a fresh one."
		} else {
			return "Fresh downloads new wallpapers (and rotates your pool when offline). Pin a wallpaper to enable Pinned only."
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Rotation")
				.font(.headline)

			Picker("Rotation", selection: rotationModeBinding) {
				ForEach(RotationMode.allCases) { mode in
					Text(mode.label)
						.tag(mode)
						.disabled(mode == .pinnedOnly && !hasPins)
				}
			}
			.labelsHidden()
			.pickerStyle(.radioGroup)

			Text(rotationCaption)
				.font(.caption)
				.foregroundColor(.secondary)
		}

		VStack(alignment: .leading, spacing: 6) {
			Text("Wallpaper Pool")
				.font(.headline)

			Picker("Pool size", selection: poolSizeBinding) {
				Text("Current only").tag(1)
				Text("5").tag(5)
				Text("10").tag(10)
				Text("25").tag(25)
			}
			.labelsHidden()
			.pickerStyle(.segmented)

			Text("Wallpapers kept on device and shown in Gallery tab")
				.font(.caption)
				.foregroundColor(.secondary)
		}

		VStack(alignment: .leading, spacing: 6) {
			Text("API Key")
				.font(.headline)

			SecureField("Your Wallhaven API key (optional)", text: apiKeyBinding)
				.textFieldStyle(.roundedBorder)
				.font(.system(.body, design: .monospaced))
		}
	}
}
