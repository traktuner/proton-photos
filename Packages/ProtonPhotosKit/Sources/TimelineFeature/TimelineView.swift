import SwiftUI
import PhotosCore
import DesignSystem

public struct TimelineView: View {
    @State private var model: TimelineViewModel

    public init(model: TimelineViewModel) {
        _model = State(initialValue: model)
    }

    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 160), spacing: 3)]

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
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(section.items) { item in
                                PhotoThumbnailCell(item: item, model: model)
                            }
                        }
                        .padding(.horizontal, 12)
                    } header: {
                        sectionHeader(section.title)
                    }
                }
            }
            .padding(.vertical, 12)
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
        .background(ProtonColor.backgroundNorm.opacity(0.92))
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

/// A single grid cell. Loads its thumbnail lazily and overlays media badges.
struct PhotoThumbnailCell: View {
    let item: PhotoItem
    let model: TimelineViewModel

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(ProtonColor.backgroundStrong)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProtonSpinner(size: 18, lineWidth: 2)
            }
            badges
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .task(id: item.uid) {
            guard image == nil else { return }
            if let data = await model.thumbnailData(for: item.uid),
               let nsImage = NSImage(data: data) {
                image = nsImage
            }
        }
    }

    @ViewBuilder private var badges: some View {
        VStack {
            HStack {
                Spacer()
                if item.isLivePhoto {
                    badge("livephoto")
                }
            }
            Spacer()
            HStack {
                Spacer()
                if item.isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "video.fill").font(.system(size: 9))
                        if let d = item.durationSeconds {
                            Text(Self.duration(d)).font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .padding(5)
                }
            }
        }
        .padding(2)
    }

    private func badge(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(radius: 1)
            .padding(5)
    }

    private static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
