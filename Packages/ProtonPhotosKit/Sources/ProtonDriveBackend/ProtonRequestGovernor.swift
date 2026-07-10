import Foundation

enum ProtonRequestScope: CaseIterable, Sendable {
    case api
    case storageDownload
    case storageUpload
}

enum ProtonRequestPriority: Int, CaseIterable, Sendable, Comparable {
    case immediate = 0
    case userInitiated = 1
    case foregroundPrefetch = 2
    case background = 3
    case maintenance = 4

    static func < (lhs: ProtonRequestPriority, rhs: ProtonRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ProtonRequestContext {
    @TaskLocal static var priority: ProtonRequestPriority = .userInitiated
}

struct ProtonRequestGovernorSnapshot: Sendable, Equatable {
    struct Scope: Sendable, Equatable {
        let inFlight: Int
        let queued: Int
        let concurrencyLimit: Int
        let admissionInterval: TimeInterval
        let admittedLastSecond: Int
        let admittedLastMinute: Int
        let succeededLastSecond: Int
        let succeededLastMinute: Int
        let rateLimitedLastMinute: Int
        let sustainableRateBeforeLastLimit: Int
        let successfulRequestsPerSecondBeforeLastLimit: Double
    }

    let api: Scope
    let storageDownload: Scope
    let storageUpload: Scope

    subscript(scope: ProtonRequestScope) -> Scope {
        switch scope {
        case .api: api
        case .storageDownload: storageDownload
        case .storageUpload: storageUpload
        }
    }
}

/// One adaptive admission point for every Proton API and storage request.
///
/// The governor does not guess a fixed server quota. It observes successful admissions and 429
/// responses, applies server-directed cooldowns, and uses additive increase/multiplicative decrease
/// to find a sustainable rate again. Feature-level work remains concurrent; only network starts are
/// queued here so visible work can overtake background prefetch and backup requests.
actor ProtonRequestGovernor {
    struct Permit: Sendable {
        fileprivate let id: UUID
        fileprivate let scope: ProtonRequestScope
    }

    struct PriorityScope: Sendable {
        fileprivate let id: UUID
    }

    struct Configuration: Sendable {
        struct Scope: Sendable {
            let initialConcurrency: Int
            let maximumConcurrency: Int
        }

        let api: Scope
        let storageDownload: Scope
        let storageUpload: Scope
        let successWindowForIncrease: Int
        let starvationPromotionInterval: TimeInterval
        let priorityScopeLifetime: TimeInterval

        static let production = Configuration(
            api: Scope(initialConcurrency: 4, maximumConcurrency: 8),
            storageDownload: Scope(initialConcurrency: 4, maximumConcurrency: 8),
            storageUpload: Scope(initialConcurrency: 2, maximumConcurrency: 4),
            successWindowForIncrease: 32,
            starvationPromotionInterval: 10,
            priorityScopeLifetime: 60
        )

        func scope(_ value: ProtonRequestScope) -> Scope {
            switch value {
            case .api: api
            case .storageDownload: storageDownload
            case .storageUpload: storageUpload
            }
        }
    }

    private struct Waiter {
        let id: UUID
        let priority: ProtonRequestPriority
        let sequence: UInt64
        let enqueuedAt: Date
        let continuation: CheckedContinuation<Permit, Error>
    }

    private struct ScopeState {
        var inFlight = 0
        var activePermitIDs: Set<UUID> = []
        var concurrencyLimit: Int
        let maximumConcurrency: Int
        var admissionInterval: TimeInterval = 0
        var nextAdmission = Date.distantPast
        var cooldownUntil = Date.distantPast
        var successStreak = 0
        var rateLimitStreak = 0
        var waiters: [Waiter] = []
        var admitted: [Date] = []
        var succeeded: [Date] = []
        var rateLimited: [Date] = []
        var sustainableRateBeforeLastLimit = 0
        var successfulRequestsPerSecondBeforeLastLimit: Double = 0

        init(configuration: Configuration.Scope) {
            concurrencyLimit = max(1, configuration.initialConcurrency)
            maximumConcurrency = max(concurrencyLimit, configuration.maximumConcurrency)
        }
    }

    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private var states: [ProtonRequestScope: ScopeState]
    private var sequence: UInt64 = 0
    private var wakeTasks: [ProtonRequestScope: Task<Void, Never>] = [:]
    private var priorityScopes: [UUID: (priority: ProtonRequestPriority, expiresAt: Date)] = [:]

    init(
        configuration: Configuration = .production,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.now = now
        states = Dictionary(uniqueKeysWithValues: ProtonRequestScope.allCases.map {
            ($0, ScopeState(configuration: configuration.scope($0)))
        })
    }

    func acquire(
        scope: ProtonRequestScope,
        priority: ProtonRequestPriority = ProtonRequestContext.priority
    ) async throws -> Permit {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sequence &+= 1
                prunePriorityScopes()
                let scopedPriority = priorityScopes.values.map(\.priority).min() ?? priority
                let effectivePriority = min(priority, scopedPriority)
                states[scope]?.waiters.append(Waiter(
                    id: id,
                    priority: effectivePriority,
                    sequence: sequence,
                    enqueuedAt: now(),
                    continuation: continuation
                ))
                drain(scope)
            }
        } onCancel: {
            Task { await self.cancel(id: id, scope: scope) }
        }
    }

