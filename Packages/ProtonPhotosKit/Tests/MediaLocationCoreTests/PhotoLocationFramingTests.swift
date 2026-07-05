import XCTest
import PhotosCore
@testable import MediaLocationCore

final class PhotoLocationFramingTests: XCTestCase {

    private func coord(_ lat: Double, _ lon: Double, _ n: Int = 0) -> PhotoCoordinate {
        PhotoCoordinate(uid: PhotoUID(volumeID: "v", nodeID: "n\(n)"), latitude: lat, longitude: lon, date: .init(timeIntervalSinceReferenceDate: 0))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(PhotoLocationFraming.denseBoundingBox(for: []))
    }

    func testSingleCoordinateFramesAroundItWithAMinimumSpan() throws {
        let box = try XCTUnwrap(PhotoLocationFraming.denseBoundingBox(for: [coord(48.2, 16.4)]))
        // Centered on the point, with a non-zero span so MapKit doesn't zoom to infinity.
        XCTAssertEqual((box.minLatitude + box.maxLatitude) / 2, 48.2, accuracy: 0.0001)
        XCTAssertEqual((box.minLongitude + box.maxLongitude) / 2, 16.4, accuracy: 0.0001)
        XCTAssertGreaterThan(box.maxLatitude - box.minLatitude, 0)
    }

    func testFarOutlierDoesNotDragTheFrame() throws {
        // 40 photos tightly around Vienna, plus ONE in South Africa. The frame must stay on Vienna,
        // not center in the ocean between Europe and Africa.
        var coords = (0..<40).map { i in coord(48.20 + Double(i % 5) * 0.01, 16.37 + Double(i % 5) * 0.01, i) }
        coords.append(coord(-33.92, 18.42, 999)) // Cape Town outlier

        let box = try XCTUnwrap(PhotoLocationFraming.denseBoundingBox(for: coords))
        let centerLat = (box.minLatitude + box.maxLatitude) / 2
        let centerLon = (box.minLongitude + box.maxLongitude) / 2
        // Center stays on Vienna (~48.2N), nowhere near the midpoint to Cape Town (~7N).
        XCTAssertEqual(centerLat, 48.2, accuracy: 0.5)
        XCTAssertEqual(centerLon, 16.4, accuracy: 0.5)
        // The Cape Town latitude must be OUTSIDE the framed box (it was dropped as an outlier).
        XCTAssertFalse(box.contains(latitude: -33.92, longitude: 18.42))
    }

    func testDenseCoreWinsOverASmallerSecondCluster() throws {
        // 30 photos in Vienna, 8 in New York. The bulk (Vienna) should anchor the frame.
        var coords = (0..<30).map { i in coord(48.20 + Double(i % 4) * 0.01, 16.37 + Double(i % 4) * 0.01, i) }
        coords += (0..<8).map { i in coord(40.71 + Double(i % 3) * 0.01, -74.00 + Double(i % 3) * 0.01, 100 + i) }

        let box = try XCTUnwrap(PhotoLocationFraming.denseBoundingBox(for: coords))
        let centerLon = (box.minLongitude + box.maxLongitude) / 2
        // Center on Vienna's longitude (~16E), not dragged west toward New York (~-74).
        XCTAssertEqual(centerLon, 16.4, accuracy: 1.0)
        XCTAssertFalse(box.contains(latitude: 40.71, longitude: -74.00))
    }

    func testCompactClusterIsFullyContained() throws {
        // No outliers: every point must remain inside the frame.
        let coords = (0..<20).map { i in coord(48.20 + Double(i) * 0.002, 16.37 + Double(i) * 0.002, i) }
        let box = try XCTUnwrap(PhotoLocationFraming.denseBoundingBox(for: coords))
        for c in coords {
            XCTAssertTrue(box.contains(latitude: c.latitude, longitude: c.longitude), "dropped a non-outlier at \(c.latitude),\(c.longitude)")
        }
    }
}
