import XCTest
@testable import Dosely

final class DrugInfoCacheTests: XCTestCase {
    var cacheURL: URL!

    override func setUp() async throws {
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drug-cache-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    func testGetReturnsNilWhenEmpty() async {
        let cache = DrugInfoCache(url: cacheURL)
        let result = await cache.get("anything")
        XCTAssertNil(result)
    }

    func testSetThenGet() async {
        let cache = DrugInfoCache(url: cacheURL)
        let drug = OpenFDADrug.fixture(brand: "Eliquis")
        await cache.set("Eliquis", drug)
        let got = await cache.get("Eliquis")
        XCTAssertEqual(got, drug)
    }

    func testKeysAreNormalised() async {
        let cache = DrugInfoCache(url: cacheURL)
        let drug = OpenFDADrug.fixture(brand: "Eliquis")
        await cache.set("Eliquis", drug)
        let got = await cache.get("  ELIQUIS  ")
        XCTAssertEqual(got?.brandName, "Eliquis")
    }

    func testLRUEvictionStaysAtCap() async {
        let cache = DrugInfoCache(url: cacheURL, maxEntries: 50)
        for i in 0..<60 {
            await cache.set("drug\(i)", OpenFDADrug.fixture(brand: "d\(i)"))
        }
        let count = await cache.count
        XCTAssertEqual(count, 50)

        // The oldest entries should have been evicted.
        let evicted = await cache.get("drug0")
        XCTAssertNil(evicted, "Oldest entry should have been LRU-evicted.")

        // A recent entry should still be there.
        let kept = await cache.get("drug55")
        XCTAssertNotNil(kept)
    }

    func testPersistsAcrossInstances() async {
        let drug = OpenFDADrug.fixture(brand: "Persistent")
        let cache = DrugInfoCache(url: cacheURL)
        await cache.set("Persistent", drug)

        let reloaded = DrugInfoCache(url: cacheURL)
        let got = await reloaded.get("Persistent")
        XCTAssertEqual(got?.brandName, "Persistent")
    }

    func testClearEmptiesEntries() async {
        let cache = DrugInfoCache(url: cacheURL)
        await cache.set("X", OpenFDADrug.fixture(brand: "X"))
        await cache.clear()
        let got = await cache.get("X")
        XCTAssertNil(got)
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }
}
