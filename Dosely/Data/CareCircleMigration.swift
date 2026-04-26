import CoreData
import Foundation

/// One-shot migration that runs the first time a Firebase user signs in
/// after the care-circle refactor. Creates a default CareCircle, inserts
/// the user as the founding supervisor, and reassigns any pre-existing
/// medications and dose logs to that supervisor's `personID`.
///
/// Idempotent: gated by `UserDefaults["circle_migration_v1_complete"]`.
enum CareCircleMigration {
    static let flagKey = "circle_migration_v1_complete"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    /// Runs the migration if needed. Returns the supervisor `Person` for
    /// the given Firebase user (creating the circle on first run, or
    /// looking up the existing supervisor on subsequent calls).
    @discardableResult
    static func runIfNeeded(
        firebaseUID: String,
        displayName: String?,
        languagePreference: String,
        stack: CoreDataStack = .shared
    ) async -> Person? {
        let careCircleRepo = CareCircleRepository(stack: stack)
        let personRepo = PersonRepository(stack: stack)

        // Already migrated? Just resolve the existing supervisor.
        if isComplete {
            return await personRepo.fetchSupervisor(firebaseUID: firebaseUID)
        }

        // Check for an existing supervisor row even when the flag is off
        // (e.g. createCareCircle ran in this same launch via auto-bootstrap).
        if let existing = await personRepo.fetchSupervisor(firebaseUID: firebaseUID) {
            if let existingID = existing.id {
                await reassignOrphans(to: existingID, stack: stack)
            }
            UserDefaults.standard.set(true, forKey: flagKey)
            return existing
        }

        // Otherwise: create the default circle and supervisor.
        let circleName = localized("circle.default.name", fallback: "My Family")
        let resolvedName = displayName?.isEmpty == false
            ? displayName!
            : localized("circle.default.foundername", fallback: "Me")

        let circle = await careCircleRepo.createCareCircle(
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
        _ = circle
        return supervisor
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
