import Foundation
import Testing
@testable import ProtonDriveBackend

@Suite("Proton request governor")
struct ProtonRequestGovernorTests {
    @Test func immediateWorkOvertakesQueuedBackgroundWork() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .api, priority: .background)
        let order = OrderRecorder()

        let background = Task {
            let permit = try await governor.acquire(scope: .api, priority: .background)
            await order.append("background")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }

        let immediate = Task {
            let permit = try await governor.acquire(scope: .api, priority: .immediate)
            await order.append("immediate")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().api.queued == 2 }

        await governor.finish(first, statusCode: 200)
        try await immediate.value
        try await background.value
        #expect(await order.values == ["immediate", "background"])
    }

    @Test func rateLimitReducesConcurrencyAndSuccessesRecoverIt() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(
            initial: 4,
            maximum: 6,
            successWindow: 2
        ))

        for _ in 0 ..< 3 {
            let permit = try await governor.acquire(scope: .api)
            await governor.finish(permit, statusCode: 200)
        }
        let limited = try await governor.acquire(scope: .api)
        await governor.finish(limited, statusCode: 429, retryAfter: 0.001)

        var snapshot = await governor.snapshot().api
        #expect(snapshot.concurrencyLimit == 2)
        #expect(snapshot.rateLimitedLastMinute == 1)
        #expect(snapshot.sustainableRateBeforeLastLimit == 3)
        #expect(snapshot.successfulRequestsPerSecondBeforeLastLimit == 3)
        #expect(snapshot.admissionInterval > 0)

        for _ in 0 ..< 2 {
            let permit = try await governor.acquire(scope: .api)
            await governor.finish(permit, statusCode: 200)
        }
        snapshot = await governor.snapshot().api
        #expect(snapshot.concurrencyLimit == 3)
    }

    @Test func cancellingQueuedRequestDoesNotLeakAWaiter() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .api)
        let queued = Task { try await governor.acquire(scope: .api, priority: .maintenance) }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }

        queued.cancel()
        do {
            _ = try await queued.value
            Issue.record("cancelled acquisition unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        #expect(await governor.snapshot().api.queued == 0)
        await governor.finish(first, statusCode: 200)
        #expect(await governor.snapshot().api.inFlight == 0)
    }

    @Test func finishingSamePermitTwiceCannotReleaseAnotherRequest() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .api)
        await governor.finish(first, statusCode: 200)
        let second = try await governor.acquire(scope: .api)
        let third = Task { try await governor.acquire(scope: .api) }
        try await Self.waitUntil { await governor.snapshot().api.queued == 1 }

        await governor.finish(first, statusCode: 200)
        #expect(await governor.snapshot().api.inFlight == 1)
        #expect(await governor.snapshot().api.queued == 1)

        third.cancel()
        _ = try? await third.value
        await governor.finish(second, statusCode: 200)
    }

    @Test func sdkPriorityScopeSurvivesNativeTaskBoundary() async throws {
        let governor = ProtonRequestGovernor(configuration: Self.configuration(initial: 1, maximum: 1))
        let first = try await governor.acquire(scope: .storageDownload, priority: .background)
        let order = OrderRecorder()
        let background = Task {
            let permit = try await governor.acquire(scope: .storageDownload, priority: .background)
            await order.append("background")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 1 }

        let scope = await governor.beginPriorityScope(.immediate)
        let sdkCallback = Task {
            let permit = try await ProtonRequestContext.$priority.withValue(.maintenance) {
                try await governor.acquire(scope: .storageDownload)
            }
            await order.append("visible")
            await governor.finish(permit, statusCode: 200)
        }
        try await Self.waitUntil { await governor.snapshot().storageDownload.queued == 2 }
        await governor.finish(first, statusCode: 200)

        try await sdkCallback.value
        await governor.endPriorityScope(scope)
        try await background.value
        #expect(await order.values == ["visible", "background"])
    }

    @Test func retryAfterParsesSecondsAndHTTPDate() throws {
        let url = try #require(URL(string: "https://drive-api.proton.me/test"))
        let seconds = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "7"]
        ))
        #expect(ProtonRetryAfter.seconds(from: seconds) == 7)

        let now = Date(timeIntervalSince1970: 784_111_777)
        let date = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "Sun, 06 Nov 1994 08:49:47 GMT"]
        ))
        #expect(ProtonRetryAfter.seconds(from: date, now: now) == 10)
    }

    private static func configuration(
        initial: Int,
        maximum: Int,
        successWindow: Int = 32
    ) -> ProtonRequestGovernor.Configuration {
        let scope = ProtonRequestGovernor.Configuration.Scope(
            initialConcurrency: initial,
            maximumConcurrency: maximum
        )
        return .init(
            api: scope,
            storageDownload: scope,
            storageUpload: scope,
            successWindowForIncrease: successWindow,
            starvationPromotionInterval: 10,
            priorityScopeLifetime: 60
        )
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition did not become true before timeout")
    }
}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
