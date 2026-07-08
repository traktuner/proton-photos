import Foundation
import PhotosCore
import XCTest
@testable import UploadCore

final class BackupRetryPolicyTests: XCTestCase {

    func testDelaysGrowExponentiallyAndCap() {
        let policy = BackupRetryPolicy(baseDelay: 1, maxDelay: 900, maxAttempts: 8)
        XCTAssertEqual(policy.delay(afterAttempts: 0), 0)
        XCTAssertEqual(policy.delay(afterAttempts: 1), 1)
        XCTAssertEqual(policy.delay(afterAttempts: 2), 2)
        XCTAssertEqual(policy.delay(afterAttempts: 3), 4)
        XCTAssertEqual(policy.delay(afterAttempts: 10), 512)
        XCTAssertEqual(policy.delay(afterAttempts: 11), 900, "the cap must clamp the exponential")
        XCTAssertEqual(policy.delay(afterAttempts: 1000), 900, "huge attempt counts must not overflow")
    }

    func testParkThreshold() {
        let policy = BackupRetryPolicy(baseDelay: 1, maxDelay: 900, maxAttempts: 3)
        XCTAssertFalse(policy.shouldPark(attempts: 2))
        XCTAssertTrue(policy.shouldPark(attempts: 3))
        XCTAssertTrue(policy.shouldPark(attempts: 4))
    }

    func testDefensiveBounds() {
        let policy = BackupRetryPolicy(baseDelay: -5, maxDelay: -10, maxAttempts: 0)
        XCTAssertEqual(policy.baseDelay, 0)
        XCTAssertGreaterThanOrEqual(policy.maxDelay, policy.baseDelay)
        XCTAssertEqual(policy.maxAttempts, 1)
    }
}

final class BackupThrottlePolicyTests: XCTestCase {

    func testConcurrencyTable() {
        let policy = BackupThrottlePolicy(baseConcurrency: 2)

        XCTAssertEqual(policy.maxConcurrentItems(for: .unconstrained), 2)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(thermalLevel: .fair)), 2)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(isLowPowerMode: true)), 1)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(isNetworkConstrained: true)), 1)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(isNetworkExpensive: true)), 1)
    }

    func testThermalPressureDoesNotReduceBackupConcurrency() {
        let policy = BackupThrottlePolicy(baseConcurrency: 6)

        // Thermal state must NOT lower backup throughput: the OS manages its own thermal
        // throttling, and the app self-slowing only adds wall-clock latency.
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(thermalLevel: .nominal)), 6)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(thermalLevel: .fair)), 6)
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(thermalLevel: .serious)), 6,
                       "serious thermal must not reduce backup concurrency")
        XCTAssertEqual(policy.maxConcurrentItems(for: .init(thermalLevel: .critical)), 6,
                       "critical thermal must not pause backup")
    }

    func testBaseConcurrencyIsAtLeastOne() {
        XCTAssertEqual(BackupThrottlePolicy(baseConcurrency: 0).maxConcurrentItems(for: .unconstrained), 1)
    }
}

final class LibraryWorkloadGovernorPolicyTests: XCTestCase {

    func testBackupBudgetMatchesExistingThrottleContract() {
        let policy = LibraryWorkloadGovernorPolicy()

        XCTAssertEqual(policy.budget(for: .userInitiatedBackup, baseConcurrency: 2).maxConcurrentItems, 2)
        // Thermal state no longer reduces backup concurrency (OS manages thermal itself).
        XCTAssertEqual(policy.budget(
            for: .userInitiatedBackup,
            signals: LibraryWorkloadSignals(thermalLevel: .serious),
            baseConcurrency: 2
        ).maxConcurrentItems, 2)
        XCTAssertEqual(policy.budget(
            for: .userInitiatedBackup,
            signals: LibraryWorkloadSignals(thermalLevel: .critical),
            baseConcurrency: 2
        ).maxConcurrentItems, 2)
    }

    func testBackgroundLocationYieldsToVisibleMediaAndActiveTransfers() {
        let policy = LibraryWorkloadGovernorPolicy()

        XCTAssertFalse(policy.budget(for: .backgroundLocationCrawl).shouldYield)
        XCTAssertTrue(policy.budget(
            for: .backgroundLocationCrawl,
            signals: LibraryWorkloadSignals(hasVisibleMediaDemand: true)
        ).shouldYield)
        XCTAssertTrue(policy.budget(
            for: .backgroundLocationCrawl,
            signals: LibraryWorkloadSignals(hasActiveUserInitiatedTransfer: true)
        ).shouldYield)
    }
}
