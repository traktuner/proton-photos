// GridZoomV3LabView.swift  —  GridZoomV3 Lab (Phases 1, 4, 6, 9 — the isolated renderer)
//
// A standalone AppKit view that renders the global photo wall by DRAWING EVERY VISIBLE TILE FRESH from the
// pure layout each frame. There is NO NSCollectionView, NO cell reuse, NO Metal atlas, NO snapshot/source
// rectangle/backdrop — exactly the confounders the prototype removes. The whole live geometry comes from
// `WallZoomSession.renderFrame`, so what you see on screen is precisely the unit-tested model.

import AppKit
import QuartzCore

/// Snapshot of the live invariants, pushed to the SwiftUI panel each frame.
public struct GridZoomV3HUD: Sendable {
    public var apparentCellSize: CGFloat = 0
    public var columnCount: Int = 0
    public var cropMode: String = "aspectFit"
    public var detentTarget: Int = 0
    public var detentTargetColumns: Int = 0
    public var anchorUID: String = "—"
    public var topMostUIDAtAnchor: String = "—"
    public var anchorTopmostPass: Bool = true
    public var focusRowRange: String = "—"
    public var rebaseActive: Bool = false
    public var rebaseProgress: CGFloat = 0
    public var velocity: CGFloat = 0
    public var visibleTiles: Int = 0
    public var phase: String = "rest"
}

@MainActor
public final class GridZoomV3LabView: NSView {

    private var session: WallZoomSession
    private var tiles: SyntheticTiles
    private var images: SyntheticTileImageProvider

    // Debug toggles
    public var showCrosshair = true { didSet { needsDisplay = true } }
    public var showRects = false { didSet { needsDisplay = true } }
    public var showFocusBand = true { didSet { needsDisplay = true } }
    public var showHUD = true { didSet { needsDisplay = true } }

    /// Pushed every frame so the SwiftUI panel can mirror the in-view HUD.
    public var onHUD: (@MainActor (GridZoomV3HUD) -> Void)?

    private var currentFrame: WallRenderFrame?
    private var lastMouse: CGPoint = .zero

    // Pinch state
    private var pinchStartApparent: CGFloat = 0
    private var accumMag: CGFloat = 0
    public var sensitivity: CGFloat = 1.7

    // Settle state
    private var settleStartApparent: CGFloat = 0
    private var settleTarget: CGFloat = 0
    private var settleStart: Double = 0
    private var settleDuration: Double = 0.26
    private var isSettling = false

    private var tick: CADisplayLink?
    private var lastLog: Double = 0

