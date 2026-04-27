import CoreData
import Foundation

enum CareCircleJoinError: Error, Equatable {
    case codeNotFound
    case alreadyMember
    case invalidName
}

enum CareCircleLeaveError: Error, Equatable {
    /// Refusing to leave a circle that would be left supervisorless.
    /// Managed clients depend on a supervisor; leaving them orphaned
    /// would soft-brick the circle.
    case lastSupervisor
    /// Acting Person isn't a supervisor in the target circle.
    case notMember
    /// Acting Person row not found in the store.
    case notFound
}

final class CareCircleRepository {
    private let stack: CoreDataStack

    init(stack: CoreDataStack = .shared) {
        self.stack = stack
    }

    private var context: NSManagedObjectContext { stack.viewContext }

    /// Creates a new CareCircle and inserts a supervisor `Person` for the
    /// founding Firebase user. Returns the newly-created circle. The
    /// supervisor row is created here so that the caller never sees a
    /// circle without at least one supervisor.
    @discardableResult
    func createCareCircle(
        name: String,
        foundingSupervisorFirebaseUID: String,
        founderName: String,
        founderLanguage: String = "en"
    ) async -> CareCircle {
        await context.perform { [context, self] in
            let circle = CareCircle(context: context)
            circle.id = UUID()
            circle.name = name.isEmpty ? "My Family" : name
            circle.createdAt = Date()
            circle.joinCode = self.uniqueJoinCode(in: context)

            let supervisor = Person(context: context)
            supervisor.id = UUID()
            supervisor.name = founderName
            supervisor.role = "supervisor"
            supervisor.languagePreference = founderLanguage
            supervisor.firebaseUID = foundingSupervisorFirebaseUID
            supervisor.failedPinAttempts = 0
            supervisor.careCircle = circle

            try? context.save()
            return circle
        }
    }

    func fetchCareCircle(for firebaseUID: String) async -> CareCircle? {
        await context.perform { [context] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(format: "firebaseUID == %@ AND role == %@",
                                            firebaseUID, "supervisor")
            request.fetchLimit = 1
            return (try? context.fetch(request))?.first?.careCircle
        }
    }

    func fetchCareCircle(id: UUID) async -> CareCircle? {
        await context.perform { [context] in
            Self.find(id: id, in: context)
        }
    }

    func joinCareCircle(
        code: String,
        asSupervisorWithFirebaseUID firebaseUID: String,
        name: String,
        language: String = "en"
    ) async -> Result<CareCircle, CareCircleJoinError> {
        await context.perform { [context] in
            let normalizedInput = Self.normalizeJoinCode(code)
            let nameTrim = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nameTrim.isEmpty else { return .failure(.invalidName) }

            // Case-insensitive compare against the stored value. Codes are
            // digit-only today (`uniqueJoinCode` uses %06d), but folding
            // both sides lets us tolerate any future generator that mixes
            // letters without re-introducing this bug class.
            let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
            request.predicate = NSPredicate(format: "joinCode ==[c] %@", normalizedInput)
            request.fetchLimit = 1
            guard let circle = (try? context.fetch(request))?.first else {
                return .failure(.codeNotFound)
            }

            // Already a supervisor in this circle? Don't create a duplicate.
            let people = (circle.people as? Set<Person>) ?? []
            if people.contains(where: { $0.firebaseUID == firebaseUID }) {
                return .failure(.alreadyMember)
            }

            let supervisor = Person(context: context)
            supervisor.id = UUID()
            supervisor.name = nameTrim
            supervisor.role = "supervisor"
            supervisor.languagePreference = language
            supervisor.firebaseUID = firebaseUID
            supervisor.failedPinAttempts = 0
            supervisor.careCircle = circle

            try? context.save()
            return .success(circle)
        }
    }

