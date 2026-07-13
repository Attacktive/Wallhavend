import AppKit
import Combine

extension WallpaperManager {
	/// How many non-pinned wallpapers each active bucket needs to reach `poolSize`.
	///
	/// Pinned files are eviction-exempt extras that don't count toward the target (matching `poolEntries`), so a bucket
	/// can sit at `poolSize` non-pinned plus any number of pinned. Only active buckets below target appear in the result.
	/// Yields nothing when `poolSize <= 1`: poolSize 1 is "Current only" and 0 is "apply and forget" — neither has a
	/// gallery worth pre-filling.
	nonisolated static func bucketsNeedingFill(
		poolsByBucket: [String: [URL]],
		pinnedIds: Set<String>,
		poolSize: Int,
		activeBuckets: [String]
	) -> [String: Int] {
		guard poolSize > 1 else {
			return [:]
		}

		var result: [String: Int] = [:]
		for bucket in activeBuckets {
			let pool = poolsByBucket[bucket] ?? []
			let nonPinnedCount = pool.filter { !pinnedIds.contains($0.deletingPathExtension().lastPathComponent) }.count
			let needed = poolSize - nonPinnedCount
			if needed > 0 {
				result[bucket] = needed
			}
		}

		return result
	}

	/// The inputs that change what the pool should contain. When any of these changes, the in-flight fill is cancelled
	/// and restarted. Pin/block state is deliberately excluded — those self-heal on the next tick rather than kicking off
	/// a download burst on every pin.
	struct PrefetchInputs: Equatable {
		let searchQuery: String
		let categories: String
		let purity: String
		let apiKey: String
		let poolSize: Int
		let rotationMode: String
	}

	private func currentPrefetchInputs() -> PrefetchInputs {
		let service = WallhavenService.shared

		return PrefetchInputs(
			searchQuery: service.searchQuery,
			categories: service.selectedCategories.map { $0.rawValue }.sorted().joined(separator: ","),
			purity: service.purityString,
			apiKey: service.apiKey,
			poolSize: poolSize,
			rotationMode: rotationMode.rawValue
		)
	}

	/// Whether background pre-filling should run right now. Bursts are allowed on any connection (the settled design),
	/// so this gates only on the engine being active, the session live, the screen unlocked, being online, and `.fresh` mode — Pinned-only
	/// never downloads. The pool-size skip (≤ 1) lives in `bucketsNeedingFill`, which then returns no targets.
	var shouldPrefetch: Bool {
		isRunning && isSessionActive && !isScreenLocked && isOnline && rotationMode == .fresh
	}

	/// Watch for search/pool settings changes that should refill the pool, debounced so per-keystroke typing coalesces
	/// into a single restart. `UserDefaults.didChangeNotification` is the one signal that catches both the manager's
	/// `@Published` settings and the service's `@AppStorage` ones; the snapshot compare filters out unrelated writes.
	func setupSettingsObserver() {
		lastPrefetchInputs = currentPrefetchInputs()

		topUpSettingsCancellable = NotificationCenter.default
			.publisher(for: UserDefaults.didChangeNotification)
			.debounce(for: .milliseconds(500), scheduler: RunLoop.main)
			.sink { [weak self] _ in
				guard let self else { return }

				let snapshot = self.currentPrefetchInputs()
				guard snapshot != self.lastPrefetchInputs else { return }

				self.lastPrefetchInputs = snapshot
				self.restartPoolTopUp()
			}
	}

	/// Ensure a background fill is running — the idempotent heartbeat the tick, network, and session triggers rely on.
	/// No-op if one is already in flight.
	func requestPoolTopUp() {
		guard prefetchTask == nil else { return }

		startPoolTopUp()
	}

	/// Cancel any in-flight fill and start a fresh one, because the target or the search results changed underneath it.
	func restartPoolTopUp() {
		cancelPoolTopUp()
		startPoolTopUp()
	}

	/// Stop any in-flight fill and clear the progress indicator.
	func cancelPoolTopUp() {
		prefetchGeneration += 1
		prefetchTask?.cancel()
		prefetchTask = nil
		isPrefetching = false
		prefetchRemaining = 0
	}

