import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineCore

/// The first-load overlay, shown over the (still-drawing) grid while `LibraryLoadState` reports a
/// loading phase: the SAME breathing loading mark as the macOS launch veil (`DesignSystemCore`),
/// centered, no text - calm and quiet instead of a status readout.
///
/// Before the inventory resolves there is nothing behind it, so it is opaque; once the grid is
/// mounting underneath (`loadingContent`) it becomes a translucent glass scrim, so the photos
/// visibly build behind the mark until the first full screen is ready.
struct MobileLibraryLoadingView: View {
    let state: LibraryLoadState

    var body: some View {
        LoadingMark()
            .frame(width: 72, height: 72)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { scrim }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "loading.library_title"))
    }

    @ViewBuilder private var scrim: some View {
        if case .loadingContent = state {
            // The grid is already building underneath — let it show through.
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
        } else {
            ProtonColor.backgroundNorm.ignoresSafeArea()
        }
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
