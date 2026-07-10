import Foundation
import PhotosCore

/// UI-ready projection of an `MLSmartSearchSnapshot`.
///
/// One localized wording implementation for every platform (strings resolve against the
/// package catalog via `L10n`), mirroring how `BackupStatus` keeps macOS and iOS wording
/// identical. Views render these fields verbatim and never derive their own status copy.
public struct MLSmartSearchPresentation: Sendable, Equatable {
    public let statusText: String
    public let detailText: String?
    /// Determinate progress in `[0, 1]`, or `nil` when no progress bar should show.
    public let progressFraction: Double?
    public let indexedCount: Int
    public let totalCount: Int
    public let installedSizeText: String?
    public let canRetry: Bool
    public let isBusy: Bool

    public init(snapshot: MLSmartSearchSnapshot) {
        var detail: String?
        var fraction: Double?
        var indexed = 0
        var total = 0
        var retry = false

        let status: String
        switch snapshot.phase {
        case .disabled:
            status = L10n.string("mlsearch.status_disabled")
        case .notInstalled(let downloadable):
            status = downloadable
                ? L10n.string("mlsearch.status_not_installed")
                : L10n.string("mlsearch.status_not_downloadable")
        case .downloading(let progress):
            status = L10n.string("mlsearch.status_downloading")
            fraction = progress.fraction
        case .verifying:
            status = L10n.string("mlsearch.status_verifying")
        case .installing:
            status = L10n.string("mlsearch.status_installing")
        case .preparingModel:
            status = L10n.string("mlsearch.status_preparing")
        case .indexing(let progress):
            status = L10n.string("mlsearch.status_indexing")
            fraction = progress.totalAssets > 0 ? progress.fraction : nil
            indexed = progress.indexed + progress.alreadyIndexed
            total = progress.totalAssets
            detail = L10n.string("mlsearch.indexed_count \(indexed) \(total)")
        case .ready(let coverage):
            indexed = coverage.indexed
            total = coverage.total
            if coverage.isComplete, coverage.total > 0 {
                status = L10n.string("mlsearch.status_complete")
            } else {
                status = L10n.string("mlsearch.status_ready")
            }
            if total > 0 {
                detail = L10n.string("mlsearch.indexed_count \(indexed) \(total)")
            }
        case .switchingModel:
            status = L10n.string("mlsearch.status_switching")
        case .deleting:
            status = L10n.string("mlsearch.status_deleting")
        case .failed(let failure):
            switch failure.kind {
            case .download: status = L10n.string("mlsearch.status_failed_download")
            case .verification: status = L10n.string("mlsearch.status_failed_verification")
            case .installation: status = L10n.string("mlsearch.status_failed_installation")
            case .modelLoad: status = L10n.string("mlsearch.status_failed_model")
            case .storage: status = L10n.string("mlsearch.status_failed_storage")
            }
            retry = failure.isRetryable
        }

        self.statusText = status
        self.detailText = detail
        self.progressFraction = fraction
        self.indexedCount = indexed
        self.totalCount = total
        self.installedSizeText = snapshot.installedModelBytes > 0
            ? ByteCountFormatter.string(fromByteCount: snapshot.installedModelBytes, countStyle: .file)
            : nil
        self.canRetry = retry
        self.isBusy = snapshot.phase.isBusy
    }

    /// Shared privacy statement shown in every Smart Search settings surface.
    public static var privacyStatement: String {
        L10n.string("mlsearch.privacy_note")
    }

    /// Warning line for developer-only models.
    public static var developerModelNote: String {
        L10n.string("mlsearch.developer_model_note")
    }
}
