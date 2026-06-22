import SwiftUI
import AppKit
import Metal
import PhotosCore

/// The Metal Grid Lab — a debug-only prototype window proving a Metal-backed photo grid can render +
/// scroll the library smoothly (Phase 1 of the Metal-grid rewrite). It does NOT replace the production
/// grid. Open it from **Debug ▸ Metal Grid Lab…** (⌥⇧⌘M).
///
/// It uses the REAL library (live `ThumbnailFeed` + timeline sections, published by the main UI) when
/// available, and falls back to synthetic streaming tiles otherwise — so it always opens, signed in or
/// not, and can be stress-tested at 20k / 50k items.
public struct MetalGridLab: View {
    @State private var model = MetalGridLabModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                MetalGridScrollHostRepresentable(model: model)
                if model.showHUD {
                    hudOverlay
                        .padding(10)
                        .allowsHitTesting(false)   // display only — never steal scroll/clicks from the grid
                }
            }
            .frame(minWidth: 480, minHeight: 360)
            Divider()
            controlPanel
                .frame(width: 290)
                .background(Color(white: 0.12))
        }
        .background(Color(white: 0.05))
    }

    // MARK: HUD overlay (drawn over the Metal viewport)

    private var hudOverlay: some View {
        let s = model.hud.stats
        return VStack(alignment: .leading, spacing: 2) {
            hud("fps", String(format: "%.0f", s.fpsEstimate), s.fpsEstimate >= 58 ? .green : (s.fpsEstimate >= 30 ? .yellow : .red))
            hud("visible", "\(s.visibleItems)  (+\(s.overscanItems) overscan)")
            hud("real / placeholder", "\(s.realTextureItems) / \(s.placeholderItems)", s.placeholderItems == 0 ? .green : .white)
            hud("uploads/frame", "\(s.textureUploads)  \(String(format: "%.0f", Double(s.textureUploadBytes)/1024))KB")
            hud("draws / instances", "\(s.drawCalls) / \(s.instanceCount)")
            hud("cpu layout / inst", "\(fmt(s.cpuLayoutMs)) / \(fmt(s.cpuInstanceMs)) ms")
            hud("gpu draw", "\(fmt(s.gpuDrawMs)) ms")
            hud("textures (lru)", "\(model.hud.cache.textureCount)  pin=\(model.hud.cache.pinnedVisible) q=\(model.hud.cache.uploadQueueDepth)")
            hud("memory", "\(String(format: "%.1f", Double(s.memoryEstimateBytes)/1_048_576)) MB")
            hud("velocity", "\(Int(model.hud.scroll.scrollVelocity)) pt/s")
            hud("hover", model.hoverUID)
        }
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .font(.system(size: 10, design: .monospaced))
    }

    private func hud(_ k: String, _ v: String, _ color: Color = .white) -> some View {
        HStack(spacing: 6) {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(v).foregroundStyle(color)
        }
        .frame(width: 230, alignment: .leading)
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    // MARK: Control panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Metal Grid Lab").font(.headline).foregroundStyle(.white)
                Text("Phase 1 prototype · NSScrollView physics + Metal viewport renderer. Does not replace the production grid.")
                    .font(.caption).foregroundStyle(.secondary)

                group("Data source") {
                    Picker("", selection: $model.useRealData) {
                        Text("Real library").tag(true)
                        Text("Synthetic").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(model.hud.dataSource == "real"
                         ? "Live ThumbnailFeed · \(model.hud.totalItems) photos"
                         : "Synthetic streaming tiles · \(model.hud.totalItems) items")
                        .font(.caption2).foregroundStyle(.secondary)
                    if model.useRealData && !MetalGridLabBridge.shared.hasRealData {
                        Text("No live library published yet (sign in / open the grid first) — using synthetic.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }

                group("Synthetic item count") {
                    Picker("", selection: $model.syntheticCount) {
                        Text("5 000").tag(5_000)
                        Text("20 000").tag(20_000)
                        Text("50 000").tag(50_000)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(model.useRealData && MetalGridLabBridge.shared.hasRealData)
                }

                group("Zoom level (density)") {
                    let maxLevel = SquareTileGridEngine.defaultLevels.count - 1
                    HStack {
                        Button("−") { model.setLevel(model.level + 1) }.disabled(model.level >= maxLevel)
                        Text("level \(model.level)").font(.system(.caption, design: .monospaced)).foregroundStyle(.white)
                        Button("+") { model.setLevel(model.level - 1) }.disabled(model.level <= 0)
                    }
                    .controlSize(.small)
                    Picker("", selection: Binding(get: { model.level }, set: { model.setLevel($0) })) {
                        ForEach(0 ... maxLevel, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }

                group("Scroll") {
                    HStack {
                        Button("Top") { model.host?.scrollToTop() }
                        Button("Bottom") { model.host?.scrollToBottom() }
                    }.controlSize(.small)
                }

                Toggle("Show HUD overlay", isOn: $model.showHUD)

                group("Live stats") {
                    statRow("visibleRect", "\(Int(model.hud.scroll.visibleRect.minY))…\(Int(model.hud.scroll.visibleRect.maxY))")
                    statRow("contentSize", "\(Int(model.hud.scroll.contentSize.width))×\(Int(model.hud.scroll.contentSize.height))")
                    statRow("evictions(last)", "\(model.hud.stats.evictions)")
                }

                Text("Scroll with the trackpad / scroll wheel — native NSScrollView inertia + rubber-band. The Metal view draws only the visible viewport.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func statRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(.caption2, design: .monospaced)).foregroundStyle(.white)
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class MetalGridLabModel {
    var hud = MetalGridHUD()
    var hoverUID = "—"
    var showHUD = true
    var level = 3   // medium density (matches production opening level after the larger level 0 was added)
    var useRealData = true { didSet { if useRealData != oldValue { pendingRebuild = true } } }
    var syntheticCount = 20_000 { didSet { if syntheticCount != oldValue && !(useRealData && MetalGridLabBridge.shared.hasRealData) { pendingRebuild = true } } }

    fileprivate var pendingRebuild = false
    weak var host: MetalGridScrollHost?

    func attach(_ host: MetalGridScrollHost) {
        self.host = host
        host.onHUD = { [weak self] hud in self?.hud = hud }
        host.onHitTest = { [weak self] uid, _ in
            self?.hoverUID = uid.map { "\($0.nodeID)" } ?? "—"
        }
    }

    func makeDataSource() -> MetalGridDataSource {
        if useRealData, let real = MetalGridLabBridge.shared.makeRealDataSource() {
            return real
        }
        return SyntheticMetalGridDataSource(itemCount: syntheticCount)
    }

    func setLevel(_ newLevel: Int) {
        let clamped = min(max(newLevel, 0), SquareTileGridEngine.defaultLevels.count - 1)
        level = clamped
        host?.setLevel(clamped)
    }
}

// MARK: - NSViewRepresentable

struct MetalGridScrollHostRepresentable: NSViewRepresentable {
    let model: MetalGridLabModel

    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice(),
              let host = MetalGridScrollHost(device: device, dataSource: model.makeDataSource()) else {
            let fallback = NSTextField(labelWithString: "Metal is unavailable on this device.")
            fallback.textColor = .white
            return fallback
        }
        model.attach(host)
        host.setLevel(model.level)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? MetalGridScrollHost else { return }
        if model.pendingRebuild {
            model.pendingRebuild = false
            host.setDataSource(model.makeDataSource())
            host.setLevel(model.level)
        }
    }
}
