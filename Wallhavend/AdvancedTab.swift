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

	/// Shows the stored mode as-is; the setter still refuses to enter Pinned only while nothing is pinned (the radio option is disabled then, too).
	private var rotationModeBinding: Binding<RotationMode> {
		Binding(
			get: { wallpaperManager.rotationMode },
			set: { newMode in
				wallpaperManager.rotationMode = if newMode == .pinnedOnly && !hasPins {
					.fresh
				} else {
					newMode
				}
			}
		)
	}

	/// The caption under the Rotation picker. Pins exist: explain both modes. Nothing pinned with Fresh stored: hint how to enable Pinned only. Nothing pinned with Pinned only stored: warn that scheduled updates are paused.
	static func rotationCaption(storedMode: RotationMode, hasPins: Bool) -> String {
		if hasPins {
			return "Fresh downloads new wallpapers (and rotates your pool when offline). Pinned only never downloads — it cycles just your pinned wallpapers. “Update Now” always fetches a fresh one."
		} else if storedMode == .pinnedOnly {
			return "Pinned only never downloads, and nothing is pinned — automatic updates are paused. Pin a wallpaper or switch to Fresh. “Update Now” still fetches a fresh one."
		} else {
			return "Fresh downloads new wallpapers (and rotates your pool when offline). Pin a wallpaper to enable Pinned only."
		}
	}

	private var rotationCaption: String {
		Self.rotationCaption(storedMode: wallpaperManager.rotationMode, hasPins: hasPins)
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
