import Foundation

/// Splits the MANDATORY thumbnail grid cache from the OPTIONAL Offline Photo Library.
///
/// Thumbnails are grid infrastructure: they must always crawl in the background (newest → oldest) whenever
/// the user is signed in and timeline metadata exists — independent of the "Offline Photo Library" toggle.
/// The toggle is reserved for future preview/original (derivative) offline caching. Encoding this as a
/// named, tested policy keeps the decoupling explicit and guards against a regression that re-couples them.
public enum OfflineLibraryPolicy {
    /// The grid thumbnail crawl is ALWAYS enabled when signed in — never gated by the offline toggle.
    public static func shouldCrawlThumbnails(offlineEnabled: Bool) -> Bool { true }

    /// Whether the (future) offline library should cache larger derivatives (previews/originals). This is
    /// the one thing the toggle controls. Not yet wired to behaviour — present so the split is explicit.
    public static func shouldCacheOfflineDerivatives(offlineEnabled: Bool) -> Bool { offlineEnabled }
}