	private func startPoolTopUp() {
		guard shouldPrefetch, let screensByBucket = currentScreensByBucket() else {
			return
		}

		var atleastByBucket: [String: String] = [:]
		for (bucket, screens) in screensByBucket {
			atleastByBucket[bucket.rawValue] = AspectBucket.atleastString(for: screens)
		}

		let needs = Self.bucketsNeedingFill(
			poolsByBucket: poolsByBucket,
			pinnedIds: WallhavenService.shared.pinnedIds,
			poolSize: poolSize,
			activeBuckets: Array(atleastByBucket.keys)
		)
		guard !needs.isEmpty else {
			return
		}

		prefetchGeneration += 1
		let generation = prefetchGeneration
		isPrefetching = true
		prefetchRemaining = needs.values.reduce(0, +)

		prefetchTask = Task { [weak self] in
			await self?.runPoolTopUp(needs: needs, atleastByBucket: atleastByBucket)
			self?.finishPoolTopUp(generation: generation)
		}
	}

	/// Reset progress once a fill ends naturally, unless a newer fill has already superseded this one.
	private func finishPoolTopUp(generation: Int) {
		guard generation == prefetchGeneration else {
			return
		}

		isPrefetching = false
		prefetchRemaining = 0
		prefetchTask = nil
	}

	private func runPoolTopUp(needs: [String: Int], atleastByBucket: [String: String]) async {
		for bucketRaw in needs.keys {
			if Task.isCancelled {
				return
			}

			guard
				let bucket = AspectBucket(rawValue: bucketRaw),
				let atleast = atleastByBucket[bucketRaw]
			else {
				continue
			}

			await fillBucket(bucket, atleast: atleast)
		}
	}

	/// Download (without applying) into one bucket until it holds `poolSize` non-pinned wallpapers, or we get cancelled,
	/// hit a transient error, or exhaust the attempt budget. The bounded attempts keep duplicate or blocked-heavy
	/// results from spinning forever.
	private func fillBucket(_ bucket: AspectBucket, atleast: String) async {
		let maxAttempts = poolSize * 2 + 2
		var attempts = 0

		while attempts < maxAttempts {
			if Task.isCancelled {
				return
			}

			let pinnedIds = WallhavenService.shared.pinnedIds
			let nonPinnedCount = (poolsByBucket[bucket.rawValue] ?? [])
				.filter { !pinnedIds.contains(wallpaperId(for: $0)) }
				.count
			guard nonPinnedCount < poolSize else {
				return
			}

			attempts += 1

			do {
				let grew = try await prefetchOneForBucket(bucket: bucket, atleast: atleast)
				if grew {
					prefetchRemaining = max(0, prefetchRemaining - 1)
				}
			} catch is CancellationError {
				return
			} catch {
				// Transient fetch/download failure (offline, no results, HTTP error). Stop this bucket quietly — prefetch
				// is invisible, so it never touches the user-facing `error`; the next tick retries.
				print("Prefetch stopped for \(bucket.rawValue): \(error)")
				return
			}
		}
	}

	/// Fetch + save one wallpaper into the bucket's pool WITHOUT applying it or changing the current wallpaper.
	/// Returns whether the pool actually grew — re-fetching an id already on disk re-saves the same file and doesn't.
	private func prefetchOneForBucket(bucket: AspectBucket, atleast: String) async throws -> Bool {
		let beforeCount = poolsByBucket[bucket.rawValue]?.count ?? 0

		let wallpaper = try await WallhavenService.shared.fetchRandomWallpaper(ratios: bucket.rawValue, atleast: atleast)
		let (data, fileExtension) = try await downloadWallpaper(from: wallpaper.path)
		let wallpaperPath = try await Task.detached(priority: .utility) {
			try self.saveWallpaper(
				data: data,
				id: wallpaper.id,
				fileExtension: fileExtension,
				bucket: bucket
			)
		}.value

		prependToPool(url: wallpaperPath, bucket: bucket.rawValue)

		let afterCount = poolsByBucket[bucket.rawValue]?.count ?? 0
		return afterCount > beforeCount
	}
}
