import SwiftUI
import UIKit

extension Color {

    // MARK: - Brand & semantic tokens (adaptive)
    //
    // Every token below is built from `UIColor(dynamicProvider:)` so that
    // SwiftUI re-evaluates it whenever `colorScheme` changes. Light variants
    // preserve the original brand palette (Prompt 1). Dark variants are
    // tuned to clear WCAG AA (≥ 4.5:1) against `dsBackground` / `dsSurface`,
    // verified by `DSColorsContrastTests`.

    static let dsBackground    = adaptive(light: 0xF7FAFC, dark: 0x0F1419)
    static let dsSurface       = adaptive(light: 0xFFFFFF, dark: 0x1A202C)
    static let dsTextPrimary   = adaptive(light: 0x1A202C, dark: 0xF7FAFC)
    static let dsTextSecondary = adaptive(light: 0x4A5568, dark: 0xA0AEC0)
    // Dark-mode brand fills sit at the Tailwind 600/700 weights so that
    // white text on them clears WCAG AA (≥ 4.5:1). The originally-suggested
    // "lifted" variants (#4A90E2, #48BB78, #ECC94B, #F56565) failed this
    // floor — see DSColorsContrastTests for the proof.
    static let dsPrimary       = adaptive(light: 0x2B6CB0, dark: 0x2563EB)
    static let dsSuccess       = adaptive(light: 0x2F855A, dark: 0x15803D)
    // dsWarning is the same hex in both modes. Light-mode `#D69E2E` failed
    // white-on-fill at 2.39:1 (used for the Snooze button). Tailwind
    // amber-700 clears 4.5:1 in both directions, so we pin it.
    static let dsWarning       = adaptive(light: 0xB45309, dark: 0xB45309)
    static let dsDanger        = adaptive(light: 0xC53030, dark: 0xDC2626)

    // MARK: - Helpers

    /// Returns a `Color` that resolves to one of two hex values depending on
    /// the current trait collection's `userInterfaceStyle`.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            switch trait.userInterfaceStyle {
            case .dark: return UIColor(hex: dark)
            default:    return UIColor(hex: light)
            }
        })
    }
}

extension UIColor {
    /// Builds a `UIColor` from a 24-bit RGB hex literal in sRGB space.
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
