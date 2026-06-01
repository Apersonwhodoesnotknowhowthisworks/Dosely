import SwiftUI
import XCTest
@testable import Dosely

/// Pins the larger-text floor logic (`AccessibilityScaling`) the root applies
/// for the `force_larger_text` toggle. Tested as pure logic rather than by
/// hosting the root and reading its environment — the same no-render-walk
/// principle as the May 28 triage. `.dynamicTypeSize(floor...)` produces exactly
/// `effectiveSize(...)`.
final class AccessibilityToggleTests: XCTestCase {

    func test_forceLargerText_appliesFloorToRoot() {
        let size = AccessibilityScaling.effectiveSize(forceLargerText: true, systemSize: .large)
        XCTAssertGreaterThanOrEqual(size, .accessibility1,
                                    "with the toggle on, a small system size is raised to the floor")
        XCTAssertEqual(size, .accessibility1)
    }

    func test_forceLargerText_doesNotReduceSystemSetting() {
        let size = AccessibilityScaling.effectiveSize(forceLargerText: true, systemSize: .accessibility5)
        XCTAssertEqual(size, .accessibility5, "the floor must never cap a larger system setting downward")
    }

    func test_forceLargerText_off_followsSystem() {
        let size = AccessibilityScaling.effectiveSize(forceLargerText: false, systemSize: .large)
        XCTAssertEqual(size, .large, "with the toggle off, the app follows the system size")
    }
}
