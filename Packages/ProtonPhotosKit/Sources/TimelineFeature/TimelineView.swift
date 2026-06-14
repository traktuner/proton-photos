import SwiftUI
import PhotosCore
import DesignSystem
import MediaCache

public struct TimelineView: View {
    @State private var model: TimelineViewModel
    /// Called when a photo is activated (opened). The host provides the viewer.
    private let onOpen: (PhotoItem, [PhotoItem]) -> Void

    public init(model: TimelineViewModel, onOpen: @escaping (PhotoItem, [PhotoItem]) -> Void = { _, _ in }) {
        _model = State(initialValue: model)
        self.onOpen = onOpen
    }

    // Apple-Photos-like grid: equal square cells, uniform hairline gaps.
    private let spacing: CGFloat = 2
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: spacing)]
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProtonLoadingView(caption: "Building your library…")
            case .empty:
                emptyState
            case let .failed(message):
                errorState(message)
            case let .loaded(sections):
                grid(sections)
            }
        }
        .background(ProtonColor.backgroundNorm)
        .task { await model.load() }
    }

    private func grid(_ sections: [TimelineSection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: spacing) {
                            ForEach(section.items) { item in
                                PhotoThumbnailCell(item: item, feed: model.feed)
                                    .onAppear { model.cellAppeared(item.uid) }
                                    .onTapGesture { onOpen(item, section.items) }
                            }
                        }
                        .padding(.horizontal, spacing)
                    } header: {
                        sectionHeader(section.title)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(ProtonColor.textHint)
            Text("No photos yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text("Photos you upload to Proton will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(ProtonColor.textWeak)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(ProtonColor.warning)
            Text("Couldn’t load your library")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(ProtonColor.textWeak)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Retry") { Task { await model.load() } }
                .buttonStyle(.proton)
                .frame(width: 140)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// A single uniform square grid cell. Loads its thumbnail from the shared feed (cache-first).
struct PhotoThumbnailCell: View {
    let item: PhotoItem
    let feed: ThumbnailFeed

    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                } else {
                    ProtonColor.backgroundStrong
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) { videoBadge }
            .overlay(alignment: .topTrailing) { liveBadge }
            .contentShape(Rectangle())
            .task(id: item.uid) {
                if image == nil { image = await feed.image(for: item.uid) }
            }
    }

    @ViewBuilder private var videoBadge: some View {
        if item.isVideo {
            HStack(spacing: 3) {
                Image(systemName: "video.fill").font(.system(size: 9))
                if let d = item.durationSeconds { Text(Self.duration(d)).font(.system(size: 10, weight: .medium)) }
            }
            .foregroundStyle(.white)
            .shadow(radius: 1)
            .padding(5)
        }
    }

    @ViewBuilder private var liveBadge: some View {
        if item.isLivePhoto {
            Image(systemName: "livephoto")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(radius: 1)
                .padding(5)
        }
    }

    private static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
