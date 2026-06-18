// GridZoomV3Lab.swift  —  GridZoomV3 Lab (Phase 1 container)
//
// The SwiftUI shell: the isolated renderer + a control panel (apparentCellSize slider fallback, debug
// toggles, tile count) + a live mirror of the in-view HUD. Open it from the app's Debug menu. It depends on
// nothing but this module — no Proton Drive, no photos, no ThumbnailFeed.

import SwiftUI
import AppKit

public struct GridZoomV3Lab: View {
    @State private var model = GridZoomV3LabModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            GridZoomV3RendererView(model: model)
                .frame(minWidth: 480, minHeight: 360)
            Divider()
            controlPanel
                .frame(width: 260)
                .background(Color(white: 0.12))
        }
        .background(Color(white: 0.07))
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("GridZoom V3 Lab").font(.headline).foregroundStyle(.white)
                Text("Synthetic tiles · isolated · no Proton data")
                    .font(.caption).foregroundStyle(.secondary)

                group("Apparent cell size (live)") {
                    Slider(value: $model.sliderApparent, in: 0...1) { editing in
                        if !editing { model.snapToDetent() }
                    }
                    Text(String(format: "%.1f px", model.hud.apparentCellSize))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.white)
                    HStack {
                        Button("− denser") { model.nudge(-1) }
                        Button("larger +") { model.nudge(1) }
                    }.controlSize(.small)
                    Button("Snap to nearest detent") { model.snapToDetent() }
                        .controlSize(.small)
                }

                group("Debug overlays") {
                    Toggle("Crosshair at anchor", isOn: $model.showCrosshair)
                    Toggle("Focus band", isOn: $model.showFocusBand)
                    Toggle("Cell rects (trails)", isOn: $model.showRects)
                    Toggle("In-view HUD", isOn: $model.showHUD)
                }

                group("Live invariants") {
                    hudRow("apparentCellSize", String(format: "%.1f", model.hud.apparentCellSize))
                    hudRow("columnCount", "\(model.hud.columnCount)")
                    hudRow("cropMode", model.hud.cropMode)
                    hudRow("detent target", "#\(model.hud.detentTarget) · \(model.hud.detentTargetColumns) cols")
                    hudRow("anchorUID", model.hud.anchorUID)
                    hudRow("topMost@anchor", model.hud.topMostUIDAtAnchor)
                    hudRow("anchorTopmost", model.hud.anchorTopmostPass ? "PASS" : "FAIL",
                           model.hud.anchorTopmostPass ? .green : .red)
                    hudRow("focus row", model.hud.focusRowRange)
                    hudRow("topologyRebase", model.hud.rebaseActive ? String(format: "active %.2f", model.hud.rebaseProgress) : "—")
                    hudRow("phase", model.hud.phase)
                    hudRow("visible tiles", "\(model.hud.visibleTiles)")
                }

                group("Tiles") {
                    Picker("Count", selection: $model.tileCount) {
                        Text("1 000").tag(1000)
                        Text("2 500").tag(2500)
                        Text("5 000").tag(5000)
                    }.pickerStyle(.segmented).controlSize(.small)
                }

                Text("Pinch on the trackpad to zoom. ⌥-scroll = zoom fallback. Scroll = pan.")
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

    private func hudRow(_ k: String, _ v: String, _ color: Color = .white) -> some View {
        HStack {
            Text(k).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(.caption2, design: .monospaced)).foregroundStyle(color)
        }
    }
}

@MainActor @Observable
final class GridZoomV3LabModel {
    var hud = GridZoomV3HUD()
    var tileCount = 2500 { didSet { rebuild = true } }
    var showCrosshair = true { didSet { view?.showCrosshair = showCrosshair } }
    var showRects = false { didSet { view?.showRects = showRects } }
    var showFocusBand = true { didSet { view?.showFocusBand = showFocusBand } }
    var showHUD = true { didSet { view?.showHUD = showHUD } }
    var sliderApparent: Double = 0.5 { didSet { applySlider() } }

    fileprivate var rebuild = false
    weak var view: GridZoomV3LabView?
    private var suppressSlider = false

    func attach(_ v: GridZoomV3LabView) {
        view = v
        v.showCrosshair = showCrosshair; v.showRects = showRects
        v.showFocusBand = showFocusBand; v.showHUD = showHUD
        v.onHUD = { [weak self] h in
            guard let self else { return }
            self.hud = h
            self.suppressSlider = true
            let b = v.apparentBounds
            let t = (log(max(h.apparentCellSize, 1)) - log(b.lowerBound)) / max(log(b.upperBound) - log(b.lowerBound), 0.0001)
            self.sliderApparent = Double(min(max(t, 0), 1))
            self.suppressSlider = false
        }
    }

    private func applySlider() {
        guard !suppressSlider, let view else { return }
        let b = view.apparentBounds
        let a = b.lowerBound * pow(b.upperBound / b.lowerBound, CGFloat(sliderApparent))
        view.setApparentFromSlider(a)
    }

    func snapToDetent() { view?.snapToNearestDetent() }
    func nudge(_ dir: Int) {
        guard let view else { return }
        let factor: CGFloat = dir > 0 ? 1.12 : 1 / 1.12
        view.setApparentFromSlider(view.currentApparent * factor)
        view.snapToNearestDetent()
    }
}

struct GridZoomV3RendererView: NSViewRepresentable {
    let model: GridZoomV3LabModel

    func makeNSView(context: Context) -> GridZoomV3LabView {
        let v = GridZoomV3LabView(tileCount: model.tileCount, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        model.attach(v)
        return v
    }

    func updateNSView(_ nsView: GridZoomV3LabView, context: Context) {
        if model.rebuild {
            model.rebuild = false
            nsView.rebuild(tileCount: model.tileCount)   // rebuild in place; do not swap the managed view
        }
    }
}
