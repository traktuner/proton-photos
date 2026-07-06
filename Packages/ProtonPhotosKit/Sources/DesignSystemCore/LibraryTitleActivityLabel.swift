import SwiftUI

/// Compact title treatment for a library surface that may still be ingesting previews.
///
/// The spinner slot is always reserved and fades in/out, so title chrome never shifts when background
/// activity starts after the app returns from the background or a remote sync adds new items.
public struct LibraryTitleActivityLabel: View {
    private let title: String
    private let isActive: Bool
    private let activityAccessibilityLabel: String

    public init(title: String, isActive: Bool, activityAccessibilityLabel: String) {
        self.title = title
        self.isActive = isActive
        self.activityAccessibilityLabel = activityAccessibilityLabel
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            LibraryTitleActivityIndicator(isActive: isActive, accessibilityLabel: activityAccessibilityLabel)
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeInOut(duration: 0.16), value: isActive)
    }
}

public struct LibraryTitleActivityIndicator: View {
    private let isActive: Bool
    private let accessibilityLabel: String

    public init(isActive: Bool, accessibilityLabel: String) {
        self.isActive = isActive
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(ProtonColor.primary)
            .frame(width: 14, height: 14)
            .opacity(isActive ? 1 : 0)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHidden(!isActive)
            .animation(.easeInOut(duration: 0.16), value: isActive)
    }
}
