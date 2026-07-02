import Foundation
import PhotosCore

/// The order in which the background thumbnail crawl walks the library.
///
/// The timeline store delivers photos oldest-first (`TimelineMetadataStore.load()` is
/// `ORDER BY t, vol, node`), and the grid bottom-pins to the newest photo - so the array the UI holds is
/// oldest → newest. Apple Photos (and this app) open scrolled to the BOTTOM, i.e. the newest photos,
/// so the crawl should fetch newest → oldest: the photos the user is most likely to look at first are
/// cached first.
///
/// This helper makes that ordering EXPLICIT and TESTABLE rather than relying on a caller remembering to
/// `.reversed()`. It sorts by capture time descending (newest first) using a STABLE sort, so items that
/// share a capture time keep their original relative order (deterministic crawl + resumable checkpoint).
public enum ThumbnailCrawlOrder {
    /// Newest → oldest UID order for the background crawl. Robust to the input order (sorts by
    /// `captureTime` descending) so it does not silently break if an upstream query stops being `ASC`.
    public static func newestToOldest(_ items: [PhotoItem]) -> [PhotoUID] {
        stableSortedNewestFirst(items).map(\.uid)
    }

    /// Same ordering, returning the full items (for callers/tests that need capture times).
    public static func newestToOldest(items: [PhotoItem]) -> [PhotoItem] {
        stableSortedNewestFirst(items)
    }

    /// Swift's `sorted(by:)` is not guaranteed stable, so we decorate with the original index and break
    /// ties on it - giving a deterministic newest-first order even when many photos share a timestamp.
    private static func stableSortedNewestFirst(_ items: [PhotoItem]) -> [PhotoItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.captureTime != rhs.element.captureTime {
                    return lhs.element.captureTime > rhs.element.captureTime   // newest first
                }
                return lhs.offset < rhs.offset                                  // stable tie-break
            }
            .map(\.element)
    }
}
