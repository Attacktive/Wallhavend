import AppKit

enum AspectBucket: String, CaseIterable {
	case ultrawide = "21x9"
	case landscape16x9 = "16x9"
	case landscape16x10 = "16x10"
	case landscape4x3 = "4x3"
	case portrait = "9x16"

	var label: String {
		switch self {
			case .ultrawide: return "Ultrawide (21:9)"
			case .landscape16x9: return "Landscape (16:9)"
			case .landscape16x10: return "Landscape (16:10)"
			case .landscape4x3: return "Landscape (4:3)"
			case .portrait: return "Portrait (9:16)"
		}
	}

	// Snap boundaries are midpoints between adjacent ratios:
	//   (16/9 + 21/9)/2 ≈ 2.06   →  16x9 / 21x9 split
	//   (16/10 + 16/9)/2 ≈ 1.69  →  16x10 / 16x9 split
	//   (4/3 + 16/10)/2 ≈ 1.47   →  4x3 / 16x10 split
	//   1.0                       →  portrait / landscape split
	static func snap(aspectRatio: Double) -> AspectBucket {
		if aspectRatio >= 2.06 {
			return .ultrawide
		}

		if aspectRatio >= 1.69 {
			return .landscape16x9
		}

		if aspectRatio >= 1.47 {
			return .landscape16x10
		}

		if aspectRatio >= 1.0 {
			return .landscape4x3
		}

		return .portrait
	}

	static func forScreen(_ screen: NSScreen) -> AspectBucket {
		let aspect = Double(screen.frame.width / screen.frame.height)
		return snap(aspectRatio: aspect)
	}

	static func atleastString(for screens: [NSScreen]) -> String {
		let dims = screens.map { screen -> (Int, Int) in
			let scale = screen.backingScaleFactor
			return (Int(screen.frame.width * scale), Int(screen.frame.height * scale))
		}

		let best = dims.max { lhs, rhs in lhs.0 * lhs.1 < rhs.0 * rhs.1 } ?? (1920, 1080)
		return "\(best.0)x\(best.1)"
	}
}
