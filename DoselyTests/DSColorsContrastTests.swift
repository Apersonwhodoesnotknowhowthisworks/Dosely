import XCTest
import SwiftUI
import UIKit
@testable import Dosely

/// WCAG AA requires ≥ 4.5:1 contrast for normal body text and ≥ 3:1 for
/// large text. We hold all of Dosely's foreground/background pairs to the
/// stricter 4.5 floor — the audience reads at arm's length and we'd rather
/// over-engineer this than ship dim text.
final class DSColorsContrastTests: XCTestCase {

    // MARK: - Light mode

    func testLightTextPrimaryOnBackground() {
        assertContrast(.dsTextPrimary, on: .dsBackground, mode: .light, atLeast: 4.5)
    }
    func testLightTextPrimaryOnSurface() {
        assertContrast(.dsTextPrimary, on: .dsSurface, mode: .light, atLeast: 4.5)
    }
    func testLightTextSecondaryOnBackground() {
        assertContrast(.dsTextSecondary, on: .dsBackground, mode: .light, atLeast: 4.5)
    }
    func testLightTextSecondaryOnSurface() {
        assertContrast(.dsTextSecondary, on: .dsSurface, mode: .light, atLeast: 4.5)
    }
    func testLightWhiteOnPrimary() {
        assertContrast(.white, on: .dsPrimary, mode: .light, atLeast: 4.5)
    }
    func testLightWhiteOnDanger() {
        assertContrast(.white, on: .dsDanger, mode: .light, atLeast: 4.5)
    }
    func testLightWhiteOnSuccess() {
        assertContrast(.white, on: .dsSuccess, mode: .light, atLeast: 4.5)
    }
    func testLightWhiteOnWarning() {
        assertContrast(.white, on: .dsWarning, mode: .light, atLeast: 4.5)
    }

    // MARK: - Dark mode

    func testDarkTextPrimaryOnBackground() {
        assertContrast(.dsTextPrimary, on: .dsBackground, mode: .dark, atLeast: 4.5)
    }
    func testDarkTextPrimaryOnSurface() {
        assertContrast(.dsTextPrimary, on: .dsSurface, mode: .dark, atLeast: 4.5)
    }
    func testDarkTextSecondaryOnBackground() {
        assertContrast(.dsTextSecondary, on: .dsBackground, mode: .dark, atLeast: 4.5)
    }
    func testDarkTextSecondaryOnSurface() {
        assertContrast(.dsTextSecondary, on: .dsSurface, mode: .dark, atLeast: 4.5)
    }
    func testDarkWhiteOnPrimary() {
        assertContrast(.white, on: .dsPrimary, mode: .dark, atLeast: 4.5)
    }
    func testDarkWhiteOnDanger() {
        assertContrast(.white, on: .dsDanger, mode: .dark, atLeast: 4.5)
    }
    func testDarkWhiteOnSuccess() {
        assertContrast(.white, on: .dsSuccess, mode: .dark, atLeast: 4.5)
    }
    func testDarkWhiteOnWarning() {
        assertContrast(.white, on: .dsWarning, mode: .dark, atLeast: 4.5)
    }

    // MARK: - Adaptive guard (resolves differently between appearances)
    //
    // The regression these catch: a token gets wired to the same value in both
    // appearances (e.g. someone copies the light hex into both arms of
    // `adaptive(light:dark:)`). Contrast can still pass while the token has
    // silently stopped adapting — which is exactly the "invisible text in dark
    // mode" bug that started this whole effort. Every adaptive token must
    // therefore resolve to a DIFFERENT CGColor under light vs dark traits.

    func testBackgroundResolvesDifferentlyByAppearance() {
        assertResolvesDifferently(.dsBackground)
    }
    func testSurfaceResolvesDifferentlyByAppearance() {
        assertResolvesDifferently(.dsSurface)
    }
    func testTextPrimaryResolvesDifferentlyByAppearance() {
        assertResolvesDifferently(.dsTextPrimary)
    }
    func testTextSecondaryResolvesDifferentlyByAppearance() {
        assertResolvesDifferently(.dsTextSecondary)
    }
    func testPrimaryResolvesDifferentlyByAppearance() {
        assertResolvesDifferently(.dsPrimary)
    }
    func testSuccessResolvesDifferentlyByAppearance() {
        assertResolvesDifferently(.dsSuccess)
    }
    func testDangerResolvesDifferentlyByAppearance() {
        assertResolvesDifferently(.dsDanger)
    }

    /// dsWarning is the documented exception: it's pinned to Tailwind amber-700
    /// (#B45309) in BOTH appearances because that's the only weight that clears
    /// white-on-fill ≥ 4.5:1 in each direction (light-mode #D69E2E failed at
    /// 2.39:1 on the Snooze button). So unlike every other token it must resolve
    /// IDENTICALLY — this test pins that intent so a future "make dsWarning adapt
    /// too" change has to consciously re-check the white-on-warning floor first.
    func testWarningResolvesIdenticallyByAppearance() {
        assertResolvesIdentically(.dsWarning)
    }

    // MARK: - Plumbing

    private func assertContrast(_ fg: Color,
                                on bg: Color,
                                mode: UIUserInterfaceStyle,
                                atLeast minimum: Double,
                                file: StaticString = #file,
                                line: UInt = #line) {
        let trait = UITraitCollection(userInterfaceStyle: mode)
        let fgUI = UIColor(fg).resolvedColor(with: trait)
        let bgUI = UIColor(bg).resolvedColor(with: trait)
        let ratio = Self.contrastRatio(fgUI, bgUI)
        let modeName = mode == .dark ? "dark" : "light"
        XCTAssertGreaterThanOrEqual(
            ratio, minimum,
            "Contrast \(String(format: "%.2f", ratio)):1 in \(modeName) mode is below WCAG floor \(minimum):1.",
            file: file, line: line
        )
    }

    private func assertResolvesDifferently(_ color: Color,
                                           file: StaticString = #file,
                                           line: UInt = #line) {
        let light = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark  = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertNotEqual(
            light.cgColor, dark.cgColor,
            "Token resolves to the same value in light and dark — it has stopped "
            + "adapting, which is the dark-mode invisible-text bug this suite guards.",
            file: file, line: line
        )
    }

    private func assertResolvesIdentically(_ color: Color,
                                           file: StaticString = #file,
                                           line: UInt = #line) {
        let light = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark  = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertEqual(
            light.cgColor, dark.cgColor,
            "dsWarning is intentionally pinned to one value in both appearances "
            + "(amber-700, for white-on-fill AA). If this fails the pin changed — "
            + "re-verify white-on-warning ≥ 4.5:1 in both modes before shipping.",
            file: file, line: line
        )
    }

    /// WCAG 2.x relative-luminance contrast ratio.
    private static func contrastRatio(_ a: UIColor, _ b: UIColor) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let lighter = max(la, lb)
        let darker  = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let R = channelLuminance(Double(r))
        let G = channelLuminance(Double(g))
        let B = channelLuminance(Double(b))
        return 0.2126 * R + 0.7152 * G + 0.0722 * B
    }

    private static func channelLuminance(_ component: Double) -> Double {
        component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
}
