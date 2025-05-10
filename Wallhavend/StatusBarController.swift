import SwiftUI

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

		let contentView =
			MenuBarView(onAction: { [weak self] in
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
