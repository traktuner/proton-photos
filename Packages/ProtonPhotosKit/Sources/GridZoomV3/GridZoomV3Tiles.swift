// GridZoomV3Tiles.swift  —  GridZoomV3 Lab (synthetic data)
//
// Fake "photo-like" tiles with STABLE UIDs. No Proton data, no ThumbnailFeed, no network. Each tile shows
// its index, a unique hue, an explicit "▲ TOP" orientation marker (so any flip/rotation bug is obvious),
// and a fixed intrinsic aspect ratio (so aspect-fit letterboxing vs square-fill cropping is visible).

import AppKit
import CoreGraphics

public struct SyntheticTiles: Sendable {
    public let uids: [TileUID]
    public let aspectByUID: [TileUID: CGFloat]

    /// `count` tiles in a stable order. Aspects cycle through a fixed set so the wall has portrait,
    /// landscape and square tiles.
    public init(count: Int) {
        let aspects: [CGFloat] = [1.0, 1.5, 0.6667, 0.75, 1.3333, 1.0, 0.8]
        var uids: [TileUID] = []
        var aspectMap: [TileUID: CGFloat] = [:]
        uids.reserveCapacity(count)
        for i in 0..<count {
            let uid = String(format: "T%05d", i)
            uids.append(uid)
            aspectMap[uid] = aspects[i % aspects.count]
        }
        self.uids = uids
        self.aspectByUID = aspectMap
    }
}

/// Lazily renders + caches one CGImage per tile index. Main-thread only (drawn during the view's draw()).
@MainActor
public final class SyntheticTileImageProvider {
    private var cache: [Int: CGImage] = [:]
    private let aspects: [TileUID: CGFloat]
    private let uids: [TileUID]
    public init(tiles: SyntheticTiles) { self.uids = tiles.uids; self.aspects = tiles.aspectByUID }

    public func image(forIndex i: Int) -> CGImage? {
        if let c = cache[i] { return c }
        guard i >= 0, i < uids.count else { return nil }
        let uid = uids[i]
        let aspect = aspects[uid] ?? 1
        let img = SyntheticTileImageProvider.render(index: i, uid: uid, aspect: aspect)
        cache[i] = img
        return img
    }

    private static func render(index: Int, uid: TileUID, aspect: CGFloat) -> CGImage? {
        let base: CGFloat = 256
        let w = aspect >= 1 ? base : base * aspect
        let h = aspect >= 1 ? base / aspect : base
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Background: a unique hue per index (golden-ratio walk so neighbours differ strongly).
        let hue = (CGFloat(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        let bg = NSColor(hue: hue, saturation: 0.62, brightness: 0.82, alpha: 1)
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // A darker top band + "▲ TOP" so a vertical flip is instantly visible (the band must be at the top).
        let band = NSColor(hue: hue, saturation: 0.7, brightness: 0.5, alpha: 1)
        ctx.setFillColor(band.cgColor)
        let bandH = h * 0.18
        ctx.fill(CGRect(x: 0, y: h - bandH, width: w, height: bandH))   // CG origin bottom-left ⇒ top band

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let topStyle = NSMutableParagraphStyle(); topStyle.alignment = .center
        ("▲ TOP" as NSString).draw(in: CGRect(x: 0, y: h - bandH + bandH * 0.18, width: w, height: bandH * 0.7),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: bandH * 0.5),
                             .foregroundColor: NSColor.white, .paragraphStyle: topStyle])

        // Big index in the centre.
        let idxStyle = NSMutableParagraphStyle(); idxStyle.alignment = .center
        let label = "\(index)"
        let fontSize = min(w, h) * 0.42
        ("\(label)" as NSString).draw(in: CGRect(x: 0, y: h * 0.30, width: w, height: fontSize * 1.2),
            withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
                             .foregroundColor: NSColor(white: 1, alpha: 0.95), .paragraphStyle: idxStyle])

        // UID + aspect at the bottom-left.
        (uid as NSString).draw(at: CGPoint(x: 6, y: 6),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: max(10, h * 0.06), weight: .medium),
                             .foregroundColor: NSColor(white: 0, alpha: 0.55)])

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
