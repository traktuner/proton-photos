import Testing
import Foundation
import CryptoKit
import PhotosCore
@testable import MediaLocationCore

private func uid(_ n: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: n) }
private func coord(_ n: String, _ lat: Double, _ lon: Double) -> PhotoCoordinate {
    PhotoCoordinate(uid: uid(n), latitude: lat, longitude: lon, date: Date(timeIntervalSince1970: 0))
}
private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("loctest-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct PhotoLocationStoreTests {
    @Test func roundTripsEncryptedCoordinates() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: key)
        let coords = [coord("a", 47.8, 13.0), coord("b", 47.4, 12.5)]
        store.save(coords)

        let reopened = PhotoLocationStore(directory: dir)
        reopened.configure(accountUID: "acct", key: key)
        #expect(reopened.load() == coords)
    }

    @Test func onDiskBlobIsNeverPlaintext() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        store.save([coord("secret", 47.812345, 13.044444)])

        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: file)
        #expect(!bytes.isEmpty)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("47.812345"))   // coordinate not in cleartext
    }

    @Test func wrongKeyOrAccountReadsEmpty() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        store.save([coord("a", 47.8, 13.0)])

        let wrongKey = PhotoLocationStore(directory: dir)
        wrongKey.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        #expect(wrongKey.load().isEmpty)

        let wrongAccount = PhotoLocationStore(directory: dir)
        wrongAccount.configure(accountUID: "other", key: SymmetricKey(size: .bits256))
        #expect(wrongAccount.load().isEmpty)
    }

    @Test func clearErasesTheBlob() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: key)
        store.save([coord("a", 47.8, 13.0)])
        store.clear()

        let reopened = PhotoLocationStore(directory: dir)
        reopened.configure(accountUID: "acct", key: key)
        #expect(reopened.load().isEmpty)
    }
}

@Suite @MainActor struct PhotoLocationIndexTests {
    @Test func mergeDedupsByUIDAndBumpsRevisionOnlyWhenChanged() {
        let index = PhotoLocationIndex()
        index.merge([coord("a", 1, 1), coord("b", 2, 2)])
        #expect(index.coordinates.count == 2)

        let r = index.revision
        index.merge([coord("a", 1, 1)])                 // pure duplicate
        #expect(index.coordinates.count == 2)
        #expect(index.revision == r)                    // no change ⇒ no view churn

        index.merge([coord("c", 3, 3)])
        #expect(index.coordinates.count == 3)
        #expect(index.revision == r + 1)
    }

    @Test func boundingBoxFiltersToVisibleRegion() {
        let index = PhotoLocationIndex()
        index.merge([coord("inside", 47.8, 13.0), coord("outside", 10.0, 10.0)])
        let box = GeoBoundingBox(minLatitude: 47, maxLatitude: 48, minLongitude: 12, maxLongitude: 14)
        let hits = index.coordinates(in: box)
        #expect(hits.map(\.uid) == [uid("inside")])
    }

