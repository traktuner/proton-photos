import Foundation

/// Platform-neutral state machine for the library's first-load / onboarding experience.
///
/// This is the single shared policy that both platform shells drive so a "loading" bug is fixed once
/// in Core and behaves identically on macOS, iOS, and iPadOS. It deliberately models only the
/// *library presentation* lifecycle after sign-in - auth and backend-build orchestration stay in each
/// app's shell because their UI differs per platform (Safari fork on iOS, `NSWorkspace` on macOS).
///
/// It distinguishes exactly the phases the product requires:
///  1. `preparingInventory` - signed in, but the photo inventory (count) is not known yet.
///  2. `loadingContent`      - the inventory count is known (from a cached snapshot or a fresh load) but the
///                             first on-screen thumbnails have not been drawn. This is the "Preparing N photos…"
///                             phase; the shell must NOT show a blank grid here.
///  3. `contentReady`        - the first visible thumbnails are drawn; the grid is safe to present.
///  4. `empty`               - the library finished loading and truly holds no photos.
///  5. `failed`              - loading failed; `retryable` drives a retry affordance.
///
/// The type carries no percentage: first-load progress cannot be measured without faking precision, so the
/// shell shows indeterminate progress plus the factual `knownCount`. Feed/crawl coverage is deliberately not
/// folded in here - it is a *background* signal, not "% of the library loaded".
public enum LibraryLoadState: Equatable, Sendable {
    /// Signed in; the backend/inventory is still being prepared. No count yet → indeterminate spinner only.
    case preparingInventory

    /// Inventory count is known but the first visible thumbnails are not drawn yet.
    /// `usingCachedInventory` distinguishes a stale cached snapshot from a fresh server load, so the shell can
    /// phrase the status truthfully ("Preparing…" vs "Updating…") without claiming false precision.
    case loadingContent(count: Int, usingCachedInventory: Bool)

    /// The first visible thumbnails are drawn - the grid is presentable. `count` is the latest known total.
    case contentReady(count: Int)

    /// The library finished loading and contains no photos.
    case empty

    /// Loading failed before any content could be presented. `retryable` requests a retry affordance.
    case failed(message: String, retryable: Bool)

    /// The initial state entered on sign-in (and on every reset).
    public static let initial: LibraryLoadState = .preparingInventory
}

public extension LibraryLoadState {
    /// The known photo count once the inventory has resolved (cached or fresh); `nil` while still preparing or
    /// after a failure. `empty` reports `0` so the shell can render "0 photos" calmly.
    var knownCount: Int? {
        switch self {
        case let .loadingContent(count, _): return count
        case let .contentReady(count): return count
        case .empty: return 0
        case .preparingInventory, .failed: return nil
        }
    }

    /// True while the shell must show the onboarding/loading UI (spinner + factual status), NOT the grid.
    var isLoading: Bool {
        switch self {
        case .preparingInventory, .loadingContent: return true
        case .contentReady, .empty, .failed: return false
        }
    }

    /// True once the grid is safe to present (first thumbnails drawn). The shell shows the timeline here.
    var isContentReady: Bool {
        if case .contentReady = self { return true }
        return false
    }

    /// True once loading settled on a truly empty library - the only case where a blank grid is acceptable.
    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    /// The failure details, if the load failed before any content was presented.
    var failure: (message: String, retryable: Bool)? {
        if case let .failed(message, retryable) = self { return (message, retryable) }
        return nil
    }

    /// True once loading has reached a terminal, presentable state (grid / empty / error) - i.e. no spinner.
    var hasSettled: Bool {
        switch self {
        case .contentReady, .empty, .failed: return true
        case .preparingInventory, .loadingContent: return false
        }
    }
}

/// Events that drive `LibraryLoadState`. All inputs are plain scalars so the reducer stays a pure, trivially
/// testable value transform with no dependency on the feed/backend/crawl machinery.
public enum LibraryLoadEvent: Equatable, Sendable {
    /// The inventory count became known - from either a cached snapshot (`cached: true`) or a fresh server load
    /// (`cached: false`). A count of `0` means the library is empty.
    case inventoryResolved(count: Int, cached: Bool)

    /// The grid reported that the first visible thumbnails are drawn.
    case firstContentReady

    /// Loading failed. `retryable` requests a retry affordance in the shell.
    case failed(message: String, retryable: Bool)

    /// A new session / sign-out / manual retry restarts the lifecycle at `preparingInventory`.
    case reset
}

/// The pure reducer. Kept separate from the state so the whole policy is one referentially-transparent function
/// that macOS and iOS share verbatim.
public enum LibraryLoadPolicy {
    public static func reduce(_ state: LibraryLoadState, _ event: LibraryLoadEvent) -> LibraryLoadState {
        switch event {
        case .reset:
            return .preparingInventory

        case let .failed(message, retryable):
            // A failure only surfaces when there is nothing presentable yet (still preparing, or a prior
            // failure). Once an inventory has resolved - even a stale cached one still drawing, or a settled
            // empty/ready grid - a later (background refresh) failure must not replace it: the user keeps their
            // photos and browses offline instead of hitting an error wall.
            switch state {
            case .preparingInventory, .failed:
                return .failed(message: message, retryable: retryable)
            case .loadingContent, .contentReady, .empty:
                return state
            }

        case let .inventoryResolved(count, cached):
            guard count > 0 else { return .empty }
            // Already presenting content → keep presenting, just carry the latest count.
            if case .contentReady = state { return .contentReady(count: count) }
            return .loadingContent(count: count, usingCachedInventory: cached)

        case .firstContentReady:
            switch state {
            case let .loadingContent(count, _):
                return .contentReady(count: count)
            case .contentReady:
                return state
            // First content cannot precede a known, non-empty inventory; ignore in every other state so a stray
            // signal can never reveal an unprepared or empty grid.
            case .preparingInventory, .empty, .failed:
                return state
            }
        }
    }
}