    func beginPriorityScope(_ priority: ProtonRequestPriority) -> PriorityScope {
        let scope = PriorityScope(id: UUID())
        priorityScopes[scope.id] = (
            priority,
            now().addingTimeInterval(configuration.priorityScopeLifetime)
        )
        return scope
    }

    func endPriorityScope(_ scope: PriorityScope) {
        priorityScopes.removeValue(forKey: scope.id)
    }

    func finish(
        _ permit: Permit,
        statusCode: Int?,
        retryAfter: TimeInterval? = nil
    ) {
        guard var state = states[permit.scope], state.activePermitIDs.remove(permit.id) != nil else { return }
        state.inFlight = max(0, state.inFlight - 1)
        let timestamp = now()

        if statusCode == 429 {
            state.rateLimited.append(timestamp)
            let successesLastSecond = Self.countRecent(state.succeeded, since: timestamp.addingTimeInterval(-1))
            let successesLastMinute = Self.countRecent(state.succeeded, since: timestamp.addingTimeInterval(-60))
            state.sustainableRateBeforeLastLimit = successesLastMinute
            state.successfulRequestsPerSecondBeforeLastLimit = max(
                Double(successesLastSecond),
                Double(successesLastMinute) / 60
            )
            state.rateLimitStreak += 1
            state.successStreak = 0
            state.concurrencyLimit = max(1, state.concurrencyLimit / 2)

            let fallback = min(30, pow(2, Double(min(state.rateLimitStreak, 5))))
            let cooldown = max(1, min(retryAfter ?? fallback, 120))
            state.cooldownUntil = max(state.cooldownUntil, timestamp.addingTimeInterval(cooldown))
            let observedInterval = 1 / max(0.1, state.successfulRequestsPerSecondBeforeLastLimit * 0.8)
            state.admissionInterval = max(0.025, min(2, max(state.admissionInterval * 2, observedInterval)))
            DebugLog.log(
                "[RequestGovernor] 429 scope=\(permit.scope) cooldownMs=\(Int(cooldown * 1_000)) "
                    + "limit=\(state.concurrencyLimit) intervalMs=\(Int(state.admissionInterval * 1_000)) "
                    + "observedRps=\(String(format: "%.1f", state.successfulRequestsPerSecondBeforeLastLimit)) "
                    + "success60s=\(successesLastMinute)"
            )
        } else if let statusCode, (200 ... 399).contains(statusCode) {
            state.succeeded.append(timestamp)
            state.successStreak += 1
            if state.successStreak >= configuration.successWindowForIncrease {
                state.successStreak = 0
                state.rateLimitStreak = 0
                state.concurrencyLimit = min(state.maximumConcurrency, state.concurrencyLimit + 1)
                state.admissionInterval *= 0.8
                if state.admissionInterval < 0.01 { state.admissionInterval = 0 }
            }
        }

        Self.prune(&state, now: timestamp)
        states[permit.scope] = state
        drain(permit.scope)
    }

    func snapshot() -> ProtonRequestGovernorSnapshot {
        let timestamp = now()
        return ProtonRequestGovernorSnapshot(
            api: snapshot(.api, now: timestamp),
            storageDownload: snapshot(.storageDownload, now: timestamp),
            storageUpload: snapshot(.storageUpload, now: timestamp)
        )
    }

