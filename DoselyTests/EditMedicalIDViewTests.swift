import SwiftUI
import XCTest
import FirebaseCore
@testable import Dosely

/// Regression coverage for `EditMedicalIDView`. Two flavours:
///
/// 1. The pure decision logic — does the in-flow picker belong on
///    screen? — is a static helper. Direct unit tests verify the
///    mapping without rendering.
/// 2. UIHostingController smoke tests render the view in both arms
///    (form / picker) and assert the resulting UIKit hierarchy
///    carries visible text. Catches the AddMedicationFlow-style trap
///    where a refactor wraps the body in `if let ...` and produces
///    a blank white sheet.
@MainActor
final class EditMedicalIDViewTests: XCTestCase {
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

    // MARK: - Render smoke tests

    /// Launched WITH a target person via environment, the form
    /// renders the section headers. Catches the regression where a
    /// refactor accidentally drops a section.
    func test_editMedicalIDView_rendersFormWhenTargetIsPresent() {
        let stack = CoreDataStack(inMemory: true)
        let view = EditMedicalIDView(
            repository: MedicalIDRepository(stack: stack, firestore: FirestoreService())
        )
        .environmentObject(AuthService())
        .environment(\.supervisorTargetPersonID, UUID())

        let visible = rendered(view)
        XCTAssertTrue(visible.contains(where: { $0.contains("Basics") || $0.contains("Allergies") }),
                      "form arm should render the basic section heading; got: \(visible)")
    }

    /// Launched WITHOUT a target, the in-flow picker renders. The
    /// picker shares the title key with the medical-id-specific copy.
    func test_editMedicalIDView_rendersPickerWhenTargetIsAbsent() {
        let stack = CoreDataStack(inMemory: true)
        let view = EditMedicalIDView(
            repository: MedicalIDRepository(stack: stack, firestore: FirestoreService())
        )
        .environmentObject(AuthService())

        let visible = rendered(view)
        // Either the picker title or its inline copy should be there.
        XCTAssertTrue(visible.contains(where: { $0.contains("Edit Medical ID for whom?") }),
                      "picker arm should render the medical-id picker title; got: \(visible)")
    }

    // MARK: - Helpers

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
