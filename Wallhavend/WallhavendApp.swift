import SwiftUI

@main
struct WallhavendApp: App {
	@StateObject
	private var wallpaperManager = WallpaperManager.shared
	private let wallhavenService = WallhavenService.shared

	@NSApplicationDelegateAdaptor(AppDelegate.self)
	var appDelegate

	var body: some Scene {
		Settings {
			EmptyView()
		}
	}
}
