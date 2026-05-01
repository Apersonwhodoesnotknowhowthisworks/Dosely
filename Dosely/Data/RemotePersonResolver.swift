import CoreData
import Foundation

/// Resolves the local Core Data `Person` for a Firebase UID by hitting
/// Firestore's `/userMemberships/{firebaseUID}` index FIRST, then
/// mirroring the referenced CareCircle and Person docs into Core Data.
///
/// Used by `AuthService.resolveCurrentPerson` on every sign-in. Without
/// this, a user who has signed in before but whose Core Data cache is
/// empty (fresh install, post sign-out, first sign-in on a second
/// device) would be misclassified as a brand-new account and routed to
/// `CircleSetupView`. The membership index doc is the authoritative
/// answer to "does this Firebase user already belong to a circle?" —
/// Core Data is only a cache, and a Core Data miss must not be treated
/// as proof that the user has no circle.
enum RemotePersonResolver {
    enum Outcome {
        /// `/userMemberships/{firebaseUID}` exists and the referenced
        /// CareCircle + Person were hydrated into Core Data. The Person
        /// row is returned for direct use by the caller.
        case found(Person)
        /// Firestore answered conclusively that no membership exists
        /// for this Firebase UID — i.e. brand-new account. The caller
        /// should route to `CircleSetupView` (or run the legacy
        /// `CareCircleMigration` for orphan reassignment first).
        case notFound
        /// Couldn't reach Firestore (offline, not configured, SDK
        /// returned `unavailable` or `permissionDenied`). The caller
        /// must fall back to the local Core Data path so existing
        /// offline behaviour and tests with a no-op service still work.
        case unavailable
    }

    /// Looks up `/userMemberships/{firebaseUID}` and, on hit, mirrors
    /// the referenced CareCircle and Person docs into Core Data.
    static func resolve(
        firebaseUID: String,
        stack: CoreDataStack = .shared,
        firestore: FirestoreService = .shared
    ) async -> Outcome {
        // Bail out early when no Firestore client exists at all (test
        // path with no Firebase app). The membership-fetch path would
        // throw `.offline` here too — we short-circuit just to make
        // intent obvious.
        guard firestore.isConfigured else { return .unavailable }

        let membership: FirestoreModels.FUserMembership?
        do {
            membership = try await firestore.fetchMembership(firebaseUID: firebaseUID)
        } catch {
            // `.offline`, `.permissionDenied`, or anything else: treat
            // as "couldn't ask" so the caller falls back to local
            // resolution rather than misclassifying as new-account.
            return .unavailable
        }

        guard let membership else { return .notFound }

        let circle: FirestoreModels.FCareCircle?
        let person: FirestoreModels.FPerson?
        do {
            circle = try await firestore.loadCareCircle(circleID: membership.careCircleID)
            person = try await firestore.fetchPerson(
                circleID: membership.careCircleID,
                personID: membership.personID
            )
        } catch {
            return .unavailable
        }

        guard let circle, let person else {
            // Membership index references a CareCircle or Person that
            // no longer exists. Treat as `.notFound` rather than
            // hydrating half a state — the caller can route to
            // CircleSetupView and the user can re-create or re-join.
            return .notFound
        }

        guard let mirrored = await mirror(circle: circle, person: person, stack: stack) else {
            return .unavailable
        }
        return .found(mirrored)
    }

    /// Upserts the CareCircle + Person into Core Data and returns the
    /// resulting Person row. Performed on the view context so the
    /// returned object is safe to hand to a `@MainActor` caller.
    private static func mirror(
        circle: FirestoreModels.FCareCircle,
        person: FirestoreModels.FPerson,
        stack: CoreDataStack
    ) async -> Person? {
        let context = stack.viewContext
        return await context.perform {
            circle.upsert(in: context)
            let mirrored = person.upsert(in: context)
            try? context.save()
            return mirrored
        }
    }
}