    /// Removes a supervisor from their circle. Used by Settings → Family →
    /// "Leave family and join another" and the LeaveAndJoinFlow.
    ///
    /// Refuses when the leaving supervisor is the only one in the circle —
    /// managed clients have no other authority and would be orphaned.
    /// Returns `.lastSupervisor` whether or not the circle has clients;
    /// even an empty circle keeps its founding supervisor by design.
    ///
    /// On success the supervisor's `Person` row is deleted. Their Firebase
    /// account stays alive, so on the next sign-in `resolveCurrentPerson`
    /// returns nil and AuthGate routes them back to `CircleSetupView`.
    /// They can then create a new circle or join another with a code.
    ///
    /// **Known limitation:** rejoining the same circle with the same
    /// Firebase account creates a fresh `Person` row — historical dose
    /// logs that referenced the old `Person.id` are not re-attributed.
    /// Documented in CLAUDE.md.
    func leaveCircle(supervisorPersonID: UUID) async -> Result<Void, CareCircleLeaveError> {
        await context.perform { [context] in
            guard let actor = Self.findPerson(id: supervisorPersonID, in: context) else {
                return .failure(.notFound)
            }
            guard actor.role == "supervisor", let circle = actor.careCircle else {
                return .failure(.notMember)
            }

            let people = (circle.people as? Set<Person>) ?? []
            let otherSupervisors = people.filter {
                $0.role == "supervisor" && $0.id != actor.id
            }
            if otherSupervisors.isEmpty {
                return .failure(.lastSupervisor)
            }

            // We delete the supervisor's Person row only. Other people in
            // the circle keep their data; medications and dose logs are
            // keyed by their own personIDs, not the leaving supervisor's.
            context.delete(actor)
            try? context.save()
            return .success(())
        }
    }

    /// Renames an existing circle. Supervisor permission is enforced at
    /// the call site (only the supervisor screen exposes this control).
    @discardableResult
    func renameCircle(careCircleID: UUID, newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await context.perform { [context] in
            guard let circle = Self.find(id: careCircleID, in: context) else { return false }
            circle.name = trimmed
            try? context.save()
            return true
        }
    }

    /// Regenerates the join code for an existing circle. Supervisor
    /// permission is enforced at the call site.
    @discardableResult
    func regenerateJoinCode(careCircleID: UUID) async -> String? {
        await context.perform { [context, self] in
            guard let circle = Self.find(id: careCircleID, in: context) else { return nil }
            circle.joinCode = self.uniqueJoinCode(in: context)
            try? context.save()
            return circle.joinCode
        }
    }

    // MARK: - Helpers

    /// Generates a 6-digit code that doesn't collide with any existing
    /// CareCircle in the store. Retries up to 100 times.
    private func uniqueJoinCode(in context: NSManagedObjectContext) -> String {
        for _ in 0..<100 {
            let candidate = Self.randomCode()
            let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
            request.predicate = NSPredicate(format: "joinCode == %@", candidate)
            request.fetchLimit = 1
            let exists = ((try? context.fetch(request))?.first) != nil
            if !exists { return candidate }
        }
        // Defensive: in the (statistically impossible) case of 100 collisions,
        // tack on an entropy suffix.
        return Self.randomCode() + String(format: "%02d", Int.random(in: 0..<100))
    }

    static func randomCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let n = UInt32.random(in: 0..<1_000_000, using: &rng)
        return String(format: "%06d", n)
    }

    /// Trim, drop interior whitespace (a real code is contiguous), and
    /// uppercase-fold so the comparison is symmetric. The Core Data
    /// predicate uses `==[c]` for the case-insensitive match, but
    /// trimming has to happen here — a predicate can't strip whitespace.
    static func normalizeJoinCode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
           .components(separatedBy: .whitespacesAndNewlines)
           .joined()
           .uppercased()
    }

    private static func find(id: UUID, in context: NSManagedObjectContext) -> CareCircle? {
        let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private static func findPerson(id: UUID, in context: NSManagedObjectContext) -> Person? {
        let request = NSFetchRequest<Person>(entityName: "Person")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}
