import XCTest
@testable import Dosely

/// Every localization key the profile switcher references must resolve in
/// BOTH shipped languages — same pattern and rationale as
/// `EmergencyMedicalIDLocalizationTests`: `localizedString` returns the key
/// verbatim when it is missing from an `.lproj`, which is the exact "raw
/// key showed up in the UI" failure mode, and the Punjabi mirror is a hard
/// requirement (the primary client's first language is Punjabi).
final class ProfileSwitchLocalizationTests: XCTestCase {

    private let keys: [String] = [
        "profileswitch.affordance.button.title",
        "profileswitch.affordance.caption",
        "profileswitch.confirm.title",
        "profileswitch.confirm.body.line1",
        "profileswitch.confirm.body.line2",
        "profileswitch.confirm.body.line3",
        "profileswitch.confirm.button.confirm",
        "profileswitch.confirm.button.cancel",
        "profileswitch.banner.actingas",
        "profileswitch.banner.switchback",
        "profileswitch.banner.button",
        "profileswitch.banner.button.a11y",
        "profileswitch.error.notprimary",
        "profileswitch.error.selftarget",
        "profileswitch.error.notincircle",
        "profileswitch.error.ineligible",
        "profileswitch.error.notfound"
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
                              "Key \"\(key)\" is missing from pa.lproj — every English profile-switch string needs its Punjabi mirror")
        }
    }

    func test_formatSpecifiersMatchAcrossLanguages() throws {
        // A pa edit that drops or doubles a %@ would feed String(format:)
        // a mismatched template at runtime (the name silently vanishes or a
        // literal %@ renders). Pin specifier parity per key, not just
        // presence.
        let en = try lprojBundle("en")
        let pa = try lprojBundle("pa")
        for key in keys {
            let enCount = specifierCount(en.localizedString(forKey: key, value: nil, table: nil))
            let paCount = specifierCount(pa.localizedString(forKey: key, value: nil, table: nil))
            XCTAssertEqual(enCount, paCount,
                           "Key \"\(key)\" has \(enCount) format specifier(s) in en but \(paCount) in pa")
        }
    }

    /// Counts C-style format specifiers, ignoring escaped `%%`.
    private func specifierCount(_ template: String) -> Int {
        var count = 0
        var iterator = template.makeIterator()
        while let char = iterator.next() {
            guard char == "%" else { continue }
            if let next = iterator.next(), next != "%" { count += 1 }
        }
        return count
    }
}
