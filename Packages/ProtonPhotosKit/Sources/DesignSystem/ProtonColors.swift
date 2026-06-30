import SwiftUI
import AppKit

/// Proton design tokens.
///
/// Neutrals (backgrounds / text / borders) map to **semantic system colors**, so the whole app adapts to
/// light/dark appearance, increased-contrast, and material vibrancy automatically — and inherits Apple's
/// refined Liquid Glass on macOS 27 with no per-token work. Only the brand accent + signal hues stay fixed
/// (they are brand identity and read correctly in both appearances). Call sites keep using these token names.
public enum ProtonColor {
    // Brand accent — legitimately custom (the only fixed brand hue; readable on light + dark).
    public static let primary = Color(hex: 0x6D4AFF)

    // Backgrounds → semantic, appearance-adaptive. Prefer letting native materials/window background show;
    // these are for the few chrome surfaces that need an explicit fill.
    public static let backgroundNorm = Color(nsColor: .windowBackgroundColor)

    // Text → semantic label roles (Dynamic-Type + vibrancy aware).
    public static let textNorm = Color.primary
    public static let textWeak = Color.secondary
    public static let textHint = Color(nsColor: .tertiaryLabelColor)

    // Signal — brand-tuned, readable in both appearances.
    public static let danger = Color(hex: 0xDC3251)
    public static let warning = Color(hex: 0xFF9900)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
