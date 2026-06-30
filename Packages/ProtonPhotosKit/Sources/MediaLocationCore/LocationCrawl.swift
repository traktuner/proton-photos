import Foundation
import PhotosCore

/// Background crawl that builds the whole-library GPS index.
///
/// For each photo not already indexed it asks the injected `location` closure (which wraps the decrypted
/// XAttr GPS via `PhotoMetadataProvider`) for a coordinate, merges it into the in-memory
/// `PhotoLocationIndex`, and periodically persists the encrypted snapshot via `PhotoLocationStore`.
///
/// **Priority:** this is LOWER priority than the thumbnail crawl (the user-facing grid). It runs a single
/// worker with a small throttle and checks `shouldYield` before each fetch, backing off while higher-
/// priority work is active — so it never competes for the backend. It is resumable: re-running only fills
/// the gaps (uids already in the index are skipped). Platform-agnostic (Foundation).
public actor LocationCrawl {
    private var task: Task<Void, Never>?
    private let throttle: Duration
    private let mergeEvery: Int
    private let saveEvery: Int

    public init(throttle: Duration = .milliseconds(40), mergeEvery: Int = 50, saveEvery: Int = 250) {
        self.throttle = throttle
        self.mergeEvery = mergeEvery
        self.saveEvery = saveEvery
    }

    /// Crawl GPS for every uid not already in `index`.
    /// - `location`: returns the decrypted `(latitude, longitude)` for a uid, or `nil` if it has none.
    /// - `captureDates`: capture date per uid (for hero ordering); missing ⇒ `.distantPast`.
    /// - `shouldYield`: `true` ⇒ back off (higher-priority crawl active).
    public func start(
        uids: [PhotoUID],
        captureDates: [PhotoUID: Date],
        location: @escaping @Sendable (PhotoUID) async -> (latitude: Double, longitude: Double)?,
        index: PhotoLocationIndex,
        store: PhotoLocationStore,
        shouldYield: @escaping @Sendable () async -> Bool = { false }
    ) {
        task?.cancel()
        let throttle = throttle, mergeEvery = mergeEvery, saveEvery = saveEvery
        task = Task {
            let alreadyIndexed = await index.indexedUIDs()
            let pending = uids.filter { !alreadyIndexed.contains($0) }
            var batch: [PhotoCoordinate] = []
            var sinceSave = 0

            for uid in pending {
                if Task.isCancelled { break }
                while await shouldYield() {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                }
                if let loc = await location(uid) {
                    batch.append(PhotoCoordinate(uid: uid, latitude: loc.latitude, longitude: loc.longitude,
                                                 date: captureDates[uid] ?? .distantPast))
                }
                sinceSave += 1
                if batch.count >= mergeEvery {
                    let toMerge = batch; batch = []
                    await index.merge(toMerge)
                }
                if sinceSave >= saveEvery {
                    sinceSave = 0
                    await persist(index, into: store)
                }
                try? await Task.sleep(for: throttle)
            }

            if !batch.isEmpty { await index.merge(batch) }
            await persist(index, into: store)
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
