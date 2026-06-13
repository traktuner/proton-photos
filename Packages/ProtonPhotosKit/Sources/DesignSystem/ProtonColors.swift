import SwiftUI

/// Proton design tokens (dark "Carbon" theme).
///
/// Values mirror Proton's `@proton/colors` dark theme. They are centralised here so the
/// whole app references tokens, never raw hex — when we reconcile 1:1 against the Proton
/// Storybook, only this file changes.
public enum ProtonColor {
    // Brand
    public static let primary = Color(hex: 0x6D4AFF)
    public static let primaryHover = Color(hex: 0x7C5CFF)
    public static let primaryActive = Color(hex: 0x5C3FD6)

    // Backgrounds (dark)
    public static let backgroundNorm = Color(hex: 0x16141C)
    public static let backgroundWeak = Color(hex: 0x1C1A24)
    public static let backgroundStrong = Color(hex: 0x292637)
    public static let backgroundElevated = Color(hex: 0x211F2B)

    // Text
    public static let textNorm = Color(hex: 0xFFFFFF)
    public static let textWeak = Color(hex: 0xA7A4B5)
    public static let textHint = Color(hex: 0x6D697D)
    public static let textInverted = Color(hex: 0x16141C)

    // Borders / separators
    public static let borderNorm = Color(hex: 0x4A4658)
    public static let borderWeak = Color(hex: 0x322F3E)

    // Signal
    public static let danger = Color(hex: 0xDC3251)
    public static let success = Color(hex: 0x1EA885)
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
