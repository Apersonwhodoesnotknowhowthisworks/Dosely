import XCTest
@testable import Dosely

final class DrugInfoRepositoryTests: XCTestCase {
    var repo: DrugInfoRepository!

    override func setUp() {
        super.setUp()
        repo = DrugInfoRepository(bundle: .main)
    }

    override func tearDown() {
        repo = nil
        super.tearDown()
    }

    // MARK: - Tier 1 (curated) — sync API

    func testLoadsAllSeedEntries() {
        XCTAssertGreaterThanOrEqual(repo.count, 8, "Expected at least the 8 seed medications.")
    }

    func testExactMatchByCommonName() {
        let info = repo.lookupCurated(for: "Metformin")
        XCTAssertEqual(info?.nameKey, "metformin")
    }

    func testCaseInsensitiveMatch() {
        let info = repo.lookupCurated(for: "METFORMIN")
        XCTAssertEqual(info?.nameKey, "metformin")
    }

    func testBrandNameMatch() {
        let info = repo.lookupCurated(for: "Glucophage")
        XCTAssertEqual(info?.nameKey, "metformin")
    }

    func testWhitespaceTrimmed() {
        let info = repo.lookupCurated(for: "   Lisinopril   ")
        XCTAssertEqual(info?.nameKey, "lisinopril")
    }

    func testFuzzyMatchWithDoseSuffix() {
        let info = repo.lookupCurated(for: "Atorvastatin 20mg")
        XCTAssertEqual(info?.nameKey, "atorvastatin")
    }

    func testFuzzyMatchOfBrandWithSuffix() {
        let info = repo.lookupCurated(for: "Lipitor 40")
        XCTAssertEqual(info?.nameKey, "atorvastatin")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(repo.lookupCurated(for: "Imaginary Drug"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(repo.lookupCurated(for: ""))
        XCTAssertNil(repo.lookupCurated(for: "   "))
    }

    func testWarfarinFoodGuidePopulated() {
        let info = repo.lookupCurated(for: "warfarin")
        XCTAssertNotNil(info)
        XCTAssertFalse(info?.foodGuide.caution.isEmpty ?? true,
                       "Warfarin should have caution entries (vitamin K).")
        XCTAssertFalse(info?.foodGuide.avoid.isEmpty ?? true,
                       "Warfarin should have avoid entries (alcohol).")
    }

    func testAtorvastatinAvoidsGrapefruit() {
        let info = repo.lookupCurated(for: "atorvastatin")
        let avoid = (info?.foodGuide.avoid ?? []).joined(separator: " ").lowercased()
        XCTAssertTrue(avoid.contains("grapefruit"))
    }

    // MARK: - Three-tier (lookupAny)

    func testTier1HitReturnsCuratedAndSkipsRemote() async throws {
        let mockRemote = MockRemote()
        let cache = DrugInfoCache(url: tempCacheURL())
        let repo = DrugInfoRepository(bundle: .main, cache: cache, remote: mockRemote)

        let result = try await repo.lookupAny(for: "Metformin")
        guard case .curated(let info) = result else {
            return XCTFail("Expected .curated, got \(result)")
        }
        XCTAssertEqual(info.nameKey, "metformin")
        let calls = await mockRemote.callCount
        XCTAssertEqual(calls, 0, "Curated hit must not touch the network.")
    }

    func testTier2HitReturnsCachedWithoutNetworkCall() async throws {
        let mockRemote = MockRemote()
        let cache = DrugInfoCache(url: tempCacheURL())
        let stored = OpenFDADrug.fixture(brand: "Eliquis")
        await cache.set("Eliquis", stored)

        let repo = DrugInfoRepository(bundle: .main, cache: cache, remote: mockRemote)
        let result = try await repo.lookupAny(for: "Eliquis")
        guard case .dynamic(let drug, let label) = result else {
            return XCTFail("Expected .dynamic, got \(result)")
        }
        XCTAssertEqual(drug.brandName, "Eliquis")
        XCTAssertTrue(label.contains("cached"), "Tier 2 source label should reflect cached origin.")
        let calls = await mockRemote.callCount
        XCTAssertEqual(calls, 0, "Cache hit must not touch the network.")
    }

    func testTier3HitFiresOnFullMissAndWritesCache() async throws {
        let mockRemote = MockRemote()
        let drug = OpenFDADrug.fixture(brand: "Eliquis")
        await mockRemote.setResponse(.success(drug), for: "Eliquis")

        let cache = DrugInfoCache(url: tempCacheURL())
        let repo = DrugInfoRepository(bundle: .main, cache: cache, remote: mockRemote)

        let result = try await repo.lookupAny(for: "Eliquis")
        guard case .dynamic(let returned, _) = result else {
            return XCTFail("Expected .dynamic, got \(result)")
        }
        XCTAssertEqual(returned.brandName, "Eliquis")
        let calls = await mockRemote.callCount
        XCTAssertEqual(calls, 1, "Tier 3 should fire exactly once on a full miss.")

        let cached = await cache.get("Eliquis")
        XCTAssertEqual(cached, drug, "Tier 3 hits should be written through to the cache.")

        // A second lookup should now skip the network entirely.
        _ = try await repo.lookupAny(for: "Eliquis")
        let callsAfter = await mockRemote.callCount
        XCTAssertEqual(callsAfter, 1, "Subsequent lookup must hit Tier 2, not the network.")
    }

    func testTier3ZeroResultsReturnsMissing() async throws {
        let mockRemote = MockRemote()
        await mockRemote.setResponse(.success(nil), for: "Nothing")

        let cache = DrugInfoCache(url: tempCacheURL())
        let repo = DrugInfoRepository(bundle: .main, cache: cache, remote: mockRemote)

        let result = try await repo.lookupAny(for: "Nothing")
        guard case .missing = result else {
            return XCTFail("Expected .missing, got \(result)")
        }
    }

    func testTier3FailureWithNoCacheThrows() async {
        let mockRemote = MockRemote()
        await mockRemote.setResponse(.failure(URLError(.notConnectedToInternet)), for: "Eliquis")

        let cache = DrugInfoCache(url: tempCacheURL())
        let repo = DrugInfoRepository(bundle: .main, cache: cache, remote: mockRemote)

        do {
            _ = try await repo.lookupAny(for: "Eliquis")
            XCTFail("Expected throw on network failure with no cache.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
            XCTAssertFalse(repo.hasNetworkRecently,
                           "hasNetworkRecently should flip false after failed Tier 3.")
        }
    }

    // MARK: - Helpers

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("drug-cache-\(UUID().uuidString).json")
    }
}

// MARK: - Test doubles

private actor MockRemote: DrugRemoteService {
    private(set) var callCount: Int = 0
    private var responses: [String: Result<OpenFDADrug?, Error>] = [:]

    func setResponse(_ response: Result<OpenFDADrug?, Error>, for key: String) {
        responses[key.lowercased()] = response
    }

    func fetchInfo(for query: String) async throws -> OpenFDADrug? {
        callCount += 1
        if let r = responses[query.lowercased()] {
            return try r.get()
        }
        return nil
    }
}

extension OpenFDADrug {
    static func fixture(brand: String) -> OpenFDADrug {
        OpenFDADrug(
            brandName: brand,
            genericName: brand.lowercased(),
            indications: "Used for the conditions described in the official label.",
            dosageAndAdministration: "Take as directed by your prescriber.",
            warnings: "Includes typical warnings.",
            adverseReactions: "Common side effects per the label.",
            sourceURL: "https://dailymed.nlm.nih.gov/dailymed/search.cfm?query=\(brand)"
        )
    }
}
