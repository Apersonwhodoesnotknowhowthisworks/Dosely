import XCTest
@testable import Dosely

/// Pure-value tests on the `VoiceUtterance` content builders — no synthesizer,
/// no Core Data. They pin the rendered segment text, the digit-by-digit phone
/// formatting, the suppress-empty-sections rule (shared with the visual
/// `EmergencyMedicalIDView`), and that a Punjabi build carries an English
/// fallback set. Plus a guard that every `voice.*` key resolves in both bundles.
final class VoiceUtteranceBuildersTests: XCTestCase {

    // MARK: - dose

    func test_dose_rendersTemplateAndFoodRule() {
        let u = VoiceUtterance.dose(medication: "Lisinopril", dose: "10 mg",
                                    time: "8:00 AM", foodRule: "with", language: "en")
        XCTAssertEqual(u.segments.first?.text, "Lisinopril, 10 mg, at 8:00 AM.")
        XCTAssertEqual(u.segments.count, 2)
        XCTAssertEqual(u.segments.last?.text, "Take with food.")
        XCTAssertNil(u.fallbackSegments, "an English utterance needs no fallback")
    }

    func test_dose_noFoodRule_isSingleSegment() {
        let u = VoiceUtterance.dose(medication: "Metformin", dose: "500 mg",
                                    time: "9:00 PM", foodRule: "either", language: "en")
        XCTAssertEqual(u.segments.count, 1, "no food-rule sentence for 'either'")
    }

    func test_dose_punjabiCarriesEnglishFallback() {
        let u = VoiceUtterance.dose(medication: "Lisinopril", dose: "10 mg",
                                    time: "8:00 AM", foodRule: nil, language: "pa")
        XCTAssertEqual(u.language, "pa")
        XCTAssertEqual(u.fallbackSegments?.first?.text, "Lisinopril, 10 mg, at 8:00 AM.",
                       "fallback is the English template")
        XCTAssertNotEqual(u.segments.first?.text, u.fallbackSegments?.first?.text,
                          "the Punjabi template must differ from the English one")
    }

    // MARK: - alert

    func test_alert_rendersTitleThenBody() {
        let u = VoiceUtterance.alert(title: "Missed dose",
                                     body: "Margaret missed Lisinopril at 8:00 AM",
                                     language: "en")
        XCTAssertEqual(u.segments.first?.text, "Missed dose. Margaret missed Lisinopril at 8:00 AM.")
        XCTAssertNil(u.fallbackSegments)
    }

    func test_alert_punjabiUsesEnglishFallbackWhenProvided() {
        let u = VoiceUtterance.alert(title: "ਖੁੰਝੀ ਖੁਰਾਕ", body: "…", language: "pa",
                                     fallbackTitle: "Missed dose",
                                     fallbackBody: "Margaret missed Lisinopril")
        XCTAssertEqual(u.fallbackSegments?.first?.text, "Missed dose. Margaret missed Lisinopril.")
    }

    // MARK: - medicalID

    func test_medicalID_speaksPhoneDigitsIndividually() {
        let vm = EmergencyMedicalIDViewModel(
            hasRecord: true, dateOfBirth: nil, bloodType: "", allergies: [], conditions: [],
            contacts: [FirestoreModels.FEmergencyContact(name: "Aunt Bibi", relationship: "Daughter",
                                                         phone: "604-555-1234")],
            notes: "")
        let u = VoiceUtterance.medicalID(vm, personName: "Margaret", dateOfBirthText: nil, language: "en")
        let texts = u.segments.map(\.text)
        XCTAssertTrue(texts.contains { $0.contains("6 0 4 5 5 5 1 2 3 4") },
                      "phone must be spoken one digit at a time")
        XCTAssertTrue(texts.contains { $0.contains("Aunt Bibi") })
    }

