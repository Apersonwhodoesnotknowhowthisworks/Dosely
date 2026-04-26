import CoreData
import Foundation

enum CareCircleJoinError: Error, Equatable {
    case codeNotFound
    case alreadyMember
    case invalidName
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
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameTrim = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nameTrim.isEmpty else { return .failure(.invalidName) }

            let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
            request.predicate = NSPredicate(format: "joinCode == %@", trimmed)
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

    private static func find(id: UUID, in context: NSManagedObjectContext) -> CareCircle? {
        let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}
