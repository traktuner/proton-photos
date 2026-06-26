import SwiftUI

/// Full-screen centered loading state with an optional caption. Uses the native indeterminate `ProgressView`
/// and semantic styles so it adapts to appearance + Dynamic Type. (The former custom `ProtonPrimaryButtonStyle`
/// and `ProtonSpinner` were removed — the app uses native `.glassProminent` buttons and `ProgressView`.)
public struct ProtonLoadingView: View {
    private let caption: String?
    public init(caption: String? = nil) { self.caption = caption }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
