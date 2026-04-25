import XCTest
@testable import Dosely

final class DrugInfoRepositoryTests: XCTestCase {
    var repo: DrugInfoRepository!

    override func setUp() {
        super.setUp()
        // Bundle.main inside the test process is the host app (Dosely.app),
        // which carries drug_info.json in its Resources phase.
        repo = DrugInfoRepository(bundle: .main)
    }

    override func tearDown() {
        repo = nil
        super.tearDown()
    }

    func testLoadsAllSeedEntries() {
        XCTAssertGreaterThanOrEqual(repo.count, 8, "Expected at least the 8 seed medications.")
    }

    func testExactMatchByCommonName() {
        let info = repo.lookupInfo(for: "Metformin")
        XCTAssertEqual(info?.nameKey, "metformin")
    }

    func testCaseInsensitiveMatch() {
        let info = repo.lookupInfo(for: "METFORMIN")
        XCTAssertEqual(info?.nameKey, "metformin")
    }

    func testBrandNameMatch() {
        let info = repo.lookupInfo(for: "Glucophage")
        XCTAssertEqual(info?.nameKey, "metformin")
    }

    func testWhitespaceTrimmed() {
        let info = repo.lookupInfo(for: "   Lisinopril   ")
        XCTAssertEqual(info?.nameKey, "lisinopril")
    }

    func testFuzzyMatchWithDoseSuffix() {
        // User-typed name that contains the canonical name as a substring.
        let info = repo.lookupInfo(for: "Atorvastatin 20mg")
        XCTAssertEqual(info?.nameKey, "atorvastatin")
    }

    func testFuzzyMatchOfBrandWithSuffix() {
        let info = repo.lookupInfo(for: "Lipitor 40")
        XCTAssertEqual(info?.nameKey, "atorvastatin")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(repo.lookupInfo(for: "Imaginary Drug"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(repo.lookupInfo(for: ""))
        XCTAssertNil(repo.lookupInfo(for: "   "))
    }

    func testWarfarinFoodGuidePopulated() {
        let info = repo.lookupInfo(for: "warfarin")
        XCTAssertNotNil(info)
        XCTAssertFalse(info?.foodGuide.caution.isEmpty ?? true,
                       "Warfarin should have caution entries (vitamin K).")
        XCTAssertFalse(info?.foodGuide.avoid.isEmpty ?? true,
                       "Warfarin should have avoid entries (alcohol).")
    }

    func testAtorvastatinAvoidsGrapefruit() {
        let info = repo.lookupInfo(for: "atorvastatin")
        let avoid = (info?.foodGuide.avoid ?? []).joined(separator: " ").lowercased()
        XCTAssertTrue(avoid.contains("grapefruit"))
    }
}
