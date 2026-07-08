import Foundation

/// Lifecycle phase of an indexing run for a model epoch.
public enum MLIndexPhase: Sendable, Equatable {
    case idle
    case planning
    case indexing
    case completed
    case failed(message: String)
    case cancelled
}

/// A stable, user-readable snapshot of indexing progress for one model epoch.
///
/// Mirrors the `BackupSyncProgress` shape from `UploadCore`: integer counters that partition
/// every input asset exhaustively, a `Double` fraction, and an optional human message.
/// `Equatable` so SwiftUI/AppKit can diff cheaply without re-rendering on every tick.
public struct MLIndexProgress: Sendable, Equatable {
    public var phase: MLIndexPhase
    public var descriptor: MLModelDescriptor
    public var totalAssets: Int
    public var indexed: Int
    public var alreadyIndexed: Int
    public var permanentFailure: Int
    public var transientFailure: Int
    
    public init(
        phase: MLIndexPhase = .idle,
        descriptor: MLModelDescriptor,
        totalAssets: Int = 0,
        indexed: Int = 0,
        alreadyIndexed: Int = 0,
        permanentFailure: Int = 0,
        transientFailure: Int = 0
    ) {
        self.phase = phase
        self.descriptor = descriptor
        self.totalAssets = totalAssets
        self.indexed = indexed
        self.alreadyIndexed = alreadyIndexed
        self.permanentFailure = permanentFailure
        self.transientFailure = transientFailure
    }
    
    /// Assets whose fate is decided this run (success + both failure kinds + already-indexed).
    public var settled: Int { indexed + alreadyIndexed + permanentFailure + transientFailure }
    
    /// Completion fraction in `[0, 1]`. Guarded against divide-by-zero.
    public var fraction: Double {
        totalAssets > 0 ? Double(settled) / Double(totalAssets) : 0
    }
    
    /// `true` when every asset is accounted for and no transient failures remain.
    public var isComplete: Bool {
        phase == .completed || (settled >= totalAssets && transientFailure == 0)
    }
    
    /// One-line, locale-neutral summary suitable for a progress row.
    public var summary: String {
        let pct = Int((fraction * 100).rounded())
        switch phase {
        case .idle: return "\(descriptor.displayName): waiting"
        case .planning: return "\(descriptor.displayName): planning…"
        case .indexing: return "\(descriptor.displayName): \(settled)/\(totalAssets) (\(pct)%)"
        case .completed: return "\(descriptor.displayName): complete (\(indexed) indexed)"
        case .failed(let message): return "\(descriptor.displayName): failed — \(message)"
        case .cancelled: return "\(descriptor.displayName): cancelled"
        }
    }
}

extension MLIndexProgress {
    /// Apply a batch report to a mutable progress snapshot (cheap, allocation-free).
    public mutating func apply(_ report: MLIndexBatchReport) {
        indexed += report.indexed
        alreadyIndexed += report.skippedAlreadyIndexed
        permanentFailure += report.permanentFailure
        transientFailure += report.transientFailure
        if settled >= totalAssets, transientFailure == 0 {
            phase = .completed
        }
    }
}
