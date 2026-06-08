import CoreData
import Foundation

/// One-shot legacy migration that runs the first time a Firebase user
/// signs in after the care-circle refactor. Reassigns any pre-existing
/// Medications / DoseLogs (which lacked `personID` / `loggedByPersonID`
/// before Prompt 13) to a freshly-bootstrapped supervisor.
///
/// **Brand-new accounts no longer auto-bootstrap a "My Family" circle.**
/// They return `nil` so AuthGate routes them to `CircleSetupView`, where
/// the user picks between creating their own circle and joining an
/// existing one with a 6-digit code.
///
/// Idempotent: gated by `UserDefaults["circle_migration_v1_complete"]`.
enum CareCircleMigration {
    static let flagKey = "circle_migration_v1_complete"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    /// Resolves the local supervisor row for `firebaseUID`. Returns:
    /// - the existing supervisor if one already lives in the store
    /// - a freshly-bootstrapped "My Family" supervisor if there is legacy
    ///   orphan data (pre-Prompt-13 Medications / DoseLogs without a
    ///   personID) that needs an owner
    /// - `nil` for a brand-new account on a clean install — the caller
    ///   should route to `CircleSetupView`.
    @discardableResult
    static func runIfNeeded(
        firebaseUID: String,
        displayName: String?,
        languagePreference: String,
        stack: CoreDataStack = .shared,
        firestore: FirestoreService = .shared
    ) async -> Person? {
        let _sp = Perf.signposter.beginInterval("migration.careCircle")
        defer { Perf.signposter.endInterval("migration.careCircle", _sp) }
        let careCircleRepo = CareCircleRepository(stack: stack, firestore: firestore)
        let personRepo = PersonRepository(stack: stack, firestore: firestore)

        // Already migrated? Just resolve the existing supervisor (may be
        // nil for accounts that haven't completed CircleSetupView yet).
        if isComplete {
            return await personRepo.fetchSupervisor(firebaseUID: firebaseUID)
        }

        // Existing supervisor for this UID? Reassign any orphan rows
        // to them and mark migration complete.
        if let existing = await personRepo.fetchSupervisor(firebaseUID: firebaseUID) {
            if let existingID = existing.id {
                await reassignOrphans(to: existingID, stack: stack)
            }
            UserDefaults.standard.set(true, forKey: flagKey)
            return existing
        }

        // No supervisor yet. Auto-bootstrap *only* when there is legacy
        // data without a person to attach to — that's the original
        // migration's purpose. A clean install on a new device has no
        // orphans, and we want such users to see CircleSetupView.
        guard await hasLegacyOrphans(stack: stack) else {
            return nil
        }

        let circleName = localized("circle.default.name", fallback: "My Family")
        let resolvedName = displayName?.isEmpty == false
            ? displayName!
            : localized("circle.default.foundername", fallback: "Me")

        _ = await careCircleRepo.createCareCircle(
            name: circleName,
            foundingSupervisorFirebaseUID: firebaseUID,
            founderName: resolvedName,
            founderLanguage: languagePreference
        )

        let supervisor = await personRepo.fetchSupervisor(firebaseUID: firebaseUID)
        if let supervisorID = supervisor?.id {
            await reassignOrphans(to: supervisorID, stack: stack)
        }

        UserDefaults.standard.set(true, forKey: flagKey)
        return supervisor
    }

    /// Returns true if any pre-Prompt-13 Medication / DoseLog rows exist
    /// without a personID (i.e. the legacy migration still has work to do).
    private static func hasLegacyOrphans(stack: CoreDataStack) async -> Bool {
        let context = stack.viewContext
        return await context.perform {
            let medRequest = NSFetchRequest<Medication>(entityName: "Medication")
            medRequest.predicate = NSPredicate(format: "personID == nil")
            medRequest.fetchLimit = 1
            if let meds = try? context.fetch(medRequest), !meds.isEmpty { return true }

            let logRequest = NSFetchRequest<DoseLog>(entityName: "DoseLog")
            logRequest.predicate = NSPredicate(format: "loggedByPersonID == nil")
            logRequest.fetchLimit = 1
            if let logs = try? context.fetch(logRequest), !logs.isEmpty { return true }

            return false
        }
    }

    /// Sweeps existing Medications / DoseLogs that lack a personID and
    /// stamps the migrating supervisor's id onto them. Safe to call
    /// multiple times — already-stamped rows are skipped via predicate.
    static func reassignOrphans(to supervisorID: UUID, stack: CoreDataStack = .shared) async {
        let context = stack.viewContext
        await context.perform {
            let medRequest = NSFetchRequest<Medication>(entityName: "Medication")
            medRequest.predicate = NSPredicate(format: "personID == nil")
            for med in (try? context.fetch(medRequest)) ?? [] {
                med.personID = supervisorID
            }

            let logRequest = NSFetchRequest<DoseLog>(entityName: "DoseLog")
            logRequest.predicate = NSPredicate(format: "loggedByPersonID == nil")
            for log in (try? context.fetch(logRequest)) ?? [] {
                log.loggedByPersonID = supervisorID
            }

            try? context.save()
        }
    }

    /// Test helper: clears the migration flag so tests can exercise the
    /// first-run path without uninstalling the app.
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: flagKey)
    }

    /// `NSLocalizedString` returns the key unchanged when no entry exists in
    /// any loaded bundle (which happens in some test contexts). Detect that
    /// and fall back to the supplied default.
    private static func localized(_ key: String, fallback: String) -> String {
        let value = NSLocalizedString(key, comment: "")
        return (value.isEmpty || value == key) ? fallback : value
    }
}