    private func snapshot(_ scope: ProtonRequestScope, now timestamp: Date) -> ProtonRequestGovernorSnapshot.Scope {
        guard var state = states[scope] else {
            return .init(
                inFlight: 0, queued: 0, concurrencyLimit: 1, admissionInterval: 0,
                admittedLastSecond: 0, admittedLastMinute: 0, succeededLastSecond: 0,
                succeededLastMinute: 0, rateLimitedLastMinute: 0,
                sustainableRateBeforeLastLimit: 0,
                successfulRequestsPerSecondBeforeLastLimit: 0
            )
        }
        Self.prune(&state, now: timestamp)
        states[scope] = state
        return .init(
            inFlight: state.inFlight,
            queued: state.waiters.count,
            concurrencyLimit: state.concurrencyLimit,
            admissionInterval: state.admissionInterval,
            admittedLastSecond: Self.countRecent(state.admitted, since: timestamp.addingTimeInterval(-1)),
            admittedLastMinute: state.admitted.count,
            succeededLastSecond: Self.countRecent(state.succeeded, since: timestamp.addingTimeInterval(-1)),
            succeededLastMinute: state.succeeded.count,
            rateLimitedLastMinute: state.rateLimited.count,
            sustainableRateBeforeLastLimit: state.sustainableRateBeforeLastLimit,
            successfulRequestsPerSecondBeforeLastLimit: state.successfulRequestsPerSecondBeforeLastLimit
        )
    }

    private func cancel(id: UUID, scope: ProtonRequestScope) {
        guard var state = states[scope],
              let index = state.waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = state.waiters.remove(at: index)
        states[scope] = state
        waiter.continuation.resume(throwing: CancellationError())
        drain(scope)
    }

    private func drain(_ scope: ProtonRequestScope) {
        guard var state = states[scope] else { return }
        let timestamp = now()

        while state.inFlight < state.concurrencyLimit, !state.waiters.isEmpty {
            let readyAt = max(state.cooldownUntil, state.nextAdmission)
            guard readyAt <= timestamp else {
                states[scope] = state
                scheduleWake(scope, at: readyAt)
                return
            }

            let index = bestWaiterIndex(in: state.waiters, now: timestamp)
            let waiter = state.waiters.remove(at: index)
            state.inFlight += 1
            state.activePermitIDs.insert(waiter.id)
            state.admitted.append(timestamp)
            state.nextAdmission = timestamp.addingTimeInterval(state.admissionInterval)
            waiter.continuation.resume(returning: Permit(id: waiter.id, scope: scope))

            if state.admissionInterval > 0 {
                states[scope] = state
                scheduleWake(scope, at: state.nextAdmission)
                return
            }
        }

        states[scope] = state
        if state.waiters.isEmpty {
            wakeTasks[scope]?.cancel()
            wakeTasks[scope] = nil
        }
    }

    private func bestWaiterIndex(in waiters: [Waiter], now timestamp: Date) -> Int {
        waiters.indices.min { lhs, rhs in
            let left = effectivePriority(waiters[lhs], now: timestamp)
            let right = effectivePriority(waiters[rhs], now: timestamp)
            if left != right { return left < right }
            return waiters[lhs].sequence < waiters[rhs].sequence
        } ?? waiters.startIndex
    }

    private func effectivePriority(_ waiter: Waiter, now timestamp: Date) -> Int {
        guard waiter.priority != .immediate else { return 0 }
        let waited = max(0, timestamp.timeIntervalSince(waiter.enqueuedAt))
        let promotions = Int(waited / configuration.starvationPromotionInterval)
        return max(ProtonRequestPriority.userInitiated.rawValue, waiter.priority.rawValue - promotions)
    }

    private func scheduleWake(_ scope: ProtonRequestScope, at date: Date) {
        wakeTasks[scope]?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        wakeTasks[scope] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.wake(scope)
        }
    }

    private func wake(_ scope: ProtonRequestScope) {
        wakeTasks[scope] = nil
        drain(scope)
    }

    private func prunePriorityScopes() {
        let timestamp = now()
        priorityScopes = priorityScopes.filter { $0.value.expiresAt > timestamp }
    }

    private static func prune(_ state: inout ScopeState, now: Date) {
        let cutoff = now.addingTimeInterval(-60)
        state.admitted.removeAll { $0 < cutoff }
        state.succeeded.removeAll { $0 < cutoff }
        state.rateLimited.removeAll { $0 < cutoff }
    }

    private static func countRecent(_ values: [Date], since cutoff: Date) -> Int {
        values.lazy.filter { $0 >= cutoff }.count
    }
}

enum ProtonRetryAfter {
    static func seconds(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }

        for formatter in makeHTTPDateFormatters() {
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }

    private static func makeHTTPDateFormatters() -> [DateFormatter] {
        ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"].map {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = $0
            return formatter
        }
    }
}
