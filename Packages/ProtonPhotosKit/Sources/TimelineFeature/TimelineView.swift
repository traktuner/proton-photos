import SwiftUI
import PhotosCore
import DesignSystem
import MediaCache

public struct TimelineView: View {
    @State private var model: TimelineViewModel
    @Binding private var cellZoom: CGFloat
    /// Live visual zoom during a pinch (applied to the whole scroll viewport, so it stays lazy);
    /// the grid re-packs once on release. Anchored at the pinch location ("zoom in place").
    @State private var liveScale: CGFloat = 1
    @State private var pinchAnchor: UnitPoint = .center
    private let aspects: AspectRegistry
    private let onOpen: (PhotoItem, [PhotoItem]) -> Void

    public init(
        model: TimelineViewModel,
        aspects: AspectRegistry,
        cellZoom: Binding<CGFloat> = .constant(1),
        onOpen: @escaping (PhotoItem, [PhotoItem]) -> Void = { _, _ in }
    ) {
        _model = State(initialValue: model)
        self.aspects = aspects
        _cellZoom = cellZoom
        self.onOpen = onOpen
    }

    private let spacing: CGFloat = 2
    /// Base justified row height; scaled by the pinch zoom.
    private let baseRowHeight: CGFloat = 168

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
        GeometryReader { geo in
            let width = max(120, geo.size.width - spacing * 2)
            let rowHeight = baseRowHeight * cellZoom
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            JustifiedSection(
                                items: section.items,
                                width: width,
                                targetHeight: rowHeight,
                                spacing: spacing,
                                feed: model.feed,
                                aspects: aspects
                            ) { item in onOpen(item, model.allItems) }
                            .padding(.horizontal, spacing)
                        } header: {
                            sectionHeader(section.title)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scaleEffect(liveScale, anchor: pinchAnchor)   // live zoom on the viewport (stays lazy)
            .clipped()
            .gesture(pinch)
        }
    }

    /// Live, continuous pinch zoom: scale the viewport in place while pinching, then commit the new
    /// cell size on release so the grid re-packs (exactly like Apple Photos).
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                pinchAnchor = value.startAnchor
                liveScale = min(max(value.magnification, 0.4), 3.0)
            }
            .onEnded { value in
                let factor = min(max(value.magnification, 0.4), 3.0)
                cellZoom = min(max(cellZoom * factor, 0.5), 2.5)
                liveScale = 1     // committed row height == the scaled size → seamless, then re-packs
            }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// One day's photos laid out as justified rows (uniform row height, aspect-preserving widths),
/// exactly like Apple Photos. Aspect ratios come from `AspectRegistry` (square until learned).
private struct JustifiedSection: View {
    let items: [PhotoItem]
    let width: CGFloat
    let targetHeight: CGFloat
    let spacing: CGFloat
    let feed: ThumbnailFeed
    let aspects: AspectRegistry
    let onOpen: (PhotoItem) -> Void

    var body: some View {
        _ = aspects.version   // re-lay out as aspect ratios are learned
        let rows = Self.layout(items, width: width, targetHeight: targetHeight, spacing: spacing, aspects: aspects)
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: spacing) {
                    ForEach(rows[i]) { cell in
                        PhotoThumbnailCell(item: cell.item, feed: feed)
                            .frame(width: cell.width, height: cell.height)
                            .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                            .onTapGesture { onOpen(cell.item) }
                    }
                }
            }
        }
    }

    struct Cell: Identifiable {
        let item: PhotoItem
        let width: CGFloat
        let height: CGFloat
        var id: PhotoUID { item.uid }
    }

    /// Greedy justified packing: fill each row to `width`, then scale the row's height so it fits
    /// exactly. The final (partial) row keeps the target height (left-aligned), like Apple.
    @MainActor
    static func layout(_ items: [PhotoItem], width: CGFloat, targetHeight: CGFloat, spacing: CGFloat, aspects: AspectRegistry) -> [[Cell]] {
        var rows: [[Cell]] = []
        var run: [(PhotoItem, CGFloat)] = []
        var aspectSum: CGFloat = 0

        func aspect(_ item: PhotoItem) -> CGFloat {
            min(max(aspects.aspect(for: item.uid), 0.45), 3.2)
        }

        for item in items {
            let a = aspect(item)
            run.append((item, a))
            aspectSum += a
            let rowWidth = aspectSum * targetHeight + spacing * CGFloat(run.count - 1)
            if rowWidth >= width {
                rows.append(justify(run, width: width, spacing: spacing))
                run.removeAll(); aspectSum = 0
            }
        }
        if !run.isEmpty {
            rows.append(run.map { Cell(item: $0.0, width: $0.1 * targetHeight, height: targetHeight) })
        }
        return rows
    }

    private static func justify(_ run: [(PhotoItem, CGFloat)], width: CGFloat, spacing: CGFloat) -> [Cell] {
        let aspectSum = run.reduce(0) { $0 + $1.1 }
        let height = (width - spacing * CGFloat(run.count - 1)) / max(aspectSum, 0.001)
        return run.map { Cell(item: $0.0, width: $0.1 * height, height: height) }
    }
}

/// A single grid cell. Loads its thumbnail from the shared feed (cache-first) and fills its slot.
struct PhotoThumbnailCell: View {
    let item: PhotoItem
    let feed: ThumbnailFeed

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                ProtonColor.backgroundStrong
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the justified slot from the parent
        .clipped()
        .overlay(alignment: .bottomTrailing) { videoBadge }
        .overlay(alignment: .topTrailing) { liveBadge }
        .contentShape(Rectangle())
        .task(id: item.uid) {
                while !Task.isCancelled {
                    if let img = await feed.cachedImage(for: item.uid) {
                        image = img
                        return
                    }
                    await feed.requestPriority(item.uid)
                    try? await Task.sleep(for: .milliseconds(120))
                }
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
