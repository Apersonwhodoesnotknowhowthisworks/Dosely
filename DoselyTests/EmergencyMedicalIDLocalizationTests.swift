import XCTest
@testable import Dosely

/// Every localization key the Emergency Medical ID feature references
/// must resolve in BOTH shipped languages. `localizedString` returns the
/// key verbatim when it is missing from an `.lproj`, which is the exact
/// "raw key showed up in the UI" failure mode — and for `pa` it also
/// guards against the English section being added without its Punjabi
/// mirror (the mirror is a hard requirement: the primary client's first
/// language is Punjabi).
final class EmergencyMedicalIDLocalizationTests: XCTestCase {

    private let keys: [String] = [
        "emergency.medicalid.button.title",
        "emergency.medicalid.view.action",
        "emergency.medicalid.picker.title",
        "emergency.medicalid.viewer.title",
        "emergency.medicalid.empty.title",
        "emergency.medicalid.empty.subtitle",
        "emergency.medicalid.section.allergies",
        "emergency.medicalid.section.conditions",
        "emergency.medicalid.section.contacts",
        "emergency.medicalid.section.notes",
        "emergency.medicalid.bloodtype.label",
        "emergency.medicalid.dob",
        "emergency.medicalid.contact.call.a11yLabel",
        "emergency.medicalid.contact.call.a11yHint"
    ]

    /// Resources ship in the app bundle, not the test bundle. Find the
    /// bundle hosting a known Dosely type, then resolve its `<code>.lproj`.
    private func lprojBundle(_ code: String) throws -> Bundle {
        let candidates = [Bundle(for: AuthService.self), Bundle.main, Bundle(for: type(of: self))]
        for host in candidates {
            if let url = host.url(forResource: code, withExtension: "lproj"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        throw XCTSkip("\(code).lproj not found in any candidate bundle for this test host")
    }

    func test_allKeysResolve_inEnglish() throws {
        let bundle = try lprojBundle("en")
        for key in keys {
            let resolved = bundle.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(resolved, key,
                              "Key \"\(key)\" is missing from en.lproj — bundle returned the key verbatim")
        }
    }

    func test_allKeysResolve_inPunjabi() throws {
        let bundle = try lprojBundle("pa")
        for key in keys {
            let resolved = bundle.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(resolved, key,
                              "Key \"\(key)\" is missing from pa.lproj — every English Medical ID string needs its Punjabi mirror")
        }
    }
}