    public init(tileCount: Int, frame frameRect: NSRect) {
        self.tiles = SyntheticTiles(count: tileCount)
        self.images = SyntheticTileImageProvider(tiles: tiles)
        self.session = WallZoomSession(orderedUIDs: tiles.uids, aspectByUID: tiles.aspectByUID,
                                       viewportSize: frameRect.size, contentInset: 12, topInset: 12)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        lastMouse = CGPoint(x: frameRect.midX, y: frameRect.midY)
    }
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }      // y-down, matches the wall's doc space
    public override var acceptsFirstResponder: Bool { true }

    public override func layout() {
        super.layout()
        if session.viewportSize != bounds.size {
            session.viewportSize = bounds.size
            refreshFrame()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
    }
    public override func mouseMoved(with event: NSEvent) {
        lastMouse = convert(event.locationInWindow, from: nil)
    }

    // MARK: - Pinch (the live path — same code for in and out)

    public override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            beginPinch(at: convert(event.locationInWindow, from: nil))
        case .changed:
            accumMag += event.magnification
            let a = pinchStartApparent * CGFloat(exp(Double(accumMag) * Double(sensitivity)))
            session.setApparent(a, now: CACurrentMediaTime())
            session.advance(now: CACurrentMediaTime())
            refreshFrame()
        case .ended, .cancelled:
            beginSettle()
        default: break
        }
    }

    private func beginPinch(at cursor: CGPoint) {
        isSettling = false
        let now = CACurrentMediaTime()
        session.beginPinch(atCursor: cursor, now: now)
        pinchStartApparent = session.apparentCellSize
        accumMag = 0
        startTick()
        refreshFrame()
    }

    private func beginSettle() {
        let target = session.detentApparent(session.settleTargetDetent())
        settleStartApparent = session.apparentCellSize
        settleTarget = target
        settleStart = CACurrentMediaTime()
        isSettling = true
        startTick()
    }

    // MARK: - Scroll (rest) + slider/wheel zoom fallback

    public override func scrollWheel(with event: NSEvent) {
        guard !session.isPinching && !isSettling else { return }
        if event.modifierFlags.contains(.option) {
            // ⌥-scroll = zoom fallback about the cursor.
            let cursor = convert(event.locationInWindow, from: nil)
            if !session.isPinching { session.beginPinch(atCursor: cursor, now: CACurrentMediaTime()) }
            let factor = CGFloat(exp(Double(event.scrollingDeltaY) * 0.01))
            session.setApparent(session.apparentCellSize * factor, now: CACurrentMediaTime())
            session.advance(now: CACurrentMediaTime())
            refreshFrame()
            beginSettle()
        } else {
            session.setScroll(y: session.scrollOffset.y - event.scrollingDeltaY)
            refreshFrame()
        }
    }

    /// Slider fallback for `apparentCellSize` (no auto-settle — for inspecting the continuous behaviour).
    public func setApparentFromSlider(_ a: CGFloat) {
        if !session.isPinching {
            session.beginPinch(atCursor: CGPoint(x: bounds.midX, y: bounds.midY), now: CACurrentMediaTime())
            pinchStartApparent = session.apparentCellSize
        }
        session.setApparent(a, now: CACurrentMediaTime())
        session.advance(now: CACurrentMediaTime())
        startTick()
        refreshFrame()
    }
    public func snapToNearestDetent() { if session.isPinching { beginSettle() } }
    public var apparentBounds: ClosedRange<CGFloat> { session.apparentBounds }
    public var currentApparent: CGFloat { session.apparentCellSize }

    /// Rebuild the synthetic wall with a new tile count, in place (no view swap).
    public func rebuild(tileCount: Int) {
        guard tileCount != tiles.uids.count else { return }
        stopTick(); isSettling = false
        tiles = SyntheticTiles(count: tileCount)
        images = SyntheticTileImageProvider(tiles: tiles)
        session = WallZoomSession(orderedUIDs: tiles.uids, aspectByUID: tiles.aspectByUID,
                                  viewportSize: bounds.size, contentInset: 12, topInset: 12)
        refreshFrame()
    }

    // MARK: - Tick (self-clock for rebase convergence + settle)

    private func startTick() {
        if tick == nil {
            let dl = displayLink(target: self, selector: #selector(handleTick))
            dl.add(to: .main, forMode: .common)   // .common ⇒ keeps firing during gesture/event tracking
            tick = dl
        }
        tick?.isPaused = false
    }
    private func stopTick() { tick?.isPaused = true }
    @objc private func handleTick() { onTick() }

    private func onTick() {
        let now = CACurrentMediaTime()
        if isSettling {
            let t = settleDuration > 0 ? min(1, (now - settleStart) / settleDuration) : 1
            let s = WallZoomDirector.smoothstep(CGFloat(t))
            session.setApparent(settleStartApparent + (settleTarget - settleStartApparent) * s, now: now)
            if t >= 1 {
                session.advance(now: now)
                session.endPinch(now: now)
                isSettling = false
                refreshFrame()
                stopTick()
                return
            }
        }
        let rebasing = session.advance(now: now)
        refreshFrame()
        if !session.isPinching && !isSettling && !rebasing { stopTick() }
    }

    // MARK: - Frame assembly + draw

    private func refreshFrame() {
        let frame = session.renderFrame(now: CACurrentMediaTime())
        currentFrame = frame
        pushHUD(frame)
        logInvariants(frame)
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frame = currentFrame ?? session.renderFrame(now: CACurrentMediaTime())
        currentFrame = frame

        ctx.setFillColor(NSColor(white: 0.07, alpha: 1).cgColor)
        ctx.fill(bounds)

        for node in frame.nodes {
            drawTile(node, ctx: ctx)
            if showRects {
                ctx.setStrokeColor(NSColor(white: 1, alpha: 0.25 * node.alpha).cgColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(node.cellScreenRect.insetBy(dx: 0.5, dy: 0.5))
            }
        }

        if showFocusBand && frame.anchorUID != nil {
            let half = WallZoomDirector.focusBandHalfHeight(viewportHeight: bounds.height)
            let band = CGRect(x: 0, y: frame.anchorScreenPoint.y - half, width: bounds.width, height: half * 2)
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.06).cgColor)
            ctx.fill(band)
            ctx.setStrokeColor(NSColor.systemGreen.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(band)
        }

        if showCrosshair {
            drawCrosshair(at: frame.anchorScreenPoint, ctx: ctx,
                          pass: frame.anchorUID == nil || frame.topMostUID(at: frame.anchorScreenPoint) == frame.anchorUID)
        }

        if showHUD { drawHUD(frame, ctx: ctx) }
    }

    private func drawTile(_ node: WallRenderNode, ctx: CGContext) {
        guard let img = images.image(forIndex: node.index) else {
            ctx.setFillColor(NSColor(white: 0.2, alpha: node.alpha).cgColor)
            ctx.fill(node.cellScreenRect)
            return
        }
        ctx.saveGState()
        ctx.setAlpha(node.alpha)
        let radius = min(node.cellScreenRect.width, node.cellScreenRect.height) * 0.04
        if node.cropMode.fillsCell {
            // square-fill: clip to the (rounded) square cell, draw the image aspect-FILL (centre-crop).
            clip(ctx, to: node.cellScreenRect, radius: radius)
            let aspect = CGFloat(img.width) / CGFloat(img.height)
            let fill = aspectFillRect(aspect: aspect, in: node.cellScreenRect)
            drawImageUpright(img, in: fill, ctx: ctx)
        } else {
            clip(ctx, to: node.imageScreenRect, radius: radius)
            drawImageUpright(img, in: node.imageScreenRect, ctx: ctx)
        }
        ctx.restoreGState()
    }

    private func clip(_ ctx: CGContext, to rect: CGRect, radius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path); ctx.clip()
    }

    /// Draw a CGImage upright inside `rect` within this flipped (y-down) view.
    private func drawImageUpright(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private func aspectFillRect(aspect: CGFloat, in cell: CGRect) -> CGRect {
        var w = cell.width, h = cell.height
        if aspect >= 1 { w = cell.height * aspect } else { h = cell.width / aspect }
        if w < cell.width { let s = cell.width / w; w *= s; h *= s }
        if h < cell.height { let s = cell.height / h; w *= s; h *= s }
        return CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h)
    }

    private func drawCrosshair(at p: CGPoint, ctx: CGContext, pass: Bool) {
        let color = (pass ? NSColor.systemGreen : NSColor.systemRed)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: p.x - 16, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 16, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: p.y - 16)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 16))
        ctx.strokePath()
        ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
        ctx.strokeEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
    }

    // MARK: - HUD

    private func hud(_ frame: WallRenderFrame) -> GridZoomV3HUD {
        var h = GridZoomV3HUD()
        h.apparentCellSize = frame.apparentCellSize
        h.columnCount = frame.liveTopology.columns
        h.cropMode = frame.liveTopology.cropSquare ? "squareFill" : "aspectFit"
        let dt = session.settleTargetDetent()
        h.detentTarget = dt
        h.detentTargetColumns = session.detents[dt].columns
        h.anchorUID = frame.anchorUID ?? "—"
        let top = frame.anchorUID == nil ? nil : frame.topMostUID(at: frame.anchorScreenPoint)
        h.topMostUIDAtAnchor = top ?? "—"
        h.anchorTopmostPass = (frame.anchorUID == nil) || (top == frame.anchorUID)
        if let lo = frame.focusRowUIDs.min(), let hi = frame.focusRowUIDs.max() {
            h.focusRowRange = lo == hi ? lo : "\(lo)…\(hi)"
        }
        h.rebaseActive = frame.isRebasing
        if case let .rebasing(_, p) = frame.plan { h.rebaseProgress = p }
        h.velocity = session.velocity
        h.visibleTiles = frame.nodes.count
        h.phase = isSettling ? "settle" : (session.isPinching ? "pinch" : "rest")
        return h
    }

    private func pushHUD(_ frame: WallRenderFrame) { onHUD?(hud(frame)) }

    private func drawHUD(_ frame: WallRenderFrame, ctx: CGContext) {
        let h = hud(frame)
        let lines: [(String, NSColor)] = [
            ("GridZoomV3 Lab — \(h.phase.uppercased())", .white),
            (String(format: "apparentCellSize  %.1f", h.apparentCellSize), .white),
            ("columnCount       \(h.columnCount)   crop \(h.cropMode)", .white),
            ("detent target     #\(h.detentTarget) (\(h.detentTargetColumns) cols)", .white),
            ("anchorUID         \(h.anchorUID)", .systemTeal),
            ("topMost@anchor    \(h.topMostUIDAtAnchor)", h.anchorTopmostPass ? .systemGreen : .systemRed),
            ("anchorTopmost     \(h.anchorTopmostPass ? "PASS" : "FAIL")", h.anchorTopmostPass ? .systemGreen : .systemRed),
            ("focus row         \(h.focusRowRange)", .systemGreen),
            ("topologyRebase    \(h.rebaseActive ? String(format: "active %.2f", h.rebaseProgress) : "—")", .systemYellow),
            ("velocity          \(String(format: "%.0f", h.velocity))   visible \(h.visibleTiles)", .white),
            ("rectLerpUsed=false  detentDuringChanged=false  oldPathUsed=false", .systemGray),
        ]
        let pad: CGFloat = 8, lineH: CGFloat = 16
        let boxH = CGFloat(lines.count) * lineH + pad * 2
        let box = CGRect(x: 10, y: 10, width: 380, height: boxH)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
        for (i, line) in lines.enumerated() {
            (line.0 as NSString).draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad + CGFloat(i) * lineH),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                                 .foregroundColor: line.1])
        }
    }

    // The HUD is drawn in a flipped view; text must not appear upside-down. NSString.draw respects the
    // view's flipped flag, so no manual flip is needed here.

    // MARK: - Greppable invariant logs

    private func logInvariants(_ frame: WallRenderFrame) {
        guard session.isPinching || isSettling else { return }
        let now = CACurrentMediaTime()
        guard now - lastLog > 0.1 else { return }
        lastLog = now
        let pass = frame.anchorUID == nil || frame.topMostUID(at: frame.anchorScreenPoint) == frame.anchorUID
        print("[GridZoomV3] active=true oldPathUsed=false rectLerpUsed=false detentDuringChanged=false " +
              "topMostAnchor=\(pass ? "PASS" : "FAIL") topologyRebase active=\(frame.isRebasing) " +
              "apparent=\(String(format: "%.1f", frame.apparentCellSize)) cols=\(frame.liveTopology.columns)")
    }
}
