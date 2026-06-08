import XCTest
@testable import Dosely

/// The Care circle card's join-code display decision. Pure static-helper tests
/// (no render walks, per the 2026-05-28 walker-triage lesson). The card's name
/// and join code are now re-synced from the live CareCircle record (the
/// root-cause-A binding fix); these pin the value-vs-loading rendering so the
/// blank "—" placeholder can never come back for a real code, and so a present
/// code renders character-for-character (no invented formatting).
final class PeopleManagementViewTests: XCTestCase {

    private let loading = "Generating code…"

    func test_joinCodeDisplay_showsRealCodeCharForChar() {
        XCTAssertEqual(
            CircleSettingsSection.joinCodeDisplayValue("482913", loadingText: loading),
            "482913"
        )
    }

    func test_joinCodeDisplay_preservesLeadingZeros() {
        // Join codes are "%06d" — a code that starts with zeros must render in
        // full, never trimmed.
        XCTAssertEqual(
            CircleSettingsSection.joinCodeDisplayValue("000123", loadingText: loading),
            "000123"
        )
    }

    func test_joinCodeDisplay_showsLoadingWhenNil() {
        XCTAssertEqual(
            CircleSettingsSection.joinCodeDisplayValue(nil, loadingText: loading),
            loading
        )
    }

    func test_joinCodeDisplay_showsLoadingWhenEmpty_neverPlaceholderDash() {
        let shown = CircleSettingsSection.joinCodeDisplayValue("", loadingText: loading)
        XCTAssertEqual(shown, loading)
        XCTAssertNotEqual(shown, "—")
        XCTAssertNotEqual(shown, "_")
    }
}
