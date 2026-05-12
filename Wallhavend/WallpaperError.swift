import Foundation

enum WallpaperError: LocalizedError {
	case invalidURL
	case invalidResponse
	case httpError(Int)
	case noContentType
	case unsupportedImageType(String)
	case invalidImage
	case noResults

	var errorDescription: String? {
		switch self {
			case .invalidURL:
				return "Invalid wallpaper URL"
			case .invalidResponse:
				return "Invalid response type"
			case .httpError(let statusCode):
				return "Download failed with HTTP \(statusCode)"
			case .noContentType:
				return "No content type in response"
			case .unsupportedImageType(let type):
				return "Unsupported image type: \(type)"
			case .invalidImage:
				return "Failed to load downloaded image"
			case .noResults:
				return "No wallpapers found matching your search criteria"
		}
	}
}
