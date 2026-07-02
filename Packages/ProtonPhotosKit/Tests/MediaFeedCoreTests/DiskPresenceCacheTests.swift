import Testing
import PhotosCore
@testable import MediaFeedCore

/// The crawl-coverage disk-presence tracker, re-keyed from an interpolated "vol~node" string to `PhotoUID`.
/// The counts must be identical to the string version for normal IDs, and STRICTER (no aliasing) for the
/// pathological IDs that straddled the `~` separator.
@Suite struct DiskPresenceCacheTests {
    private func uid(_ vol: String, _ node: String) -> PhotoUID { PhotoUID(volumeID: vol, nodeID: node) }

    @Test func tracksPresentSubset() {
        let cache = DiskPresenceCache()
        cache.beginTracking([uid("v", "a"), uid("v", "b"), uid("v", "c")])
        cache.set(uid("v", "a"), present: true)
        cache.set(uid("v", "b"), present: true)
        let cov = cache.coverage()
        #expect(cov.present == 2 && cov.total == 3)
        #expect(abs(cov.percent - 2.0 / 3.0) < 1e-12)
    }

    @Test func presenceSetBeforeTrackingIsCountedAtBeginTracking() {
        let cache = DiskPresenceCache()
        cache.set(uid("v", "a"), present: true)   // learned during a prior crawl pass
        cache.beginTracking([uid("v", "a"), uid("v", "b")])
        let cov = cache.coverage()
        #expect(cov.present == 1 && cov.total == 2)
    }

    @Test func togglingPresenceDecrements() {
        let cache = DiskPresenceCache()
        cache.beginTracking([uid("v", "a")])
        cache.set(uid("v", "a"), present: true)
        #expect(cache.coverage().present == 1)
        cache.set(uid("v", "a"), present: false)   // e.g. evicted
        #expect(cache.coverage().present == 0)
    }

    @Test func emptyTrackingReportsFullCoverage() {
        // No tracked items ⇒ "nothing missing" (percent 1), matching the prior behavior.
        let cov = DiskPresenceCache().coverage()
        #expect(cov.present == 0 && cov.total == 0 && cov.percent == 1)
    }

    /// The correctness win of the re-key: two UIDs whose (vol, node) fields straddle the old "~" separator
    /// ("a~b"+"c" and "a"+"b~c" both flatten to "a~b~c") must be counted as SEPARATE entries. Under the old
    /// string key they aliased into one; under PhotoUID identity they do not.
    @Test func collidingStringKeysStayDistinctUnderPhotoUID() {
        let cache = DiskPresenceCache()
        let u1 = uid("a~b", "c")
        let u2 = uid("a", "b~c")
        cache.beginTracking([u1, u2])
        #expect(cache.coverage().total == 2)

        cache.set(u1, present: true)
        #expect(cache.coverage().present == 1, "marking u1 present must NOT also mark the aliasing u2 present")

        cache.set(u2, present: true)
        #expect(cache.coverage().present == 2)
    }
}
