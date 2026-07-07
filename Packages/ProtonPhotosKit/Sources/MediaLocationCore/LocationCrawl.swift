import Foundation
import PhotosCore

/// What one GPS probe of a photo's metadata yielded. Distinguishing "no GPS in the metadata" from "the
/// probe failed" is what lets the map say "no geotagged photos" vs "couldn't scan" honestly.
public enum LocationProbeResult: Equatable, Sendable {
    case found(latitude: Double, longitude: Double)
    case noLocation
    /// `category` must be non-sensitive (e.g. "http-429", "CancellationError") - it is logged.
    case failed(category: String)
}

/// Background crawl that builds the whole-library GPS index.
///
/// For each photo not already indexed it asks the injected `location` closure (which wraps the decrypted
/// XAttr GPS via `PhotoMetadataProvider`) for a coordinate, merges it into the in-memory
/// `PhotoLocationIndex` (progressively - the map gets its first pins after the first merged batch, long
/// before the run finishes), and periodically persists the encrypted snapshot via `PhotoLocationStore`.
///
/// **Priority:** this is LOWER priority than VISIBLE thumbnail work. It runs a single worker with a small
/// throttle and checks `shouldYield` before each fetch, backing off while the grid actively demands
/// thumbnails. `shouldYield` must reflect *live* demand only (see
/// `ThumbnailFeedCore.hasVisibleThumbnailPressure`) - keying it to "any thumbnail work pending" parks the
/// crawl until a whole 20k-photo library finishes crawling.
/// It is resumable: re-running only fills the gaps (uids already in the index are skipped).
/// Platform-agnostic (Foundation).
public actor LocationCrawl {
    private var task: Task<Void, Never>?
    private let throttle: Duration
    private let backoff: Duration
    private let mergeEvery: Int
    private let saveEvery: Int
    private let logEvery: Int

    public init(throttle: Duration = .milliseconds(40), backoff: Duration = .milliseconds(500),
                mergeEvery: Int = 50, saveEvery: Int = 250, logEvery: Int = 500) {
        self.throttle = throttle
        self.backoff = backoff
        self.mergeEvery = mergeEvery
        self.saveEvery = saveEvery
        self.logEvery = logEvery
    }

    /// Crawl GPS for every uid not already in `index`.
    /// - `location`: probes the decrypted metadata for a uid (found / no GPS / failed).
    /// - `captureDates`: capture date per uid (for hero ordering); missing ⇒ `.distantPast`.
    /// - `shouldYield`: `true` ⇒ back off (visible thumbnail demand active). Checked before each probe.
    /// - `log`: bounded diagnostics sink (start / cadence / backoff / completion - never per item).
    public func start(
        uids: [PhotoUID],
        captureDates: [PhotoUID: Date],
        location: @escaping @Sendable (PhotoUID) async -> LocationProbeResult,
        index: PhotoLocationIndex,
        store: PhotoLocationStore,
        shouldYield: @escaping @Sendable () async -> Bool = { false },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        task?.cancel()
        let throttle = throttle, backoff = backoff
        let mergeEvery = mergeEvery, saveEvery = saveEvery, logEvery = logEvery
        task = Task {
            let alreadyIndexed = await index.indexedUIDs()
            let pending = uids.filter { !alreadyIndexed.contains($0) }
            var progress = PhotoLocationScanProgress(
                phase: .scanning, scanned: 0, total: pending.count,
                found: alreadyIndexed.count, noLocation: 0, failed: 0
            )
            await index.updateScanProgress(progress)
            log("[LocationCrawl] started candidates=\(pending.count) alreadyIndexed=\(alreadyIndexed.count)")

            var batch: [PhotoCoordinate] = []
            var sinceSave = 0
            var sinceLog = 0
            var failureCategories: [String: Int] = [:]
            var loggedBackoff = false

            func mergeNow() async {
                let toMerge = batch; batch = []
                await index.merge(toMerge)
                progress.found = await index.coordinates.count
                await index.updateScanProgress(progress)
            }

            for uid in pending {
                if Task.isCancelled { break }
                while await shouldYield() {
                    if !loggedBackoff {
                        loggedBackoff = true
                        log("[LocationCrawl] backing off (visible thumbnail demand) scanned=\(progress.scanned)/\(progress.total)")
                    }
                    try? await Task.sleep(for: backoff)
                    if Task.isCancelled { break }
                }
                if Task.isCancelled { break }
                if loggedBackoff {
                    loggedBackoff = false
                    log("[LocationCrawl] resumed scanned=\(progress.scanned)/\(progress.total)")
                }

                switch await location(uid) {
                case let .found(latitude, longitude):
                    batch.append(PhotoCoordinate(uid: uid, latitude: latitude, longitude: longitude,
                                                 date: captureDates[uid] ?? .distantPast))
                case .noLocation:
                    progress.noLocation += 1
                case let .failed(category):
                    progress.failed += 1
                    // Bounded: count per category, remember at most the first few distinct categories.
                    if failureCategories[category] != nil || failureCategories.count < 4 {
                        failureCategories[category, default: 0] += 1
                    }
                }
                progress.scanned += 1
                sinceSave += 1
                sinceLog += 1

                if batch.count >= mergeEvery { await mergeNow() }
                if sinceSave >= saveEvery {
                    sinceSave = 0
                    await persist(index, into: store)
                }
                if sinceLog >= logEvery {
                    sinceLog = 0
                    await index.updateScanProgress(progress)
                    log("[LocationCrawl] scanned=\(progress.scanned)/\(progress.total) found=\(progress.found + batch.count) noLocation=\(progress.noLocation) failed=\(progress.failed)")
                }
                try? await Task.sleep(for: throttle)
            }

            if !batch.isEmpty { await mergeNow() }
            await persist(index, into: store)
            progress.found = await index.coordinates.count

            if Task.isCancelled {
                // Partial run: back to idle so the next start rescans the gap (the index keeps what it got).
                progress.phase = .idle
                await index.updateScanProgress(progress)
                log("[LocationCrawl] cancelled scanned=\(progress.scanned)/\(progress.total) found=\(progress.found)")
                return
            }
            // Every probe failing is a real failure (metadata unreachable), not "your photos have no GPS".
            let allFailed = progress.scanned > 0 && progress.failed == progress.scanned && progress.found == 0
            progress.phase = allFailed ? .failed : .completed
            await index.updateScanProgress(progress)
            let categories = failureCategories.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: " ")
            log("[LocationCrawl] \(allFailed ? "FAILED" : "completed") scanned=\(progress.scanned)/\(progress.total) found=\(progress.found) noLocation=\(progress.noLocation) failed=\(progress.failed)"
                + (categories.isEmpty ? "" : " categories: \(categories)"))
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func persist(_ index: PhotoLocationIndex, into store: PhotoLocationStore) async {
        let coords = await index.coordinates
        store.save(coords)
    }
}

public extension LocationCrawl {
    /// The canonical GPS probe over a `PhotoMetadataProvider` backend - shared by the macOS and iOS
    /// shells so the platforms cannot drift. Failure categories are broad and non-sensitive
    /// (error domain + code, never node ids or API paths) because they end up in the debug log.
    static func metadataProbe(_ metadata: any PhotoMetadataProvider) -> @Sendable (PhotoUID) async -> LocationProbeResult {
        { uid in
            do {
                let m = try await metadata.metadata(for: uid)
                if m.hasLocation, let latitude = m.latitude, let longitude = m.longitude {
                    return .found(latitude: latitude, longitude: longitude)
                }
                return .noLocation
            } catch is CancellationError {
                return .failed(category: "cancelled")
            } catch {
                let ns = error as NSError
                return .failed(category: "\(ns.domain)#\(ns.code)")
            }
        }
    }
}
