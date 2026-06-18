import Testing
import AppKit
@testable import TimelineFeature

/// COMMIT-MATCH (the design-attack's #1 concern): the V2 live overlay is rendered from the
/// arbitrary-column-count day-sectioned projection (`…in:cols:gap:width:`), and the grid is committed at a
/// detent's discrete level (`…in:level:width:`). Those two MUST produce byte-identical geometry when the
/// cols/gap come from that level — otherwise the reveal at release "pops". This proves it by construction:
/// for every square level, the cols-projection at (`columnCount(forLevel:)`, that level's gap) equals the
/// level-projection. If this ever drifts, the live path and the committed grid disagree and the user sees a
/// jump at commit — exactly the rejected behaviour.
@MainActor
struct JustifiedCommitMatchTests {

    /// A layout populated with a few day-sections of varying counts (square levels ignore aspect values —
    /// only the per-section COUNT drives the packing, so any ratio works).
    private func makeLayout() -> JustifiedCollectionLayout {
        let l = JustifiedCollectionLayout()
        l.sectionAspects = [
            Array(repeating: 1.0, count: 37),
            Array(repeating: 1.0, count: 50),
            Array(repeating: 1.0, count: 9),
            Array(repeating: 1.0, count: 128),
        ]
        return l
    }

    @Test func projectionEqualsCommittedGridAtEveryLevel() {
        let l = makeLayout()
        let W: CGFloat = 1200
        let big = NSRect(x: 0, y: 0, width: W, height: 100_000)   // whole content, no culling difference
        for level in JustifiedCollectionLayout.levels.indices {
            let cols = l.columnCount(forLevel: level, width: W)
            let gap = JustifiedCollectionLayout.levels[level].gap

            let committed = l.projectedFramesForElements(in: big, level: level, width: W)
                .sorted { lhs, rhs in lhs.0.section != rhs.0.section ? lhs.0.section < rhs.0.section : lhs.0.item < rhs.0.item }
            let v2 = l.projectedFramesForElements(in: big, cols: cols, gap: gap, width: W)
                .sorted { lhs, rhs in lhs.0.section != rhs.0.section ? lhs.0.section < rhs.0.section : lhs.0.item < rhs.0.item }

            #expect(committed.count == v2.count, "level \(level): element count differs")
            for (a, b) in zip(committed, v2) {
                #expect(a.0 == b.0, "level \(level): index path order differs")
                #expect(abs(a.1.minX - b.1.minX) < 0.001 && abs(a.1.minY - b.1.minY) < 0.001
                        && abs(a.1.width - b.1.width) < 0.001 && abs(a.1.height - b.1.height) < 0.001,
                        "level \(level) item \(a.0): committed \(a.1) != v2 \(b.1)")
            }
        }
    }

    /// The single-item projection (used to anchor the focus photo under the cursor) likewise matches the
    /// committed single-item frame — so the anchor's doc rect the overlay scales about is the SAME rect the
    /// commit places it at.
    @Test func anchorFrameMatchesCommittedAtEveryLevel() {
        let l = makeLayout()
        let W: CGFloat = 1200
        for level in JustifiedCollectionLayout.levels.indices {
            let cols = l.columnCount(forLevel: level, width: W)
            let gap = JustifiedCollectionLayout.levels[level].gap
            for section in l.sectionAspects.indices {
                for item in [0, l.sectionAspects[section].count / 2, l.sectionAspects[section].count - 1] {
                    let ip = IndexPath(item: item, section: section)
                    let committed = l.projectedFrameForItem(at: ip, level: level, width: W)
                    let v2 = l.projectedFrameForItem(at: ip, cols: cols, gap: gap, width: W)
                    #expect(committed != nil && v2 != nil)
                    if let a = committed, let b = v2 {
                        #expect(abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
                                && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001,
                                "level \(level) \(ip): committed \(a) != v2 \(b)")
                    }
                }
            }
        }
    }
}
