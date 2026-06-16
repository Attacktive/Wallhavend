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

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Wallpaper Pool")
				.font(.headline)

			Picker("Pool size", selection: poolSizeBinding) {
				Text("Current only").tag(0)
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