    @Test func viewportPolicyMatchesVisibleMapRectMarginFormula() {
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 1.6, maxCells: 400, cellDivisor: 12)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.5,
            centerLongitude: 13.0,
            latitudeDelta: 0.5,
            longitudeDelta: 1.25
        )

        let box = policy.boundingBox(for: viewport)
        #expect(box == GeoBoundingBox(
            minLatitude: 46.7,
            maxLatitude: 48.3,
            minLongitude: 11.0,
            maxLongitude: 15.0
        ))
    }

    @Test func viewportPolicyBinsNearbyCoordinatesIntoOneCell() {
        let index = PhotoLocationIndex()
        // Three photos close enough to fall into the same grid cell, plus one far away.
        index.merge([
            coord("a", 47.700, 13.000),
            coord("b", 47.701, 13.001),
            coord("c", 47.702, 13.002),
            coord("far", 48.000, 14.000),
        ])
        // Large cellDivisor with a tight viewport ensures the three near photos share a cell, while
        // the far one lands in its own. Margin 1 keeps the box tight so `far` is excluded entirely.
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 1, maxCells: 100, cellDivisor: 6)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.701,
            centerLongitude: 13.001,
            latitudeDelta: 0.01,
            longitudeDelta: 0.01
        )

        let cells = index.coordinates(in: viewport, policy: policy)
        // One cell aggregates the three near photos; `far` is outside the box.
        #expect(cells.count == 1, "expected one cell; got \(cells.count)")
        #expect(cells[0].count == 3, "expected 3 members in the cell; got \(cells[0].count)")
    }

    @Test func minCellMetersFloorCollapsesSamePlaceBurstEvenWhenZoomedIn() {
        let index = PhotoLocationIndex()
        // A burst at essentially one spot, spread by ~30 m of GPS noise (0.0003° lat ≈ 33 m).
        index.merge([
            coord("a", 47.70000, 13.00000),
            coord("b", 47.70030, 13.00040),
            coord("c", 47.69975, 13.00020),
        ])
        // A tightly zoomed-in viewport (~110 m tall): with cellDivisor 12 the raw cell is ~9 m, so
        // without a floor these three scatter into separate cells (the reported bug). A 80 m floor
        // forces them into one.
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.70000,
            centerLongitude: 13.00000,
            latitudeDelta: 0.001,
            longitudeDelta: 0.001
        )

        let noFloor = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 2, maxCells: 400, cellDivisor: 12)
        #expect(index.coordinates(in: viewport, policy: noFloor).count > 1,
                "control: without a floor the burst should scatter into multiple cells")

        let floored = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 2, maxCells: 400, cellDivisor: 12, minCellMeters: 80)
        let cells = index.coordinates(in: viewport, policy: floored)
        #expect(cells.count == 1, "expected one cell with the 80 m floor; got \(cells.count)")
        #expect(cells.first?.count == 3, "the single cell must carry all 3 photos; got \(cells.first?.count ?? -1)")
    }

    @Test func viewportPolicyRejectsInvalidInputsWithoutLeakingAllCoordinates() {
        let index = PhotoLocationIndex()
        index.merge([coord("a", 47.8, 13.0)])
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: .infinity, maxCells: 400, cellDivisor: 12)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.7,
            centerLongitude: 13.1,
            latitudeDelta: 0.5,
            longitudeDelta: 0.5
        )

        #expect(index.coordinates(in: viewport, policy: policy).isEmpty)
    }

    /// Regression for the map-churn bug: sub-pixel viewport jitter must not change which cells exist
    /// or which photos each cell holds. The aggregation bins by integer cell indices, so a fractional
    /// shift of the center keeps the same cells (just possibly re-keyed, but still bounded) - the
    /// member sets per cell must stay identical.
    @Test func viewportPolicyCellsAreStableAcrossSmallViewportJitter() {
        let index = PhotoLocationIndex()
        let center = (lat: 47.7045, lon: 13.1045)
        // Spread photos across a few distinct cells so aggregation is meaningful.
        index.merge([
            coord("a", center.lat,       center.lon),
            coord("b", center.lat + 0.01, center.lon),
            coord("c", center.lat + 0.02, center.lon),
            coord("d", center.lat,       center.lon + 0.01),
            coord("e", center.lat,       center.lon + 0.02),
        ])
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 2.0, maxCells: 10, cellDivisor: 10)

        let viewportA = PhotoLocationViewport(
            centerLatitude: center.lat, centerLongitude: center.lon,
            latitudeDelta: 0.03, longitudeDelta: 0.03
        )
        let viewportB = PhotoLocationViewport(
            centerLatitude: center.lat + 0.0000001, centerLongitude: center.lon + 0.0000001,
            latitudeDelta: 0.03, longitudeDelta: 0.03
        )

        let cellsA = index.coordinates(in: viewportA, policy: policy)
        let cellsB = index.coordinates(in: viewportB, policy: policy)
        // Same set of heroes (cell identities are stable) and same total photo count.
        #expect(Set(cellsA.map(\.uid)) == Set(cellsB.map(\.uid)),
               "cell heroes must be stable across sub-pixel jitter")
        let totalA = cellsA.reduce(0) { $0 + $1.count }
        let totalB = cellsB.reduce(0) { $0 + $1.count }
        #expect(totalA == totalB, "total photo coverage must be stable")
        #expect(totalA == 5, "all five photos must be represented")
    }

    @Test func aggregationPreservesEveryPhotoAcrossCells() {
        let index = PhotoLocationIndex()
        // 20 photos spread so each cell gets ~2 members - none should be dropped.
        var coords: [PhotoCoordinate] = []
        for i in 0..<20 {
            coords.append(coord("p\(i)", 47.0 + Double(i % 4) * 0.01, 13.0 + Double(i / 4) * 0.01))
        }
        index.merge(coords)
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 2.0, maxCells: 50, cellDivisor: 10)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.015, centerLongitude: 13.015,
            latitudeDelta: 0.05, longitudeDelta: 0.05
        )
        let cells = index.coordinates(in: viewport, policy: policy)
        let totalMembers = cells.reduce(0) { $0 + $1.count }
        #expect(totalMembers == 20, "every photo must be accounted for; got \(totalMembers)")
    }

    @Test func capKeepsTheDensestCellEvenWhenItIsFarFromCenter() {
        let index = PhotoLocationIndex()
        var coords: [PhotoCoordinate] = []
        // Many sparse single-photo cells clustered near the viewport center.
        for i in 0..<40 {
            coords.append(coord("near\(i)", 47.500 + Double(i) * 0.001, 13.500))
        }
        // One very dense place far from center (the "home with 2000 photos" case, scaled down): 50
        // photos within one cell, off to the side.
        for i in 0..<50 {
            coords.append(coord("home\(i)", 47.600 + Double(i) * 0.00001, 13.700))
        }
        index.merge(coords)
        // A tight cap that MUST drop cells: with count-blind nearest-center pruning the dense far cell
        // would be dropped; the count-first policy must keep it.
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 5, maxCells: 10, cellDivisor: 50)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.500, centerLongitude: 13.500,
            latitudeDelta: 0.05, longitudeDelta: 0.05
        )
        let cells = index.coordinates(in: viewport, policy: policy)
        #expect(cells.count == 10, "cap must be applied; got \(cells.count)")
        let densest = cells.map(\.count).max() ?? 0
        #expect(densest >= 50, "the densest cell (the far 50-photo home) must survive the cap; got \(densest)")
    }
}

