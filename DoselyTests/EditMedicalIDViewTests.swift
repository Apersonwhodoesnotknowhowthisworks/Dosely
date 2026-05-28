import XCTest
@testable import Dosely

/// Regression coverage for `EditMedicalIDView`'s in-flow target
/// picker decision — does the picker belong on screen right now?
///
/// This file used to also carry two `UIHostingController` render-walk
/// "smoke" tests (form arm / picker arm). Both were deleted: under
/// recent iOS, SwiftUI no longer materialises `Text` as `UILabel`s in
/// the offscreen UIView tree, so the walker returned `[]` and the
/// asserts were vacuous (they failed the moment the test target
/// compiled again). The only proof they were reaching for — which arm
/// the view picks for a given target state — is exactly what the pure
/// `shouldShowTargetPicker` helper encodes, and the tests below cover
/// every branch of it directly.
final class EditMedicalIDViewTests: XCTestCase {

    // MARK: - Decision logic

    func test_shouldShowTargetPicker_isTrueWhenNoTargetIsKnown() {
        XCTAssertTrue(EditMedicalIDView.shouldShowTargetPicker(
            envTargetPersonID: nil, pickedTargetPersonID: nil
        ))
    }

    func test_shouldShowTargetPicker_isFalseWhenEnvTargetIsSet() {
        XCTAssertFalse(EditMedicalIDView.shouldShowTargetPicker(
            envTargetPersonID: UUID(), pickedTargetPersonID: nil
        ))
    }

    func test_shouldShowTargetPicker_isFalseWhenInFlowPickHasResolved() {
        XCTAssertFalse(EditMedicalIDView.shouldShowTargetPicker(
            envTargetPersonID: nil, pickedTargetPersonID: UUID()
        ))
    }
}
