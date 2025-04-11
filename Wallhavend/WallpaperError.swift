import Foundation

enum WallpaperError: LocalizedError {
	case invalidURL
	case invalidResponse
	case noContentType
	case unsupportedImageType(String)
	case invalidImage
	case zeroByteResource

	var errorDescription: String? {
		switch self {
			case .invalidURL:
				return "Invalid wallpaper URL"
			case .invalidResponse:
				return "Invalid response type"
			case .noContentType:
				return "No content type in response"
			case .unsupportedImageType(let type):
				return "Unsupported image type: \(type)"
			case .invalidImage:
				return "Failed to load downloaded image"
			case .zeroByteResource:
				return "The response is literally empty."
		}
	}
}