    func test_medicalID_suppressesEmptySectionIntros() {
        let vm = EmergencyMedicalIDViewModel(
            hasRecord: true, dateOfBirth: nil, bloodType: "O+",
            allergies: [], conditions: [], contacts: [], notes: "")
        let texts = VoiceUtterance.medicalID(vm, personName: "Margaret",
                                             dateOfBirthText: nil, language: "en").segments.map(\.text)
        XCTAssertFalse(texts.contains("Allergic to:"), "no orphan allergies intro when empty")
        XCTAssertFalse(texts.contains("Medical conditions:"))
        XCTAssertFalse(texts.contains("Emergency contacts:"))
        XCTAssertTrue(texts.contains { $0.contains("O+") }, "blood type still spoken")
    }

    func test_medicalID_punjabiCarriesEnglishFallback() {
        let vm = EmergencyMedicalIDViewModel(
            hasRecord: true, dateOfBirth: nil, bloodType: "A+", allergies: ["Penicillin"],
            conditions: [], contacts: [], notes: "")
        let u = VoiceUtterance.medicalID(vm, personName: "Margaret", dateOfBirthText: nil, language: "pa")
        XCTAssertNotNil(u.fallbackSegments)
        XCTAssertTrue(u.fallbackSegments?.contains { $0.text == "Allergic to:" } ?? false,
                      "English fallback uses the English allergies intro")
    }

    // MARK: - spokenDigits / custom

    func test_spokenDigits_stripsFormattingAndSpacesDigits() {
        XCTAssertEqual(VoiceUtterance.spokenDigits("604-555-1234"), "6 0 4 5 5 5 1 2 3 4")
        XCTAssertEqual(VoiceUtterance.spokenDigits("+1 (604) 555"), "1 6 0 4 5 5 5")
        XCTAssertEqual(VoiceUtterance.spokenDigits("no digits here"), "")
    }

    func test_custom_fallbackOnlyWhenPunjabiAndProvided() {
        XCTAssertNil(VoiceUtterance.custom("hi", language: "en").fallbackSegments)
        XCTAssertNil(VoiceUtterance.custom("ਸਤ ਸ੍ਰੀ ਅਕਾਲ", language: "pa").fallbackSegments)
        XCTAssertNotNil(VoiceUtterance.custom("ਸਤ ਸ੍ਰੀ ਅਕਾਲ", language: "pa", fallbackText: "Hi").fallbackSegments)
    }

    // MARK: - Localization coverage

    /// Every `voice.*` key must resolve in BOTH bundles — catches a key added in
    /// code but missing from en or pa (which would speak the raw key aloud).
    func test_allVoiceKeysResolveInBothLocales() throws {
        let keys = [
            "voice.readaloud.button.a11yLabel", "voice.readaloud.button.a11yHint",
            "voice.readaloud.button.speaking",
            "voice.dose.template", "voice.dose.instruction.suffix",
            "voice.dose.foodrule.with", "voice.dose.foodrule.without",
            "voice.alert.template", "voice.alert.title.misseddose",
            "voice.alert.title.emergency", "voice.alert.title.weeklysummary",
            "voice.medicalid.intro", "voice.medicalid.dob", "voice.medicalid.bloodtype",
            "voice.medicalid.allergies.intro", "voice.medicalid.conditions.intro",
            "voice.medicalid.contacts.intro", "voice.medicalid.contact.template",
            "voice.settings.section.title", "voice.settings.enabled.label",
            "voice.settings.rate.label", "voice.settings.rate.slow",
            "voice.settings.rate.normal", "voice.settings.rate.fast",
            "voice.settings.test.button", "voice.settings.test.sample",
        ]
        for lang in ["en", "pa"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"),
                                     "\(lang).lproj missing from the bundle")
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
                XCTAssertNotEqual(value, "__MISSING__", "\(key) missing in \(lang).lproj")
                XCTAssertNotEqual(value, key, "\(key) resolved to itself in \(lang).lproj")
            }
        }
    }
}
