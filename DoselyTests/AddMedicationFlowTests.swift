import XCTest
@testable import Dosely

/// Regression coverage for the bug where AddMedicationView rendered a
/// blank white sheet when launched from the supervisor dashboard's
/// Quick Actions without a preselected person. The dashboard wrapped
/// the sheet body in `if let target = pendingAddTargetPersonID { ... }`
/// — when the optional unwrap failed at render time, the closure
/// produced no view and SwiftUI presented an empty sheet. The fix
/// routes the body through `AddMedicationFlow.shouldShowTargetPicker`
/// so a missing target drops into the in-flow picker instead of
/// nothing.
///
/// This file used to also carry two `UIHostingController` render-walk
/// "smoke" tests asserting the body produced non-empty label text in
/// both arms. Both were deleted: under recent iOS, SwiftUI no longer
/// materialises `Text` as `UILabel`s in the offscreen UIView tree, so
/// the walker returned `[]` and both asserts failed the moment the
/// test target compiled again — they caught the framework, not a
/// regression. The proof that actually guards the blank-sheet bug —
/// the body always selects a non-empty arm — is the branch logic
/// below, tested directly.
final class AddMedicationFlowTests: XCTestCase {

    // MARK: - Decision logic

    func test_shouldShowTargetPicker_returnsTrueWhenNoTargetIsKnown() {
        XCTAssertTrue(AddMedicationFlow.shouldShowTargetPicker(
            supervisorTargetPersonID: nil,
            pickedTargetPersonID: nil
        ))
    }

    func test_shouldShowTargetPicker_isFalseWhenEnvironmentTargetIsSet() {
        XCTAssertFalse(AddMedicationFlow.shouldShowTargetPicker(
            supervisorTargetPersonID: UUID(),
            pickedTargetPersonID: nil
        ))
    }

    func test_shouldShowTargetPicker_isFalseWhenInFlowPickHasResolved() {
        XCTAssertFalse(AddMedicationFlow.shouldShowTargetPicker(
            supervisorTargetPersonID: nil,
            pickedTargetPersonID: UUID()
        ))
    }

    func test_shouldShowTargetPicker_isFalseWhenBothAreSet() {
        XCTAssertFalse(AddMedicationFlow.shouldShowTargetPicker(
            supervisorTargetPersonID: UUID(),
            pickedTargetPersonID: UUID()
        ))
    }
}
