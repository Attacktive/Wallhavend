import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
	var statusBarController: StatusBarController?

	private var settingsWindowController: NSWindowController?
	private let wallpaperManager = WallpaperManager.shared

	@AppStorage("startAutoUpdateOnLaunch")
	private var startAutoUpdateOnLaunch: Bool = false

	@AppStorage("updateInterval")
	private var updateInterval: TimeInterval = 60

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusBarController = StatusBarController(appDelegate: self)

		// Hide dock icon
		NSApp.setActivationPolicy(.accessory)

		if startAutoUpdateOnLaunch {
			wallpaperManager.startAutoUpdate(interval: updateInterval)
		}
	}

	func application(_ application: NSApplication, open urls: [URL]) {}

	func showSettings() {
		if let windowController = settingsWindowController {
			windowController.showWindow(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 400, height: 650),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)

		let contentView = ContentView()
			.environmentObject(wallpaperManager)
			.environmentObject(WallhavenService.shared)

		let hostingView = NSHostingView(rootView: contentView)
		hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 650)
		hostingView.autoresizingMask = [.width, .height]

		window.contentView = hostingView
		window.title = "Wallhavend Settings"
		window.contentMinSize = NSSize(width: 400, height: 650)
		window.setContentSize(NSSize(width: 400, height: 650))
		window.center()

		let windowController = NSWindowController(window: window)
		windowController.shouldCascadeWindows = true
		windowController.showWindow(nil)
		settingsWindowController = windowController

		NSApp.activate(ignoringOtherApps: true)
	}
}

private struct AppDelegateKey: EnvironmentKey {
	static let defaultValue: AppDelegate? = nil
}

extension EnvironmentValues {
	var appDelegate: AppDelegate? {
		get { self[AppDelegateKey.self] }
		set { self[AppDelegateKey.self] = newValue }
	}
}
