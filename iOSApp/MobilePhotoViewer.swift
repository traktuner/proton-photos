import AVFoundation
import AVKit
import DesignSystemCore
import PhotoViewerCore
import PhotoViewerUIKitAdapter
import PhotosCore
import SwiftUI
import UIKit

/// Native full-screen photo/video viewer. Paging + chrome live here (pure presentation); the media decoding,
/// titles and video-playback semantics come from shared `PhotoViewerCore` and the shared backend — no viewer
/// business logic is reimplemented per platform.
struct MobilePhotoViewer: View {
    let items: [PhotoItem]
    let startIndex: Int
    let libraryModel: MobileLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chromeVisible = true

    init(items: [PhotoItem], startIndex: Int, libraryModel: MobileLibraryModel) {
        self.items = items
        self.startIndex = startIndex
        self.libraryModel = libraryModel
        _index = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(items.indices, id: \.self) { i in
                    MobileViewerPage(
                        item: items[i],
                        isCurrent: i == index,
                        libraryModel: libraryModel,
                        onToggleChrome: { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
                    )
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chromeVisible {
                chrome
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
    }

    private var chrome: some View {
        VStack {
            HStack(alignment: .top) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Spacer()

                if items.indices.contains(index) {
                    let title = ViewerTitleFormatter.make(
                        captureDate: items[index].captureTime,
                        index: index,
                        total: items.count
                    )
                    VStack(spacing: 1) {
                        Text(title.line1)
                            .font(.subheadline.weight(.semibold))
                        Text(title.line2)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                }

                Spacer()

                // Balances the close button so the title stays centered.
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer()
        }
    }
}

/// A single viewer page — a zoomable image, or a native video player for video items.
private struct MobileViewerPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let libraryModel: MobileLibraryModel
    let onToggleChrome: () -> Void

    var body: some View {
        if item.isVideo {
            MobileVideoPage(item: item, isCurrent: isCurrent, libraryModel: libraryModel)
        } else {
            MobileImagePage(item: item, libraryModel: libraryModel, onToggleChrome: onToggleChrome)
        }
    }
}

/// Loads the placeholder thumbnail immediately, then the full-resolution original, and shows it zoomable.
private struct MobileImagePage: View {
    let item: PhotoItem
    let libraryModel: MobileLibraryModel
    let onToggleChrome: () -> Void

    @State private var image: UIImage?
    @State private var isLoadingFull = false

    var body: some View {
        ZStack {
            if let image {
                MobileZoomableImage(image: image, onSingleTap: onToggleChrome)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.uid) { await load() }
    }

    private func load() async {
        // Instant placeholder from the in-memory thumbnail cache (already decoded for the grid).
        if image == nil, let thumb = libraryModel.thumbnailFeed?.memoryImage(for: item.uid) {
            image = thumb
        }
        guard !isLoadingFull, let backend = libraryModel.backend else { return }
        isLoadingFull = true
        defer { isLoadingFull = false }
        do {
            let data = try await backend.originalData(for: item.uid)
            if let full = UIKitViewerImageAdapter.image(from: data) {
                image = full
            }
        } catch {
            // Keep the thumbnail placeholder on failure — better than a blank page.
        }
    }
}

/// Native video playback via AVKit over the shared `VideoStreamProvider` streaming asset.
private struct MobileVideoPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let libraryModel: MobileLibraryModel

    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if failed {
                ContentUnavailableView("Can't play this video", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.uid) { await prepare() }
        .onChange(of: isCurrent) { _, current in
            if current { player?.play() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }

    private func prepare() async {
        guard player == nil, let backend = libraryModel.backend else { return }
        do {
            let streaming = try await backend.makeStreamingAsset(for: item.uid)
            let item = AVPlayerItem(asset: streaming.asset)
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            if isCurrent { newPlayer.play() }
        } catch {
            failed = true
        }
    }
}

/// UIScrollView-backed zoomable image: pinch + double-tap to zoom, single-tap toggles chrome. At minimum zoom
/// the scroll view does not pan, so the enclosing page TabView keeps its swipe.
private struct MobileZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSingleTap: onSingleTap) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        var onSingleTap: () -> Void

        init(onSingleTap: @escaping () -> Void) { self.onSingleTap = onSingleTap }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func handleSingleTap() { onSingleTap() }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let side = scrollView.bounds.size
                let zoomRect = CGRect(x: point.x - side.width / 6, y: point.y - side.height / 6,
                                      width: side.width / 3, height: side.height / 3)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}
