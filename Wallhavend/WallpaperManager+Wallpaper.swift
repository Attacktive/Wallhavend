import Foundation
import AppKit

extension WallpaperManager {
	// Stub: Task 5 replaces this with parallel per-bucket fetching.
	func updateWallpaper() async {}

	func getWallpaperStorageDirectory() throws -> URL {
		let libraryURL = try FileManager.default.url(
			for: .libraryDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)

		let desktopPicturesURL = libraryURL
			.appendingPathComponent("Desktop Pictures", isDirectory: true)
			.appendingPathComponent("Wallhavend", isDirectory: true)

		try FileManager.default.createDirectory(at: desktopPicturesURL, withIntermediateDirectories: true)
		return desktopPicturesURL
	}

	func applyWallpaper(url: URL, to screens: [NSScreen]) throws {
		let workspace = NSWorkspace.shared
		let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
			.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
			.allowClipping: false,
			.fillColor: NSColor.black
		]

		for screen in screens {
			try workspace.setDesktopImageURL(url, for: screen, options: options)
		}
	}
}
