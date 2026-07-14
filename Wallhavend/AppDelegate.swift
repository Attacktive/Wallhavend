import SwiftUI
import Sparkle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
	var statusBarController: StatusBarController?

	private var settingsWindowController: NSWindowController?
	private let wallpaperManager = WallpaperManager.shared
	private var updaterController: SPUStandardUpdaterController?

	@AppStorage("startAutoUpdateOnLaunch")
	private var startAutoUpdateOnLaunch: Bool = false

	func applicationDidFinishLaunching(_ notification: Notification) {
		let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
		if !isRunningTests {
			updaterController = SPUStandardUpdaterController(
				startingUpdater: true,
				updaterDelegate: self,
				userDriverDelegate: nil
			)
		}

		statusBarController = StatusBarController(appDelegate: self)

		// Hide dock icon
		NSApp.setActivationPolicy(.accessory)

		if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
			DispatchQueue.main.async { [weak self] in
				self?.showSettings()
			}
		}

		if startAutoUpdateOnLaunch {
			wallpaperManager.startAutoUpdate()
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
			contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)

		let contentView = ContentView()
			.environmentObject(wallpaperManager)
			.environmentObject(WallhavenService.shared)

		let hostingView = NSHostingView(rootView: contentView)
		hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 540)
		hostingView.autoresizingMask = [.width, .height]

		window.contentView = hostingView
		window.title = "Wallhavend Settings"
		window.contentMinSize = NSSize(width: 500, height: 480)
		window.setContentSize(NSSize(width: 500, height: 540))
		window.center()

		let windowController = NSWindowController(window: window)
		windowController.shouldCascadeWindows = true
		windowController.showWindow(nil)
		settingsWindowController = windowController

		NSApp.activate(ignoringOtherApps: true)
	}

	func checkForUpdates() {
		updaterController?.checkForUpdates(nil)
	}

	// MARK: - SPUUpdaterDelegate

	/// Installs a silently-downloaded automatic update immediately instead of letting Sparkle defer it to app quit.
	///
	/// Wallhavend is a menu-bar agent that users basically never quit, so Sparkle's default "install on quit" leaves a background-downloaded update staged forever: when no delegate handles this callback, the automatic driver aborts and waits for a termination that never comes (see SPUAutomaticUpdateDriver).
	/// Invoking the block and returning true tells Sparkle to install and relaunch right away, which is what makes automatic updates actually land on a background app.
	func updater(
		_ updater: SPUUpdater,
		willInstallUpdateOnQuit item: SUAppcastItem,
		immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
	) -> Bool {
		immediateInstallHandler()
		return true
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
