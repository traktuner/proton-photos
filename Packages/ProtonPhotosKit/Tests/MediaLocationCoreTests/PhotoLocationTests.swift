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
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 1.6, maxCoordinates: 3000)
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

    @Test func viewportPolicyFiltersAndCapsByDistanceToCenter() {
        let index = PhotoLocationIndex()
        index.merge([
            coord("a", 47.8, 13.0),
            coord("b", 47.7, 13.1),
            coord("outside", 10.0, 10.0),
            coord("c", 47.6, 13.2),
        ])
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 1, maxCoordinates: 2)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.7,
            centerLongitude: 13.1,
            latitudeDelta: 0.5,
            longitudeDelta: 0.5
        )

        let hits = index.coordinates(in: viewport, policy: policy)
        // When capped, the N closest to the viewport center win — NOT the first N in insertion order.
        // b is at the exact center (dist 0); a and c tie at equal distance, broken deterministically
        // by the (volumeID, nodeID) tuple tiebreaker: ("v","a") < ("v","c") → a precedes c.
        // With maxCoordinates=2 → [b, a].
        #expect(hits.map(\.uid) == [uid("b"), uid("a")])
    }

    @Test func viewportPolicyRejectsInvalidInputsWithoutLeakingAllCoordinates() {
        let index = PhotoLocationIndex()
        index.merge([coord("a", 47.8, 13.0)])
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: .infinity, maxCoordinates: 3000)
        let viewport = PhotoLocationViewport(
            centerLatitude: 47.7,
            centerLongitude: 13.1,
            latitudeDelta: 0.5,
            longitudeDelta: 0.5
        )

        #expect(index.coordinates(in: viewport, policy: policy).isEmpty)
    }

    /// Regression for the map-churn bug: when the viewport holds more photos than `maxCoordinates`,
    /// a sub-pixel jitter of the map region must not swap which N photos win the cap. Before the fix,
    /// `prefix(maxCoordinates)` picked by insertion order, so a tiny box-edge change re-selected a
    /// different subset and caused the host to remove/re-add ~2000 annotations and cancel/re-spawn
    /// their thumbnail loads on every jitter. Distance-to-center selection keeps the N closest
    /// stable as the box edges wobble.
    @Test func viewportPolicyCapsAreStableAcrossSmallViewportJitter() {
        let index = PhotoLocationIndex()
        // 6 photos at increasing distances from the cluster center, spaced widely enough that a
        // sub-pixel center jitter cannot flip which one sits at the cap boundary (5th vs 6th).
        // Photos ordered in insertion order OPPOSITE to distance, so the OLD prefix-based behavior
        // would have picked the wrong 5 — this also asserts distance selection is in effect.
        let center = (lat: 47.7045, lon: 13.1045)
        index.merge([
            coord("far1",   center.lat + 0.05, center.lon + 0.05), // insertion 0, but FARTHEST
            coord("far2",   center.lat + 0.04, center.lon + 0.04),
            coord("mid1",   center.lat + 0.002, center.lon + 0.002),
            coord("near3",  center.lat + 0.0015, center.lon + 0.0015),
            coord("near2",  center.lat + 0.001, center.lon + 0.001),
            coord("near1",  center.lat, center.lon),               // insertion 5, CLOSEST
        ])
        let policy = PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 2.0, maxCoordinates: 5)

        // Box radius = delta * marginMultiplier = 0.03 * 2.0 = 0.06 ≥ 0.05, so all 6 photos are
        // inside both viewports — cap binds, isolation is purely about deterministic selection.
        let viewportA = PhotoLocationViewport(
            centerLatitude: center.lat, centerLongitude: center.lon,
            latitudeDelta: 0.03, longitudeDelta: 0.03
        )
        let viewportB = PhotoLocationViewport(
            // Sub-pixel jitter: same region scale, fractionally shifted center. All 6 photos
            // remain inside both boxes (membership unchanged), so the only variable is which 5
            // win the cap — and distance selection must keep them stable.
            centerLatitude: center.lat + 0.0000001, centerLongitude: center.lon + 0.0000001,
            latitudeDelta: 0.03, longitudeDelta: 0.03
        )

        let hitsA = index.coordinates(in: viewportA, policy: policy).map(\.uid)
        let hitsB = index.coordinates(in: viewportB, policy: policy).map(\.uid)
        #expect(hitsA.count == 5, "expected cap to bind; got \(hitsA.count)")
        #expect(hitsA == hitsB, "capped selection must be stable across sub-pixel viewport jitter")
        // The farthest photo (far1) is the one dropped, NOT the last-inserted one.
        #expect(!hitsA.contains(uid("far1")), "distance selection drops the farthest, not the last-inserted")
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
