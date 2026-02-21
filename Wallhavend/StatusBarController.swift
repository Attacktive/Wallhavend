import SwiftUI
import Combine

@MainActor
class StatusBarController {
	private var statusItem: NSStatusItem
	private var popover: NSPopover
	private var appDelegate: AppDelegate?
	private let wallpaperManager = WallpaperManager.shared
	private var cancellables = Set<AnyCancellable>()

	init(appDelegate: AppDelegate) {
		self.appDelegate = appDelegate

		popover = NSPopover()
		popover.contentSize = NSSize(width: 180, height: 400)
		popover.behavior = .applicationDefined

		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		if let button = statusItem.button {
			button.action = #selector(handleClick(_:))
			button.target = self
			button.sendAction(on: [.leftMouseUp, .rightMouseUp])
		}

		let contentView =
			MenuBarView(onAction: { [weak self] in
				self?.closePopover()
			})
			.environmentObject(wallpaperManager)
			.environmentObject(WallhavenService.shared)
			.environment(\.appDelegate, appDelegate)

		popover.contentViewController = NSHostingController(rootView: contentView)

		wallpaperManager.$isOnline
			.combineLatest(wallpaperManager.$isRunning)
			.sink { [weak self] isOnline, isRunning in
				self?.updateStatusBarIcon(isOnline: isOnline, isRunning: isRunning)
			}
			.store(in: &cancellables)
	}

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
			button.image = makeGrayscaleIcon(from: baseImage, size: iconSize)
		}
	}

	private func makeGrayscaleIcon(from source: NSImage, size: NSSize) -> NSImage {
		guard
			let tiffData = source.tiffRepresentation,
			let ciImage = CIImage(data: tiffData),
			let filter = CIFilter(name: "CIColorControls")
		else {
			return source
		}

		filter.setValue(ciImage, forKey: kCIInputImageKey)
		filter.setValue(0.0, forKey: kCIInputSaturationKey)

		guard let outputCI = filter.outputImage else { return source }

		let rep = NSCIImageRep(ciImage: outputCI)
		let result = NSImage(size: size)
		result.addRepresentation(rep)

		return result
	}

	private func makeOfflineIcon(from source: NSImage, size: NSSize) -> NSImage {
		let grayscale = makeGrayscaleIcon(from: source, size: size)

		let result = NSImage(size: size)
		result.lockFocus()

		grayscale.draw(in: NSRect(origin: .zero, size: size))

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

	@objc
	private func handleClick(_ sender: AnyObject?) {
		guard let event = NSApp.currentEvent else { return }
		if event.type == .rightMouseUp {
			closePopover()
			toggleAutoUpdate()
		} else {
			if popover.isShown {
				closePopover()
			} else {
				showPopover()
			}
		}
	}

	private func toggleAutoUpdate() {
		if wallpaperManager.isRunning {
			wallpaperManager.stopAutoUpdate()
		} else if wallpaperManager.isOnline {
			let interval = UserDefaults.standard.double(forKey: "updateInterval")
			wallpaperManager.startAutoUpdate(interval: interval > 0 ? interval : 60)
		}
	}

	private func showPopover() {
		DispatchQueue.main.async { [weak self] in
			guard let self = self else { return }

			guard let button = self.statusItem.button else {
				print("🛑 statusItem.button is nil. Not showing popover.")
				return
			}

			guard self.popover.contentViewController != nil else {
				print("🛑 popover.contentViewController is nil. Not showing popover.")
				return
			}

			self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
			if !wallpaperManager.isOnline {
				Label("Offline", systemImage: "wifi.slash")
					.foregroundColor(.secondary)
					.font(.caption)
			}

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
			.disabled(!wallpaperManager.isOnline)

			Button("Previous Wallpaper") {
				Task {
					onAction()
					await wallpaperManager.restorePreviousWallpaper()
				}
			}
			.disabled(wallpaperManager.previousWallpaperFileURL == nil)

			Button(wallpaperManager.isRunning ? "Stop Auto Update" : "Start Auto Update") {
				if wallpaperManager.isRunning {
					wallpaperManager.stopAutoUpdate()
				} else {
					wallpaperManager.startAutoUpdate()
				}

				onAction()
			}
			.disabled(!wallpaperManager.isOnline && !wallpaperManager.isRunning)

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