@Suite("MediaLocationCore platform purity")
struct MediaLocationCorePlatformPurityTests {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 { url.deleteLastPathComponent() }
        return url
    }

    private var sources: URL {
        packageRoot.appendingPathComponent("Sources/MediaLocationCore")
    }

    private static let forbiddenFrameworkImports: [String] = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "AVKit",
        "MetalKit",
    ]

    private static let forbiddenTokens: [String] = [
        "NSImage",
        "UIImage",
        "NSView",
        "UIView",
        "NSWorkspace",
        "NSOpenPanel",
        "UIApplication",
        "NSApplication",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let allowedFrameworkImports: Set<String> = [
        "CryptoKit",
        "Foundation",
        "Observation",
        "PhotosCore",
    ]

    @Test func hasNoPlatformFrameworkImports() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        var seen: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let remainder = trimmed.dropFirst("import ".count)
                let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
                seen.insert(moduleName)
                if Self.forbiddenFrameworkImports.contains(moduleName) {
                    violations.append("\(file.lastPathComponent): \(trimmed)")
                }
            }
        }

        #expect(violations.isEmpty, "MediaLocationCore must not import platform UI frameworks:\n\(violations.joined(separator: "\n"))")
        #expect(seen.subtracting(Self.allowedFrameworkImports).isEmpty, "Unexpected MediaLocationCore imports: \(seen.subtracting(Self.allowedFrameworkImports).sorted())")
    }

    @Test func hasNoPlatformImageOrHardwarePolicyTokens() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens where source.contains(token) {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(violations.isEmpty, "MediaLocationCore must not reference platform UI types or hardware policy:\n\(violations.joined(separator: "\n"))")
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  url.pathExtension == "swift" else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }
}
