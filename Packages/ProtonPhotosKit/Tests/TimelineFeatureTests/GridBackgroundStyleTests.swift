import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

// The production grid is ONE uniform Apple-like dark-gray surface behind the thumbnails: gaps + aspectFit
// letterbox + clear color all use `MetalGridPalette.background`. No per-cell card backgrounds, no missing-image
// placeholder cards, no grid lines, no debug tile colors in production.
@Suite struct GridBackgroundStyleTests {
    private let eps: CGFloat = 0.5
    private func repoRoot() -> URL { var u = URL(fileURLWithPath: #filePath); for _ in 0 ..< 5 { u.deleteLastPathComponent() }; return u }
    private func src(_ name: String) -> String {
        (try? String(contentsOf: repoRoot().appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/\(name)"), encoding: .utf8)) ?? ""
    }

    // 1 — a single named background color is the source of truth, a neutral dark gray, used for the clear color.
    @Test func productionGridUsesSingleBackgroundColor() {
        let c = MetalGridPalette.backgroundRGBA
        #expect(abs(c.r - c.g) < 0.01 && abs(c.g - c.b) < 0.01, "background must be a NEUTRAL gray")
        #expect(c.r > 0.07 && c.r < 0.20, "background must be a dark gray ~#1f1f1f, not black/light: \(c.r)")
        #expect(c.a == 1.0, "opaque surface")
        // The renderer + host clear to the palette (no scattered hardcoded clear colors).
        #expect(src("MetalGridRenderer.swift").contains("MetalGridPalette.clearColor"))
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("MetalGridPalette.clearColor") && host.contains("MetalGridPalette.background"))
        #expect(!host.contains("red: 0.043"), "no leftover hardcoded warm-brown clear color")
    }

    // 2 — production grid build draws NO per-cell card for resident or missing images. Missing thumbnails should
    // reveal the same bottom-most grid surface instead of a darker rounded square.
    @Test func rendererDoesNotDrawGridCellBackgroundsInProduction() {
        let coord = src("MetalGridCoordinator.swift")
        guard let range = coord.range(of: "private func buildRealGroups") else { Issue.record("buildRealGroups missing"); return }
        let body = String(coord[range.lowerBound ..< (coord.index(range.lowerBound, offsetBy: 2800, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(!body.contains("backgrounds.append"), "missing thumbnails must not draw placeholder background cards")
        #expect(!body.contains("quads: backgrounds"), "production must not submit a placeholder-background render group")
    }

    // 3 — aspectFit leaves letterbox INSIDE the square slot; with no card drawn, it shows the grid background.
    @Test func aspectFitLetterboxUsesGridBackground() {
        let slot = CGRect(x: 0, y: 0, width: 180, height: 180)
        // A wide (16:9) photo letterboxes: contentRect is strictly shorter than the square → letterbox bands exist.
        let fit = TileContentFitter.fit(slotRect: slot, mediaAspect: 16.0 / 9.0, displayMode: .aspectFitInsideSquare)
        #expect(fit.contentRect.height < slot.height - eps, "letterbox bands must exist for a wide photo")
        #expect(fit.contentRect.minX >= slot.minX - eps && fit.contentRect.maxX <= slot.maxX + eps, "content stays in slot")
        // No card is drawn behind a resident image (guard #2), so the letterbox bands reveal the cleared
        // MetalGridPalette.background — the same uniform surface as the gaps.
        #expect(MetalGridPalette.backgroundVector.w == 1)
    }

    // 4 — the synthetic colored-tile debug grid was removed; production (buildRealGroups) must never draw a
    // solid colored card, and the debug palette must stay gone entirely.
    @Test func productionDoesNotUseSyntheticDebugColors() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(!coord.contains("SquareGridDebugMode"), "the synthetic debug palette must stay removed")
        // Production path: resident tiles draw an image quad, never a solid colored card.
        guard let range = coord.range(of: "private func buildRealGroups") else { Issue.record("buildRealGroups missing"); return }
        let body = String(coord[range.lowerBound ..< (coord.index(range.lowerBound, offsetBy: 2800, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(!body.contains("mode: .solid"), "production must not draw synthetic solid-colored tiles")
    }
}
