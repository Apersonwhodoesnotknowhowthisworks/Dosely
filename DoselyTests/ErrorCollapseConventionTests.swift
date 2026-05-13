import XCTest
import FirebaseFirestore
@testable import Dosely

/// Project-wide guard for the error-collapse convention (see
/// CLAUDE.md "Error-collapse convention" and the build_log entries
/// for April 30 phantom-join-code and May 13 medical-id-save). The
/// rule: `FirestoreServiceError.permissionDenied` MUST surface as a
/// permission-denied error all the way to the UI, never as
/// `.offline`. Same for the reverse.
///
/// These tests stub the per-domain mapping directly — checking that
/// the per-repository error enums carry distinct `permissionDenied`
/// vs `.offline` cases and that conversion functions don't collapse
/// them. The emulator path through `FirestoreServiceError.map` itself
/// is covered by `FirestoreServiceTests`.
final class ErrorCollapseConventionTests: XCTestCase {

    // MARK: - FirestoreServiceError maps each Firestore code distinctly

    func testFirestoreServiceError_mapsPermissionDeniedDistinctly() {
        let nsError = NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.permissionDenied.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )
        XCTAssertEqual(FirestoreServiceError.map(nsError), .permissionDenied)
    }

    func testFirestoreServiceError_mapsUnavailableToOffline() {
        let nsError = NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.unavailable.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Unavailable"]
        )
        XCTAssertEqual(FirestoreServiceError.map(nsError), .offline)
    }

    func testFirestoreServiceError_mapsNotFoundDistinctly() {
        let nsError = NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.notFound.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Not found"]
        )
        XCTAssertEqual(FirestoreServiceError.map(nsError), .notFound)
    }

    /// Anything else lands as `.unknown(String)` — never silently
    /// collapsed to `.offline`. The detail string is what
    /// `FirestoreServiceError.map` writes to `Logger` so a future
    /// crash report has a name to grep for.
    func testFirestoreServiceError_unknownCarriesDiagnosticDetail() {
        let nsError = NSError(
            domain: FirestoreErrorDomain,
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "Some weird code"]
        )
        let mapped = FirestoreServiceError.map(nsError)
        guard case .unknown(let detail) = mapped else {
            XCTFail("expected .unknown, got \(mapped)")
            return
        }
        XCTAssertTrue(detail.contains("999"),
                      "unknown's detail string must carry the underlying code for diagnostics")
    }

    /// Network-domain errors from outside Firestore also flow to
    /// `.unknown` (with a diagnostic string), not `.offline`. The
    /// SDK's own `.unavailable` is the only path to `.offline`.
    func testFirestoreServiceError_nonFirestoreDomainLandsInUnknown() {
        let nsError = NSError(
            domain: NSURLErrorDomain, code: -1009,
            userInfo: [NSLocalizedDescriptionKey: "No internet"]
        )
        let mapped = FirestoreServiceError.map(nsError)
        guard case .unknown = mapped else {
            XCTFail("expected .unknown for non-Firestore domain, got \(mapped)")
            return
        }
    }

    // MARK: - Per-repository domain error enums

    /// Each of the three new repository error enums MUST carry both
    /// `permissionDenied` and `offline` as DISTINCT cases. If a
    /// future "let's simplify" PR collapses them into a single
    /// `.error(String)`, this test catches it at the type level.
    func testCareCircleEditError_hasDistinctPermissionAndOfflineCases() {
        XCTAssertNotEqual(CareCircleEditError.permissionDenied, .offline)
        XCTAssertNotEqual(CareCircleEditError.permissionDenied, .notFound)
        let unknown = CareCircleEditError.unknown("x")
        XCTAssertNotEqual(unknown, .offline)
    }

    func testCareCircleJoinError_hasDistinctPermissionAndOfflineCases() {
        XCTAssertNotEqual(CareCircleJoinError.permissionDenied, .offline)
        XCTAssertNotEqual(CareCircleJoinError.permissionDenied, .codeNotFound)
    }

    func testMedicalIDRepositoryError_hasDistinctPermissionAndOfflineCases() {
        XCTAssertNotEqual(MedicalIDRepositoryError.permissionDenied, .offline)
        XCTAssertNotEqual(MedicalIDRepositoryError.permissionDenied, .notFound)
        let unknown = MedicalIDRepositoryError.unknown("x")
        XCTAssertNotEqual(unknown, .offline)
    }
}
