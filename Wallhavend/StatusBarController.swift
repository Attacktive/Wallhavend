import AppKit
import Combine

@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
	private var statusItem: NSStatusItem
	private weak var appDelegate: AppDelegate?
	private let wallpaperManager = WallpaperManager.shared
	private var cancellables = Set<AnyCancellable>()

	init(appDelegate: AppDelegate) {
		self.appDelegate = appDelegate

		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

		super.init()

		let menu = NSMenu()
		menu.delegate = self
		statusItem.menu = menu

		wallpaperManager.$isOnline
			.combineLatest(wallpaperManager.$isRunning)
			.sink { [weak self] isOnline, isRunning in
				self?.updateStatusBarIcon(isOnline: isOnline, isRunning: isRunning)
			}
			.store(in: &cancellables)
	}

	// MARK: - NSMenuDelegate

	func menuWillOpen(_ menu: NSMenu) {
		menu.removeAllItems()

		if !wallpaperManager.isOnline {
			let offlineItem = NSMenuItem(title: "Offline", action: nil, keyEquivalent: "")
			offlineItem.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
			offlineItem.isEnabled = false
			menu.addItem(offlineItem)
			menu.addItem(.separator())
		}

		let updateNowItem = NSMenuItem(title: "Update Wallpaper Now", action: #selector(updateNow), keyEquivalent: "")
		updateNowItem.target = self
		updateNowItem.isEnabled = wallpaperManager.isOnline
		menu.addItem(updateNowItem)

		let pinAction = wallpaperManager.currentPinAction
		let pinTitle: String
		let pinSymbol: String
		let pinSelector: Selector?

		switch pinAction {
			case .unavailable:
				pinTitle = "Pin Current Wallpaper"
				pinSymbol = "pin"
				pinSelector = nil
			case .pin:
				pinTitle = "Pin Current Wallpaper"
				pinSymbol = "pin"
				pinSelector = #selector(togglePinCurrentWallpaper)
			case .unpin:
				pinTitle = "Unpin Current Wallpaper"
				pinSymbol = "pin.slash"
				pinSelector = #selector(togglePinCurrentWallpaper)
		}

		let pinItem = NSMenuItem(title: pinTitle, action: pinSelector, keyEquivalent: "")
		pinItem.target = self
		pinItem.isEnabled = pinAction != .unavailable
		pinItem.image = NSImage(systemSymbolName: pinSymbol, accessibilityDescription: nil)
		menu.addItem(pinItem)

		let autoUpdateTitle = wallpaperManager.isRunning ? "Stop Auto Update" : "Start Auto Update"
		let autoUpdateItem = NSMenuItem(title: autoUpdateTitle, action: #selector(toggleAutoUpdate), keyEquivalent: "")
		autoUpdateItem.target = self

		// Auto-update can run offline in Pinned-only mode (it never downloads).
		let canRunAutoUpdate = wallpaperManager.isOnline || wallpaperManager.isRunning || wallpaperManager.rotationMode == .pinnedOnly
		autoUpdateItem.isEnabled = canRunAutoUpdate
		menu.addItem(autoUpdateItem)

		menu.addItem(.separator())

		let settingsItem = NSMenuItem(title: "Open Settings...", action: #selector(openSettings), keyEquivalent: ",")
		settingsItem.target = self
		menu.addItem(settingsItem)

		let checkUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
		checkUpdatesItem.target = self
		menu.addItem(checkUpdatesItem)

		menu.addItem(.separator())

		let quitItem = NSMenuItem(title: "Quit Wallhavend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		menu.addItem(quitItem)
	}

	// MARK: - Actions

	@objc
	private func updateNow() {
		Task {
			await wallpaperManager.fetchFreshNow()
		}
	}

	@objc
	private func togglePinCurrentWallpaper() {
		wallpaperManager.toggleCurrentWallpaperPin()
	}

	@objc
	private func toggleAutoUpdate() {
		if wallpaperManager.isRunning {
			wallpaperManager.stopAutoUpdate()
		} else {
			wallpaperManager.startAutoUpdate()
		}
	}

	@objc
	private func openSettings() {
		appDelegate?.showSettings()
	}

	@objc
	private func checkForUpdates() {
		appDelegate?.checkForUpdates()
	}

	// MARK: - Icon

	private func updateStatusBarIcon(isOnline: Bool, isRunning: Bool) {
		guard let button = statusItem.button else { return }

		let iconSize = NSSize(width: 18, height: 18)

		guard let baseImage = NSImage(named: NSImage.Name("MenuBarIcon")) else { return }

		baseImage.size = iconSize

		if !isOnline {
			button.image = makeOfflineIcon(from: baseImage, size: iconSize)
		} else if isRunning {
			button.image = baseImage
		} else {
			button.image = makeDimmedIcon(from: baseImage, size: iconSize)
		}
	}

	private func makeDimmedIcon(from source: NSImage, size: NSSize) -> NSImage {
		let result = NSImage(size: size)
		result.lockFocus()
		source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 0.35)
		result.unlockFocus()

		return result
	}

	private func makeOfflineIcon(from source: NSImage, size: NSSize) -> NSImage {
		let dimmed = makeDimmedIcon(from: source, size: size)

		let result = NSImage(size: size)
		result.lockFocus()

		dimmed.draw(in: NSRect(origin: .zero, size: size))

		let badgeSize: CGFloat = 8
		let badgeRect = NSRect(x: size.width - badgeSize, y: 0, width: badgeSize, height: badgeSize)

		let symbolConfig = NSImage.SymbolConfiguration(pointSize: badgeSize, weight: .bold)

		if let badge = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)?
			.withSymbolConfiguration(symbolConfig) {
				badge.draw(in: badgeRect)
			}

		result.unlockFocus()

		return result
	}
}
