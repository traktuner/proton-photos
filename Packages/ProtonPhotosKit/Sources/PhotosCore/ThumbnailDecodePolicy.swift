/// Shared soft→sharp policy for the decoded-thumbnail RAM tier: when a grid level asks for more pixels
/// than a UID was last decoded at, is the gap worth a re-decode?
///
/// Uses the same 1.25× hysteresis as the Metal texture tier's `residentTextureNeedsMeaningfulUpgrade`,
/// so the two tiers agree on what "materially sharper" means and a small per-level cap fluctuation can
/// never ping-pong decodes. The comparison is against the pixel CAP the cached image was decoded under,
/// not the achieved image size: a source-limited image (bytes smaller than any cap) records the cap it
/// was already given, so repeating the same large request can never re-decode in a loop.
public enum ThumbnailDecodeUpgradePolicy {
    /// True when `requestedPixels` is a materially larger ask (≥ 1.25×) than `cachedDecodePixels`.
    public static func needsSharperDecode(cachedDecodePixels: Int, requestedPixels: Int) -> Bool {
        requestedPixels * 4 >= cachedDecodePixels * 5
    }
}
