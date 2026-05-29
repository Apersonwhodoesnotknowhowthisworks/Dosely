import SwiftUI
import UIKit

// MARK: - Sanctioned non-token color usages
//
// A periodic grep for `Color.red/blue/black/white/gray`, `Color(red:…)`,
// `Color(hex:…)`, or `UIColor.…` outside this file is how we keep raw color
// literals from rotting back into the app. As of the 2026-05-28 audit, every
// hit outside DSColors falls into one of four categories that are deliberately
// NOT design-system tokens — documented here, with the less-obvious sites also
// tagged inline ("see DSColors audit note"), so a future grep doesn't re-flag
// them:
//
//  1. White-on-fill — `.foregroundColor(.white)` and white pill backgrounds
//     layered on a saturated DS fill (dsPrimary / dsDanger / dsSuccess /
//     dsWarning). White is correct on all four in BOTH appearances; the
//     contrast tests pin white-on-fill ≥ 4.5:1 in light AND dark. Because the
//     fill is what adapts, the white is appearance-independent by design.
//  2. Dimming scrims — `Color.black.opacity(0.1…0.55)` behind sheets and
//     full-screen covers, count-badge backdrops, and the camera viewfinder's
//     solid black. A scrim is meant to be black regardless of appearance;
//     adapting it would defeat the dimming.
//  3. Adaptive system grays — `Color.gray.opacity(…)` for disabled controls,
//     empty/future history cells, and progress tracks. `Color.gray` is itself
//     trait-reactive (it shifts light↔dark), so these are NOT fixed-literal
//     bypasses; they already adapt. Left as-is rather than tokenized so their
//     on-device appearance doesn't change.
//  4. Card elevation shadows — `Color.black.opacity(0.06)`. Shadows fade to
//     invisible against a dark surface by convention; in dark mode the
//     dsSurface/dsBackground contrast carries separation instead.
//
// Anything that does NOT fit these four belongs as a DS token. Content text
// and surfaces already route through the adaptive tokens below.

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
