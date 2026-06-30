# Library Map View — Design

**Status:** IN PROGRESS (Phase 1). **Goal:** an Apple-Photos-style map of the whole library — own sidebar route, clustered badges (count + hero photo) that subdivide on zoom.

## Decisions (locked)
- **Tiles/framework: MapKit** (`MKMapView`). Native, first-party, **no API key**, Apple-served tiles licensed for in-app use. Already used in `InfoPanelView`. No third-party tiles.
- **Crawl: full library**, via a priority **scheduler** — thumbnails are P1, GPS is P2 (extensible). The map fills in live as the GPS job progresses.
- **Persistence: E2EE at-rest + decrypt-once-into-RAM.** GPS is sensitive PII → one AES-GCM blob on disk (per-account cache key, like the thumbnail caches); decrypted **once** into an in-memory index (~1 MB for 20k photos) → instant region queries, no per-view decode. Purged on sign-out.
- **Route:** a `PhotoFilter.map` sidebar entry; the detail swaps `TimelineView` → `LibraryMapView`.
- **Hero photo:** first photo in the cluster for now (best/cover heuristic later).

## Universal-binary architecture (load-bearing)
Long-term: a universal binary for iPad/iOS without a rewrite (see memory `universal-binary-shared-core-vision`). So:
- **Shared core (platform-agnostic, Foundation/CryptoKit):** `PhotoCoordinate` (PhotosCore); `PhotoLocationStore` + `PhotoLocationIndex` + `LocationCrawl` (MediaLocationCore). Reused as-is on iOS.
- **Platform UI:** `MapFeature` module — the `MKMapView` wrapper (`NSViewRepresentable` on macOS; `UIViewRepresentable` later) + annotation views are the only platform-specific bits. All native + Liquid Glass.

## Data source
GPS = decrypted XAttr `Location` (Latitude/Longitude), already surfaced by `PhotoMetadataProvider.metadata(for:)` → `PhotoMetadata.latitude/longitude`. The crawl reuses this seam per photo (no new decode path).

## Performance (20k+ photos)
- The encrypted index loads once into RAM (~1 MB) → region queries are in-memory filters (µs).
- The map adds annotations only for the visible map rect (+ margin); MapKit clusters that subset. Scales to any library; SQLite R*Tree only if libraries get huge.
- Thumbnails for badges reuse the existing `ThumbnailFeed`/cache.

## Components
| Module | Type | Role |
|---|---|---|
| PhotosCore | `PhotoCoordinate` | shared model (uid, lat, lon, date) |
| MediaLocationCore | `PhotoLocationStore` | AES-GCM encrypted persistence of the index blob |
| MediaLocationCore | `PhotoLocationIndex` | `@Observable` in-memory index + bbox query; the map binds its `revision` |
| MediaLocationCore | `LocationCrawl` | low-priority background GPS crawl (yields to thumbnails) |
| MapFeature (new) | `LibraryMapView`, annotation/cluster views, `MapViewModel` | the MapKit UI + clustering |
| App/Drive | crawl wiring | feeds the real metadata provider + uid list; sign-out purge |
| App | `PhotoFilter.map` + sidebar + detail switch | the route |

## Phases (each a building commit)
1. **Core (this):** PhotoCoordinate + store + index + crawl, headless, tests.
2. **MapFeature + route:** MKMapView, raw pins, sidebar entry, wiring.
3. **Clustering + hero/count badges:** the Photos look.
4. **Polish:** region-based loading, scheduler integration, sign-out purge, "show on map" from the viewer.

## Verification
Build green; crawl populates the index (background, behind thumbnails); map fills live; clusters split/merge on zoom; tap-cluster zooms, tap-photo opens the viewer; sign-out purges the index; smooth pan/zoom at 20k.
