import DesignSystemCore
import GridCore
import PhotosCore
import SwiftUI
import TimelineUIKitAdapter
import UIKit

@main
struct ProtonPhotosMobileApp: App {
    var body: some Scene {
        WindowGroup {
            MobileRootView()
        }
    }
}

private struct MobileRootView: View {
    private let adapter = UIKitTimelineGridProfileAdapter()
    private let sampleUID = PhotoUID(volumeID: "mobile-shell", nodeID: "viewport-proof")

    var body: some View {
        GeometryReader { geometry in
            let layout = MobileViewportLayout(geometry: geometry)
            let profile = adapter.profile(
                forBounds: CGRect(origin: .zero, size: geometry.size),
                safeAreaInsets: layout.safeAreaInsets,
                additionalInsets: layout.chromeInsets
            )
            let metrics = profile.metrics(level: profile.defaultLevel)

            ZStack {
                ProtonColor.backgroundNorm.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Proton Photos")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(ProtonColor.textNorm)

                    MobileGridPreview(metrics: metrics)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(accessibilityLabel(profile: profile, metrics: metrics))

                    Text(sampleUID.nodeID)
                        .font(.caption)
                        .foregroundStyle(ProtonColor.textHint)
                }
                .padding(.horizontal, layout.contentPadding)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func accessibilityLabel(profile: GridLevelProfile, metrics: GridLevelMetrics) -> String {
        "\(profile.id), \(metrics.nominalColumns) columns"
    }
}

private struct MobileViewportLayout {
    let safeAreaInsets: UIEdgeInsets
    let chromeInsets: UIEdgeInsets
    let contentPadding: CGFloat

    init(geometry: GeometryProxy) {
        safeAreaInsets = UIEdgeInsets(
            top: geometry.safeAreaInsets.top,
            left: geometry.safeAreaInsets.leading,
            bottom: geometry.safeAreaInsets.bottom,
            right: geometry.safeAreaInsets.trailing
        )
        chromeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        contentPadding = min(max(geometry.size.width * 0.045, 16), 32)
    }
}

private struct MobileGridPreview: View {
    let metrics: GridLevelMetrics

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 8), spacing: metrics.gap),
            count: max(1, metrics.nominalColumns)
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: metrics.gap) {
            ForEach(0 ..< min(max(metrics.nominalColumns * 4, 12), 48), id: \.self) { index in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tileColor(index: index))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    private func tileColor(index: Int) -> Color {
        let opacity = 0.2 + Double(index % 5) * 0.08
        return ProtonColor.primary.opacity(opacity)
    }
}
