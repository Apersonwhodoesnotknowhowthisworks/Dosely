import XCTest
import SwiftUI
import FirebaseCore
@testable import Dosely

/// Regression coverage for the bug where AddMedicationView rendered a
/// blank white sheet when launched from the supervisor dashboard's
/// Quick Actions without a preselected person. The dashboard wrapped
/// the sheet body in `if let target = pendingAddTargetPersonID { ... }`
/// — when the optional unwrap failed at render time, the closure
/// produced no view and SwiftUI presented an empty sheet.
///
/// The fix split into two parts that each warrant a probe:
///
/// 1. The decision logic — does the in-flow picker belong on screen
///    right now? — is a pure static function on `AddMedicationFlow`.
///    Direct unit test below.
/// 2. The rendered body must produce non-empty content in *both*
///    arms (with and without a preselected target). A `UIHostingController`
///    smoke test renders each variant offscreen and walks the resulting
///    UIKit subview tree for any visible label text. An empty body
///    produces no labels — that's the regression we're guarding.
@MainActor
final class AddMedicationFlowTests: XCTestCase {
    private static var firebaseConfigured = false

    override func setUp() {
        super.setUp()
        Self.configureFirebaseIfNeeded()
    }

    private static func configureFirebaseIfNeeded() {
        if !firebaseConfigured {
            if FirebaseApp.app() == nil { FirebaseApp.configure() }
            firebaseConfigured = true
        }
    }

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

    // MARK: - Render smoke tests

    /// Quick Actions case: no person preselected on the dashboard, so
    /// `supervisorTargetPersonID` is nil. The body MUST still render —
    /// it should drop into the in-flow target picker rather than
    /// returning an empty view.
    func test_addMedicationFlow_rendersNonEmpty_whenLaunchedWithoutTargetPersonID() {
        let view = AddMedicationFlow(
            repository: MedicationRepository(stack: CoreDataStack(inMemory: true)),
            onSaved: {}
        )
        .environmentObject(AuthService())

        XCTAssertFalse(rendered(view).isEmpty,
                       "AddMedicationFlow must render visible content even when no target is provided (Quick Actions case)")
    }

    /// Person-detail case: dashboard or PersonDetailView preselected
    /// the patient via environment. The body should render the
    /// medication-detail steps directly, not the picker — and obviously
    /// not nothing.
    func test_addMedicationFlow_rendersNonEmpty_whenLaunchedWithTargetPersonID() {
        let view = AddMedicationFlow(
            repository: MedicationRepository(stack: CoreDataStack(inMemory: true)),
            onSaved: {}
        )
        .environmentObject(AuthService())
        .environment(\.supervisorTargetPersonID, UUID())

        XCTAssertFalse(rendered(view).isEmpty,
                       "AddMedicationFlow must render visible content when a target is provided")
    }

    // MARK: - Helpers

    /// Hosts `view` in a UIHostingController, lays it out at iPhone 15
    /// dimensions, and walks the resulting subview tree for any
    /// non-empty label/text-view text. Returns those strings — empty
    /// means the body produced no rendered content.
    private func rendered<V: View>(_ view: V) -> [String] {
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return Self.collectVisibleText(in: controller.view)
    }

    private static func collectVisibleText(in view: UIView) -> [String] {
        var found: [String] = []
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            found.append(text)
        }
        if let textView = view as? UITextView, !textView.text.isEmpty {
            found.append(textView.text)
        }
        for sub in view.subviews {
            found.append(contentsOf: collectVisibleText(in: sub))
        }
        return found
    }
}
