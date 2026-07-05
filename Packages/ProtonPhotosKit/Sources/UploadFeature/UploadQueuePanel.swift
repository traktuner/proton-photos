import SwiftUI
import PhotosCore
import UploadCore

/// Compact upload-queue panel: total progress, per-item status, and per-item retry/cancel/pause.
public struct UploadQueuePanel: View {
    @Bindable private var coordinator: UploadCoordinator

    public init(coordinator: UploadCoordinator) {
        self._coordinator = Bindable(coordinator)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if coordinator.items.isEmpty {
                empty
            } else {
                List {
                    ForEach(coordinator.items) { item in
                        row(item)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        #if os(macOS)
        .frame(width: 380, height: coordinator.items.isEmpty ? 220 : 360)
        #else
        .frame(maxWidth: .infinity, maxHeight: coordinator.items.isEmpty ? 220 : 360)
        #endif
        // No .presentationBackground override → the popover keeps its native Liquid Glass chrome.
    }

    private var header: some View {
        let s = coordinator.stats
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.string("upload.queue_title"), systemImage: "square.and.arrow.up")
                    .font(.headline)
                Spacer()
                Button(L10n.string("upload.clear_finished")) { coordinator.clearFinished() }
                    .buttonStyle(.borderless)
                    .disabled(!UploadQueuePresentation.canClearFinished(s))
            }
            if s.total > 0 {
                ProgressView(value: s.totalProgress)
                Text(s.summaryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(L10n.string("upload.no_uploads"), systemImage: "tray")
        } description: {
            Text(L10n.string("upload.empty_description"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: UploadItem) -> some View {
        HStack(spacing: 10) {
            icon(for: item)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.callout)
                    .lineLimit(1).truncationMode(.middle)
                statusLine(item)
            }
            Spacer()
            actions(for: item)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func statusLine(_ item: UploadItem) -> some View {
        if case let .uploading(p) = item.state {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: p)
                    .frame(maxWidth: 170)
                Text(L10n.string("upload.state_uploading \(Int(p * 100))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(item.state.label)
                .font(.caption)
                .foregroundStyle(color(for: item.state))
                .lineLimit(2)
        }
    }

    @ViewBuilder private func icon(for item: UploadItem) -> some View {
        switch item.state {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case let .skipped(reason):
            Image(systemName: reason.countsAsBackedUp ? "checkmark.circle" : "slash.circle")
                .foregroundStyle(reason.countsAsBackedUp ? .green : .secondary)
        case .failed:
            Image(systemName: item.partialSuccess ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .foregroundStyle(item.partialSuccess ? .yellow : .red)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .paused:
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        default:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private func actions(for item: UploadItem) -> some View {
        HStack(spacing: 6) {
            ForEach(UploadQueuePresentation.rowActions(for: item, capabilities: coordinator.uploadCapabilities), id: \.self) { action in
                Button { perform(action, item: item) } label: {
                    Image(systemName: symbol(for: action))
                }
                .buttonStyle(.borderless)
                .help(help(for: action))
                .accessibilityLabel("\(help(for: action)) \(item.displayName)")
            }
        }
        .font(.system(size: 12))
    }

    private func color(for state: UploadItemState) -> Color {
        switch state {
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }

    private func perform(_ action: UploadQueueRowAction, item: UploadItem) {
        switch action {
        case .cancel: coordinator.cancel(item.id)
        case .pause: coordinator.pause(item.id)
        case .resume: coordinator.resume(item.id)
        case .retry: coordinator.retry(item.id)
        }
    }

    private func symbol(for action: UploadQueueRowAction) -> String {
        switch action {
        case .cancel: "xmark"
        case .pause: "pause"
        case .resume: "play"
        case .retry: "arrow.clockwise"
        }
    }

    private func help(for action: UploadQueueRowAction) -> String {
        switch action {
        case .cancel: L10n.string("action.cancel")
        case .pause: L10n.string("upload.action_pause")
        case .resume: L10n.string("upload.action_resume")
        case .retry: L10n.string("action.retry")
        }
    }
}
