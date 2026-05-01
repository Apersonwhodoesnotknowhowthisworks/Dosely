import Foundation

/// One-shot sweep that deletes care circles the user founded but no
/// longer belongs to via `/userMemberships`.
///
/// Background. `/userMemberships/{firebaseUID}` is keyed by Firebase UID
/// and so points at exactly one circle at a time. During earlier
/// debugging cycles the founder flow accidentally re-ran, leaving
/// behind several careCircles whose primary supervisor's Person doc
/// still records this user as the founder while the user's
/// `/userMemberships` was overwritten to point at the most recent
/// circle. The orphans never get garbage-collected — every read of
/// `/joinCodes` shows them, and a stranger could in principle join one
/// by guessing the code. This migration tears them down once.
///
/// Discovery: the migration enumerates `/joinCodes` (readable by any
/// signed-in user, by design — that's how a new joiner finds a circle)
/// and tries to read each candidate `/careCircles/{id}`. The rules
/// helper `isOrphanFounder(circleID)` allows the read iff the
/// careCircle's `primarySupervisorPersonID` resolves to a Person doc
/// whose `firebaseUID == request.auth.uid`. Strangers' circles fail
/// that check and are silently skipped; the user's real circle is
/// excluded because we already know its id from `/userMemberships`.
///
/// Idempotent via `UserDefaults["orphan_circle_cleanup_v1"]`. Once
/// the flag flips we never revisit; subsequent orphans (should any
/// arise) require the user to manually report them — the migration is
/// a one-shot data-shape correction, not a perpetual sweeper.
enum OrphanCircleCleanupMigration {
    static let flagKey = "orphan_circle_cleanup_v1"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    /// Runs the cleanup if the flag isn't yet set. Returns the number
    /// of orphan circles deleted (0 if nothing to do, none discovered,
    /// or Firestore is unreachable). Errors during a single delete are
    /// logged via `[CLEANUP-DEBUG]` and the sweep continues — a
    /// permission-denied on one candidate just means it isn't ours.
    @discardableResult
    static func runIfNeeded(
        firebaseUID: String,
        firestore: FirestoreService = .shared
    ) async -> Int {
        if isComplete { return 0 }

        // Step 1: get the user's real circleID. If they have no
        // membership we can't tell orphans from "this is just my real
        // circle" — defer until they've finished bootstrap.
        let realMembership: FirestoreModels.FUserMembership?
        do {
            realMembership = try await firestore.fetchMembership(firebaseUID: firebaseUID)
        } catch {
            #if DEBUG
            print("[CLEANUP-DEBUG] fetchMembership failed: \(error)")
            #endif
            return 0
        }
        guard let realCircleID = realMembership?.careCircleID else {
            #if DEBUG
            print("[CLEANUP-DEBUG] no real /userMemberships — deferring cleanup")
            #endif
            return 0
        }

        // Step 2: list every /joinCodes doc and dedupe by careCircleID.
        // Most entries belong to other users; isOrphanFounder will
        // filter those out.
        let codes: [(code: String, careCircleID: String)]
        do {
            codes = try await firestore.listAllJoinCodes()
        } catch {
            #if DEBUG
            print("[CLEANUP-DEBUG] listAllJoinCodes failed: \(error)")
            #endif
            return 0
        }
        let candidateIDs = Set(codes.map { $0.careCircleID }).subtracting([realCircleID])

        // Step 3: for each candidate, prove ownership by reading the
        // careCircle's `primarySupervisorPersonID` and verifying that
        // the Person doc at that path has `firebaseUID == our uid`.
        // This mirrors the rules-side `isOrphanFounder` check exactly.
        // Doing it app-side too — rather than relying on the rules
        // short-circuit alone — keeps the migration deterministic even
        // when the SDK runs against the emulator with admin access (a
        // condition where every read succeeds regardless of authority).
        // Strangers' circles fail the firebaseUID match and are skipped.
        var deleted = 0
        for circleID in candidateIDs {
            let circle: FirestoreModels.FCareCircle?
            do {
                circle = try await firestore.loadCareCircle(circleID: circleID)
            } catch FirestoreServiceError.permissionDenied {
                continue
            } catch {
                #if DEBUG
                print("[CLEANUP-DEBUG] loadCareCircle(\(circleID)) failed: \(error)")
                #endif
                continue
            }
            guard let circle, let primaryID = circle.primarySupervisorPersonID else {
                continue
            }
            let primary: FirestoreModels.FPerson?
            do {
                primary = try await firestore.fetchPerson(
                    circleID: circleID, personID: primaryID
                )
            } catch FirestoreServiceError.permissionDenied {
                continue
            } catch {
                continue
            }
            guard let primary, primary.firebaseUID == firebaseUID else {
                continue
            }

            do {
                #if DEBUG
                print("[CLEANUP-DEBUG] deleting orphan circle=\(circleID)")
                #endif
                try await firestore.deleteOrphanedCareCircle(circleID: circleID)
                deleted += 1
            } catch {
                #if DEBUG
                print("[CLEANUP-DEBUG] delete orphan \(circleID) failed: \(error)")
                #endif
            }
        }

        UserDefaults.standard.set(true, forKey: flagKey)
        #if DEBUG
        print("[CLEANUP-DEBUG] cleanup complete, deleted=\(deleted)")
        #endif
        return deleted
    }

    /// Test helper.
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: flagKey)
    }
}
