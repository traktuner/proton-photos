import XCTest
@testable import PhotosCore

final class AppFeaturePolicyTests: XCTestCase {
    func testUnsupportedCapabilityHidesFeatureBeforeTierEvaluation() {
        let device = AppDeviceCapabilities(available: [], physicalMemoryBytes: 8 << 30)
        XCTAssertEqual(
            AppFeaturePolicy.production.availability(of: .smartSearch, device: device, tier: .premium),
            .unavailable
        )
    }

    func testProductTierLocksSupportedPremiumFeature() {
        let device = AppDeviceCapabilities(available: [.neuralEngine], physicalMemoryBytes: 8 << 30)
        XCTAssertEqual(
            AppFeaturePolicy.production.availability(of: .peopleRecognition, device: device, tier: .free),
            .locked
        )
        XCTAssertEqual(
            AppFeaturePolicy.production.availability(of: .peopleRecognition, device: device, tier: .premium),
            .available
        )
    }
}
