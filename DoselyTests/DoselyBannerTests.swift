import SwiftUI
import UIKit
import XCTest
@testable import Dosely

/// Render smoke for `DoselyBanner` — the brand header on the sign-in screen
/// and the client home. Same idiom as the other view smoke tests: host the
/// view, force layout, and confirm it produced non-empty content. We do NOT
/// walk the view tree for the wordmark text — under recent iOS SwiftUI doesn't
/// materialise `Text` as `UILabel`s offscreen, so such a walk is vacuous (the
/// 2026-05-28 lesson, see `EmergencyMedicalIDViewTests`).
///
/// Both branches are exercised: WITH the bundled logo art, and WITHOUT it (a
/// deliberately-absent asset name forcing the text-wordmark fallback).
@MainActor
final class DoselyBannerTests: XCTestCase {

    /// Hosts a view and returns the size its content actually wants. A non-zero
    /// result proves the banner rendered something rather than collapsing to
    /// nothing; a crash in `body`/layout fails the test before we get here.
    private func fittingSize(_ view: some View) -> CGSize {
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return controller.sizeThatFits(in: CGSize(width: 390,
                                                  height: CGFloat.greatestFiniteMagnitude))
    }

    func test_logoAssetIsBundled() {
        XCTAssertNotNil(UIImage(named: "DoselyLogo"),
                        "the DoselyLogo image set must be wired into the asset catalog")
    }

    func test_bannerRendersWithLogo() {
        let size = fittingSize(DoselyBanner())
        XCTAssertGreaterThan(size.width, 0, "banner with the logo should produce content")
        XCTAssertGreaterThan(size.height, 0, "banner with the logo should produce content")
    }

    func test_bannerRendersWithoutLogo_fallsBackToWordmark() {
        let size = fittingSize(DoselyBanner(imageName: "DoselyLogo.__absent__"))
        XCTAssertGreaterThan(size.width, 0, "fallback wordmark should still produce content")
        XCTAssertGreaterThan(size.height, 0, "fallback wordmark should still produce content")
    }
}
