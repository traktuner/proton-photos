import SwiftUI

public enum LibraryTitleStatus: Equatable, Sendable {
    case idle
    case activity
    case offline
    case onlineRestored
}

/// Compact title treatment for a library surface that may still be ingesting previews.
///
/// The status slot is always reserved and fades between states, so title chrome never shifts when background
/// activity starts, connectivity drops, or connectivity returns.
public struct LibraryTitleStatusLabel: View {
    private let title: String
    private let status: LibraryTitleStatus
    private let accessibilityLabel: String
    private let titleFont: Font?

    public init(title: String, status: LibraryTitleStatus, accessibilityLabel: String, titleFont: Font? = nil) {
        self.title = title
        self.status = status
        self.accessibilityLabel = accessibilityLabel
        self.titleFont = titleFont
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(titleFont)
                .lineLimit(1)
            LibraryTitleStatusIndicator(status: status, accessibilityLabel: accessibilityLabel)
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeInOut(duration: 0.16), value: status)
    }
}

public struct LibraryTitleStatusIndicator: View {
    private let status: LibraryTitleStatus
    private let accessibilityLabel: String

    public init(status: LibraryTitleStatus, accessibilityLabel: String) {
        self.status = status
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        ZStack {
            activitySpinner
                .opacity(status == .activity ? 1 : 0)
            statusIcon("bolt.slash")
                .opacity(status == .offline ? 1 : 0)
            statusIcon("bolt.fill")
                .opacity(status == .onlineRestored ? 1 : 0)
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHidden(status == .idle)
        .animation(.easeInOut(duration: 0.16), value: status)
    }

    private var activitySpinner: some View {
        ProgressView()
            .controlSize(.small)
            .tint(ProtonColor.primary)
    }

    private func statusIcon(_ name: String) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ProtonColor.textWeak)
    }
}
