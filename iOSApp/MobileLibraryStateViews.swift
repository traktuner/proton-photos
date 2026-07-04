import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineCore

/// The polished first-load / onboarding overlay, shown over the (still-drawing) grid while `LibraryLoadState`
/// reports a loading phase. It never fakes a percentage — indeterminate progress plus a factual, calm status.
///
/// Before the inventory resolves there is nothing behind it, so it is opaque; once the grid is mounting
/// underneath (`loadingContent`) it becomes a translucent glass scrim, so the photos visibly build behind
/// the spinner until the first full screen is ready.
struct MobileLibraryLoadingView: View {
    let state: LibraryLoadState

    var body: some View {
        VStack(spacing: 18) {
            MobileBrandLogo(height: 44)

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
        .background { scrim }
    }

    @ViewBuilder private var scrim: some View {
        if case .loadingContent = state {
            // The grid is already building underneath — let it show through.
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
        } else {
            ProtonColor.backgroundNorm.ignoresSafeArea()
        }
    }

    private var title: String {
        switch state {
        case .preparingInventory:
            return String(localized: "loading.library_title")
        case let .loadingContent(_, usingCachedInventory):
            return usingCachedInventory
                ? String(localized: "loading.updating_title")
                : String(localized: "loading.preparing_title")
        case .contentReady, .empty, .failed:
            return String(localized: "loading.library_title")
        }
    }

    /// Once the count is known it appears calmly (numeric transition, monospaced digits) — no layout jump.
    private var detail: String? {
        guard let count = state.knownCount, count > 0 else { return nil }
        return String(localized: "loading.preparing_count \(count)")
    }
}

/// Shown only when the library truly holds no photos — the one case where a blank grid is acceptable.
struct MobileEmptyLibraryView: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text("empty.title")
            } icon: {
                MobileBrandLogo(height: 40)
            }
        } description: {
            Text("empty.message \(ProductBrand.displayName)")
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
            Label("error.library_load_failed", systemImage: "exclamationmark.icloud")
        } description: {
            Text(message)
        } actions: {
            if retryable {
                Button(String(localized: "action.try_again"), action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(ProtonColor.primary)
            }
        }
    }
}

/// The Proton Photos brand mark from `Branding/` (bundled via the asset catalog), template-rendered so it
/// follows the brand tint on any background.
struct MobileBrandLogo: View {
    var height: CGFloat

    var body: some View {
        Image("BrandLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(ProtonColor.primary)
            .accessibilityHidden(true)
    }
}
