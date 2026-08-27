import Foundation

/// The pure mapping between our aspect buckets and Openverse's query vocabulary, kept apart from the service so it stays callable — and testable — without a live client.
extension OpenverseService {
	/// Openverse's aspect filter is coarse: three buckets against our five.
	/// `square` is never requested — no screen snaps to it — and all four landscape buckets have to share `wide`, which is the whole reason the client-side admit gate exists.
	nonisolated static func aspectParameter(for bucket: AspectBucket) -> String {
		switch bucket {
			case .portrait:
				return "tall"
			case .ultrawide, .landscape16x9, .landscape16x10, .landscape4x3:
				return "wide"
		}
	}

	/// Whether a result may be saved under `bucket`.
	///
	/// Neither of Openverse's own filters is trustworthy here: `wide` covers four of our buckets, and `size` is a coarse small/medium/large bucket derived from filesize.
	/// Wallpapers are filed by bucket, so the snap check is what makes the requested bucket equal the measured one — a stronger guarantee than Wallhaven's `ratios` filter gives today.
	/// A result that never reported its dimensions can't prove it qualifies.
	nonisolated static func admits(width: Int?, height: Int?, minimumWidth: Int, minimumHeight: Int, bucket: AspectBucket) -> Bool {
		guard let width, let height, width > 0, height > 0 else {
			return false
		}

		guard width >= minimumWidth, height >= minimumHeight else {
			return false
		}

		return AspectBucket.snap(aspectRatio: Double(width) / Double(height)) == bucket
	}

	/// Openverse has no random sort, so variety comes from where in the result set a fetch lands.
	/// The first fetch of a window has to be page 1 — nothing yet says how deep that window goes — and every one after it picks at random within reach.
	nonisolated static func pageRange(knownPageCount: Int?) -> ClosedRange<Int> {
		guard let knownPageCount else {
			return 1...1
		}

		return 1...max(1, min(knownPageCount, maximumPages))
	}

	/// The dimension floor a candidate has to clear: the screen's own pixels while the size filter is on, and nothing at all once it's off.
	/// `nil` for a non-nil `atleast` means `AspectBucket.atleastString(for:)` produced something unparseable, which is a broken contract rather than an absent floor.
	nonisolated static func floor(atleast: String?) -> (width: Int, height: Int)? {
		guard let atleast else {
			return (0, 0)
		}

		return AspectBucket.minimumDimensions(atleast: atleast)
	}
}
