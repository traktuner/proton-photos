import Foundation
import CoreGraphics
import PhotosCore

/// Feature flag for the Apple-matched **detent zoom** on the Metal grid (justified aspect rows + square
/// overview + continuous pinch + two-surface transitions). Default ON. Toggle via the `MetalGrid.detentZoom`
/// UserDefaults key, the Settings ▸ Developer toggle, or `-MetalGrid.detentZoom NO` at launch. When OFF the
/// grid falls back to the legacy square-`aspectFit` `MetalGridLayout` path with instant level snaps — so the
/// old behavior stays one switch away until the new one is visually signed off (the user's explicit ask:
/// "do not delete the old square layout until the Apple-like layout is visually verified").
public enum MetalGridDetentZoomFlag {
    public static let userDefaultsKey = "MetalGrid.detentZoom"

    public static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else { return true } // default ON
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
    }
}

/// Structured `[GridDetent]/[GridAnchor]/[GridTransition]/[GridSettle]` instrumentation for the zoom — the
/// behavior is largely invisible to unit tests once it hits the GPU, so these logs are the evidence trail
/// for live tuning. Throttled by the caller; routed through `PhotoDiagnostics`.
enum GridZoomDebug {
    static let verbose = ProcessInfo.processInfo.arguments.contains("-GridZoomVerbose")

    static func detent(source: Int, target: Int, progress: CGFloat, snap: Int?, family: String) {
        guard verbose else { return }
        PhotoDiagnostics.shared.emit("GridDetent", [
            "source": "\(source)", "target": "\(target)",
            "progress": String(format: "%.3f", progress),
            "snapTarget": snap.map(String.init) ?? "—", "transitionFamily": family,
        ])
    }

    static func anchor(uid: String, screen: CGPoint, status: String) {
        guard verbose else { return }
        PhotoDiagnostics.shared.emit("GridAnchor", [
            "anchorUID": uid, "cursorPoint": "(\(Int(screen.x)),\(Int(screen.y)))", "anchorStatus": status,
        ])
    }

    static func transition(mode: String, progress: CGFloat, replacementCount: Int, focusProtected: Bool) {
        guard verbose else { return }
        PhotoDiagnostics.shared.emit("GridTransition", [
            "mode": mode, "progress": String(format: "%.3f", progress),
            "replacementCount": "\(replacementCount)", "focusBandProtected": "\(focusProtected)",
        ])
    }

    static func settle(velocity: CGFloat, finalDetent: Int, originMatch: Bool) {
        guard verbose else { return }
        PhotoDiagnostics.shared.emit("GridSettle", [
            "releaseVelocity": String(format: "%.2f", velocity),
            "finalDetent": "\(finalDetent)", "originMatch": "\(originMatch)",
        ])
    }

    /// `[PinchOutTransition]` per-frame diagnostics: the cross-dissolve plan counts + progress.
    static func pinchOut(progress: CGFloat, source: Int, target: Int, replacements: Int, targetOnly: Int, unchanged: Int) {
        guard verbose else { return }
        PhotoDiagnostics.shared.emit("PinchOutTransition", [
            "progress": String(format: "%.3f", progress),
            "source": "\(source)", "target": "\(target)",
            "replacements": "\(replacements)", "targetOnly": "\(targetOnly)", "unchanged": "\(unchanged)",
        ])
    }
}
