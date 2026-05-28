import XCTest
@testable import Dosely

/// Pure-logic coverage for `EmergencyMedicalIDViewModel` — the value type
/// the read-only paramedic viewer branches on. No Core Data, no render:
/// every decision below is a property of the value type, so a regression
/// in section visibility, the empty-state collapse, age math, or the
/// `tel:` sanitiser fails here long before it reaches a device.
final class EmergencyMedicalIDViewModelTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        return cal.date(from: c)!
    }

    private func contact(_ name: String, _ phone: String) -> FirestoreModels.FEmergencyContact {
        FirestoreModels.FEmergencyContact(name: name, relationship: "Daughter", phone: phone)
    }

    // MARK: - Empty state

    /// No record at all → empty state, and `hasRecord` reports the
    /// distinction (a row that exists but is blank is a different thing
    /// from no row, even though both render the same empty card).
    func test_emptyState_whenNoRecord() {
        let vm = EmergencyMedicalIDViewModel(medicalID: nil)
        XCTAssertTrue(vm.isEmptyState)
        XCTAssertFalse(vm.hasRecord)
    }

    /// A record whose every field is blank must still read as "nothing
    /// here" — never a grid of empty placeholders a paramedic might
    /// misread as a complete, all-clear record.
    func test_emptyState_whenRecordExistsButEveryFieldBlank() {
        let vm = EmergencyMedicalIDViewModel(
            hasRecord: true, dateOfBirth: nil, bloodType: "",
            allergies: [], conditions: [], contacts: [], notes: ""
        )
        XCTAssertTrue(vm.isEmptyState)
    }

    /// A record carrying only a date of birth is NOT empty: the header
    /// band shows it, so the empty card would wrongly hide real info.
    func test_notEmptyState_whenOnlyDateOfBirthPresent() {
        let vm = EmergencyMedicalIDViewModel(
            hasRecord: true, dateOfBirth: date(1958, 3, 12), bloodType: "",
            allergies: [], conditions: [], contacts: [], notes: ""
        )
        XCTAssertFalse(vm.isEmptyState)
        XCTAssertTrue(vm.hasDateOfBirth)
    }

    // MARK: - Section visibility

    /// Empty allergies → the Allergies section is suppressed. This is the
    /// exact decision the view reads to decide whether to draw the
    /// heading, asserted at the source rather than by walking the render.
    func test_showAllergies_isFalseWhenEmpty_trueWhenPopulated() {
        XCTAssertFalse(EmergencyMedicalIDViewModel(
            hasRecord: true, dateOfBirth: nil, bloodType: "",
            allergies: [], conditions: [], contacts: [], notes: ""
        ).showAllergies)

        XCTAssertTrue(EmergencyMedicalIDViewModel(
            hasRecord: true, dateOfBirth: nil, bloodType: "",
            allergies: ["Penicillin"], conditions: [], contacts: [], notes: ""
        ).showAllergies)
    }

    /// Every section predicate flips to true once its field has content,
    /// and the view is no longer in the empty state.
    func test_sectionPredicates_reflectContent() {
        let vm = EmergencyMedicalIDViewModel(
            hasRecord: true,
            dateOfBirth: date(1958, 3, 12),
            bloodType: "O+",
            allergies: ["Penicillin"],
            conditions: ["Hypertension"],
            contacts: [contact("Aunt Bibi", "555-0101")],
            notes: "Uses a hearing aid"
        )
        XCTAssertFalse(vm.isEmptyState)
        XCTAssertTrue(vm.showBloodType)
        XCTAssertTrue(vm.showAllergies)
        XCTAssertTrue(vm.showConditions)
        XCTAssertTrue(vm.showContacts)
        XCTAssertTrue(vm.showNotes)
    }

    // MARK: - Age

    /// Age is whole completed years to the as-of date — birthday already
    /// passed in the as-of year.
    func test_age_afterBirthdayInYear() {
        let vm = EmergencyMedicalIDViewModel(
            hasRecord: true, dateOfBirth: date(1958, 3, 12), bloodType: "",
            allergies: [], conditions: [], contacts: [], notes: ""
        )
        XCTAssertEqual(vm.age(asOf: date(2026, 5, 28), calendar: cal), 68)
    }

    /// Before the birthday in the as-of year the count is one lower —
    /// proves the month/day component is honoured, not just the year diff.
    func test_age_beforeBirthdayInYear() {
        let vm = EmergencyMedicalIDViewModel(
            hasRecord: true, dateOfBirth: date(1958, 3, 12), bloodType: "",
            allergies: [], conditions: [], contacts: [], notes: ""
        )
        XCTAssertEqual(vm.age(asOf: date(2026, 1, 1), calendar: cal), 67)
    }

    func test_age_nilWhenNoDateOfBirth() {
        let vm = EmergencyMedicalIDViewModel(medicalID: nil)
        XCTAssertNil(vm.age(asOf: date(2026, 5, 28), calendar: cal))
    }

    // MARK: - tel: sanitising

    /// Spaces, dashes, and parentheses are stripped so the dialer gets a
    /// bare digit string.
    func test_telURL_stripsFormatting() {
        XCTAssertEqual(
            EmergencyMedicalIDViewModel.telURL(from: "(555) 010-1234"),
            URL(string: "tel://5550101234")
        )
    }

    /// A leading "+" (international dialling) is a non-digit and is
    /// stripped along with the spaces.
    func test_telURL_stripsLeadingPlusAndSpaces() {
        XCTAssertEqual(
            EmergencyMedicalIDViewModel.telURL(from: "+1 555 0101"),
            URL(string: "tel://15550101")
        )
    }

    /// A string with no digits yields no URL rather than a malformed
    /// `tel://` — the view hides the tap action in that case.
    func test_telURL_isNilWhenNoDigits() {
        XCTAssertNil(EmergencyMedicalIDViewModel.telURL(from: "call the office"))
    }
}
