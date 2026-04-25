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
