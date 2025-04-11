import SwiftUI
import AppKit

class StatusBarController {
	private var statusItem: NSStatusItem
	private var popover: NSPopover
	private var appDelegate: AppDelegate?

	init(appDelegate: AppDelegate) {
		self.appDelegate = appDelegate

		popover = NSPopover()
		popover.contentSize = NSSize(width: 180, height: 400)
		popover.behavior = .applicationDefined

		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		if let button = statusItem.button {
			button.action = #selector(togglePopover(_:))
			button.target = self

			if let image = NSImage(named: NSImage.Name("MenuBarIcon")) {
				image.size.width = 24
				image.size.height = 24
				button.image = image
			}
		}

		let contentView = MenuBarView(onAction: { [weak self] in
			self?.closePopover()
		})
		.environmentObject(WallpaperManager.shared)
		.environmentObject(WallhavenService.shared)
		.environment(\.appDelegate, appDelegate)

		popover.contentViewController = NSHostingController(rootView: contentView)
	}

	@objc
	private func togglePopover(_ sender: AnyObject?) {
		if popover.isShown {
			closePopover()
		} else {
			showPopover()
		}
	}

	private func showPopover() {
		if let button = statusItem.button {
			popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
		}
	}

	private func closePopover() {
		popover.performClose(nil)
	}
}

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

struct MenuBarView: View {
	@StateObject
	private var wallpaperManager = WallpaperManager.shared

	@Environment(\.appDelegate)
	private var appDelegate

	var onAction: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			if wallpaperManager.lastUpdated != nil {
				Text(wallpaperManager.formattedLastUpdated)
					.font(.caption)
			}

			Button("Locate in Finder") {
				wallpaperManager.revealCurrentWallpaperInFinder()
				onAction()
			}
			.disabled(!wallpaperManager.hasCurrentWallpaper)

			Divider()

			Button("Update Now") {
				Task {
					onAction()
					await wallpaperManager.updateWallpaper()
				}
			}

			Button(wallpaperManager.isRunning ? "Stop Auto Update" : "Start Auto Update") {
				if wallpaperManager.isRunning {
					wallpaperManager.stopAutoUpdate()
				} else {
					wallpaperManager.startAutoUpdate()
				}

				onAction()
			}

			Divider()

			Button("Open Settings...") {
				appDelegate?.showSettings()
				onAction()
			}

			Button("Quit") {
				onAction()
				NSApplication.shared.terminate(nil)
			}
		}
		.padding()
	}
}
