import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineCore

/// The polished first-load / onboarding overlay, shown over the (still-drawing) grid while `LibraryLoadState`
/// reports a loading phase. It never fakes a percentage — indeterminate progress plus a factual, calm status.
struct MobileLibraryLoadingView: View {
    let state: LibraryLoadState

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(ProtonColor.primary)

            Text(title)
                .font(.headline)
                .foregroundStyle(ProtonColor.textNorm)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(ProtonColor.textWeak)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }

    private var title: String {
        switch state {
        case .preparingInventory:
            return String(localized: "Loading your library…")
        case let .loadingContent(_, usingCachedInventory):
            return usingCachedInventory
                ? String(localized: "Updating your library…")
                : String(localized: "Preparing your photos…")
        case .contentReady, .empty, .failed:
            return String(localized: "Loading your library…")
        }
    }

    /// Once the count is known it appears calmly (numeric transition, monospaced digits) — no layout jump.
    private var detail: String? {
        guard let count = state.knownCount, count > 0 else { return nil }
        return String(localized: "Preparing \(count) photos")
    }
}

/// Shown only when the library truly holds no photos — the one case where a blank grid is acceptable.
struct MobileEmptyLibraryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No photos yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Photos you back up to \(ProductBrand.displayName) will appear here.")
        }
    }
}

/// Shown when the first load fails; offers a retry when the failure is retryable.
struct MobileLibraryErrorView: View {
    let message: String
    let retryable: Bool
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load your library", systemImage: "exclamationmark.icloud")
        } description: {
            Text(message)
        } actions: {
            if retryable {
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(ProtonColor.primary)
            }
        }
    }
}
