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
//
// As of the 2026-06-01 accessibility pass, each token resolves FOUR cells —
// userInterfaceStyle (light/dark) × accessibilityContrast (normal/high):
//   • light/normal — the validated brand palette (Prompt 1).
//   • light/high   — text pushed to black, semantic fills deepened for more
//                    contrast on white surfaces; backgrounds unchanged.
//   • dark/normal  — Tailwind 600/700 fills so white-on-fill clears AA.
//   • dark/high    — text pushed to white, background to true black, fills
//                    deepened FURTHER (not lightened) so white-on-fill clears
//                    AA with room — see the dark/high note on the helper.
// High contrast activates from iOS "Increase Contrast" OR the in-app
// `force_high_contrast` default; the toggle adds on top, never overrides iOS.

extension Color {

    // MARK: - Brand & semantic tokens (adaptive, 4-cell)
    //
    // Four cells per token (light/dark × normal/high contrast) — see the
    // "4-cell" note in the file header. Every cell is verified ≥ 4.5:1 by
    // `DSColorsContrastTests`. Dark fills sit at the Tailwind 600/700 weights so
    // white-on-fill clears AA; the originally-suggested "lifted" variants
    // (#4A90E2, #48BB78, #ECC94B, #F56565) failed that floor and were rejected.

    static let dsBackground    = adaptive(lightNormal: 0xF7FAFC, lightHigh: 0xF7FAFC, darkNormal: 0x0F1419, darkHigh: 0x000000)
    static let dsSurface       = adaptive(lightNormal: 0xFFFFFF, lightHigh: 0xFFFFFF, darkNormal: 0x1A202C, darkHigh: 0x1A1A1A)
    static let dsTextPrimary   = adaptive(lightNormal: 0x1A202C, lightHigh: 0x000000, darkNormal: 0xF7FAFC, darkHigh: 0xFFFFFF)
    static let dsTextSecondary = adaptive(lightNormal: 0x4A5568, lightHigh: 0x1F2937, darkNormal: 0xA0AEC0, darkHigh: 0xE2E8F0)
    static let dsPrimary       = adaptive(lightNormal: 0x2B6CB0, lightHigh: 0x1E40AF, darkNormal: 0x2563EB, darkHigh: 0x1D4ED8)
    static let dsSuccess       = adaptive(lightNormal: 0x2F855A, lightHigh: 0x166534, darkNormal: 0x15803D, darkHigh: 0x166534)
    // dsWarning is pinned identical in light/normal AND light/high: light amber
    // is already at the white-on-fill 4.5:1 boundary (#D69E2E failed at 2.39:1
    // on the Snooze button), and deepening it further would clear contrast but
    // lose the amber and break the brand color. Dark/high deepens to amber-800,
    // where there is room. Pinned in DSColorsContrastTests.
    static let dsWarning       = adaptive(lightNormal: 0xB45309, lightHigh: 0xB45309, darkNormal: 0xB45309, darkHigh: 0x92400E)
    static let dsDanger        = adaptive(lightNormal: 0xC53030, lightHigh: 0x991B1B, darkNormal: 0xDC2626, darkHigh: 0xB91C1C)

    // MARK: - Helpers

    /// Resolves to one of four hex values by `userInterfaceStyle` ×
    /// `accessibilityContrast`. High contrast activates from iOS's "Increase
    /// Contrast" trait OR the in-app `force_high_contrast` default — the latter
    /// adds on top, never reducing iOS's setting.
    ///
    /// Note on dark/high: semantic FILLS deepen (go darker) rather than lighten.
    /// White text sits on these fills, and the contrast suite pins white-on-fill
    /// ≥ 4.5:1; a lighter fill lowers that ratio (dark/normal is already only
    /// ~5:1), so deepening is what actually raises contrast for the button text.
    /// The UserDefaults read is the only wrinkle; UIColor invokes the provider
    /// per resolved trait, so it stays a cheap, side-effect-free `bool(forKey:)`.
    static func adaptive(lightNormal: UInt32, lightHigh: UInt32,
                         darkNormal: UInt32, darkHigh: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let highContrast = trait.accessibilityContrast == .high
                || UserDefaults.standard.bool(forKey: "force_high_contrast")
            let isDark = trait.userInterfaceStyle == .dark
            switch (isDark, highContrast) {
            case (false, false): return UIColor(hex: lightNormal)
            case (false, true):  return UIColor(hex: lightHigh)
            case (true, false):  return UIColor(hex: darkNormal)
            case (true, true):   return UIColor(hex: darkHigh)
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
