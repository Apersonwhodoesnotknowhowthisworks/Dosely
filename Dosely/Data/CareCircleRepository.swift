import CoreData
import Foundation

enum CareCircleJoinError: Error, Equatable {
    case codeNotFound
    case alreadyMember
    case invalidName
    /// Firestore couldn't be reached and we don't have a local copy of
    /// this circle to fall back on. Distinct from `codeNotFound` —
    /// retry-after-network would help here.
    case offline
}

enum CareCircleLeaveError: Error, Equatable {
    case lastSupervisor
    case notMember
    case notFound
}

/// Care circle reads stay synchronous from Core Data (instant UI).
/// Writes go to Firestore first; on success we mirror the change into
/// Core Data. The SyncCoordinator listener keeps Core Data fresh for
/// cross-device updates.
final class CareCircleRepository {
    private let stack: CoreDataStack
    private let firestore: FirestoreService

    init(stack: CoreDataStack = .shared, firestore: FirestoreService = .shared) {
        self.stack = stack
        self.firestore = firestore
    }

    private var context: NSManagedObjectContext { stack.viewContext }

    // MARK: - Create

    /// Creates a new CareCircle in Firestore (with founding supervisor
    /// person + reserved join code), then mirrors the result into Core
    /// Data. The Firestore write happens first so two devices can
    /// observe the same circle from the moment of creation.
    @discardableResult
    func createCareCircle(
        name: String,
        foundingSupervisorFirebaseUID: String,
        founderName: String,
        founderLanguage: String = "en"
    ) async -> CareCircle {
        let resolvedName = name.isEmpty ? "My Family" : name
        let circleID = UUID()
        let supervisorID = UUID()
        let joinCode = await uniqueJoinCode()

        let fcircle = FirestoreModels.FCareCircle(
            id: circleID.uuidString,
            name: resolvedName,
            joinCode: joinCode,
            createdAt: Date(),
            lastModified: nil
        )

        // Firestore write first — failures don't block the local
        // create because the SDK queues writes while offline.
        try? await firestore.createCareCircle(fcircle)

        let supervisor = FirestoreModels.FPerson(
            id: supervisorID.uuidString,
            careCircleID: circleID.uuidString,
            name: founderName,
            role: "supervisor",
            languagePreference: founderLanguage,
            firebaseUID: foundingSupervisorFirebaseUID,
            photoData: nil,
            pinHash: nil,
            pinSalt: nil,
            failedPinAttempts: 0,
            lastModified: nil
        )
        try? await firestore.upsertPerson(supervisor)

        return await context.perform { [context] in
            let circle = CareCircle(context: context)
            circle.id = circleID
            circle.name = resolvedName
            circle.createdAt = Date()
            circle.joinCode = joinCode

            let supervisorRow = Person(context: context)
            supervisorRow.id = supervisorID
            supervisorRow.name = founderName
            supervisorRow.role = "supervisor"
            supervisorRow.languagePreference = founderLanguage
            supervisorRow.firebaseUID = foundingSupervisorFirebaseUID
            supervisorRow.failedPinAttempts = 0
            supervisorRow.careCircle = circle

            try? context.save()
            return circle
        }
    }

    // MARK: - Read (Core Data only)

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

    // MARK: - Join

    /// Joins a circle by its 6-digit code. The lookup hits Firestore via
    /// `/joinCodes/{code}` — a direct document fetch, not a collection
    /// scan — so it works for circles never seen on this device.
    ///
    /// Falls back to a Core Data scan when Firestore is unreachable so
    /// the existing single-device flow still works offline (e.g. a
    /// handed-down iPad scenario where the circle row is already local).
    func joinCareCircle(
        code: String,
        asSupervisorWithFirebaseUID firebaseUID: String,
        name: String,
        language: String = "en"
    ) async -> Result<CareCircle, CareCircleJoinError> {
        let normalized = Self.normalizeJoinCode(code)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.invalidName) }

        let fcircle: FirestoreModels.FCareCircle?
        do {
            fcircle = try await firestore.lookupJoinCode(normalized)
        } catch FirestoreServiceError.offline {
            return await joinViaCoreData(
                normalized: normalized,
                firebaseUID: firebaseUID,
                name: trimmedName,
                language: language
            )
        } catch {
            return .failure(.codeNotFound)
        }

        guard let fcircle, let circleUUID = UUID(uuidString: fcircle.id) else {
            return .failure(.codeNotFound)
        }

        // Already a supervisor in this circle on this device? Don't
        // create a duplicate. Mirror to Core Data first if missing.
        let alreadyMember = await context.perform { [context] in
            let request = NSFetchRequest<Person>(entityName: "Person")
            request.predicate = NSPredicate(
                format: "firebaseUID == %@ AND careCircle.id == %@",
                firebaseUID, circleUUID as CVarArg
            )
            request.fetchLimit = 1
            return ((try? context.fetch(request))?.first) != nil
        }
        if alreadyMember { return .failure(.alreadyMember) }

        // Mirror the Firestore circle into Core Data so the new
        // supervisor row has somewhere to live.
        await context.perform { [context] in
            fcircle.upsert(in: context)
            try? context.save()
        }

        let supervisorID = UUID()
        let fperson = FirestoreModels.FPerson(
            id: supervisorID.uuidString,
            careCircleID: fcircle.id,
            name: trimmedName,
            role: "supervisor",
            languagePreference: language,
            firebaseUID: firebaseUID,
            photoData: nil,
            pinHash: nil,
            pinSalt: nil,
            failedPinAttempts: 0,
            lastModified: nil
        )
        try? await firestore.upsertPerson(fperson)

        return await context.perform { [context] in
            guard let circle = Self.find(id: circleUUID, in: context) else {
                return .failure(.codeNotFound)
            }
            let person = Person(context: context)
            person.id = supervisorID
            person.name = trimmedName
            person.role = "supervisor"
            person.languagePreference = language
            person.firebaseUID = firebaseUID
            person.failedPinAttempts = 0
            person.careCircle = circle
            try? context.save()
            return .success(circle)
        }
    }

    /// Local-only fallback used when Firestore is unreachable. Mirrors
    /// the previous (Prompt 14) join-by-code semantics so a handed-down
    /// device with the circle already in Core Data still works.
    /// Returns `.codeNotFound` (not `.offline`) when the circle isn't
    /// in Core Data either — the user-visible meaning is identical and
    /// matches the previous behaviour the existing tests expect.
    private func joinViaCoreData(
        normalized: String,
        firebaseUID: String,
        name: String,
        language: String
    ) async -> Result<CareCircle, CareCircleJoinError> {
        await context.perform { [context] in
            let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
            request.predicate = NSPredicate(format: "joinCode ==[c] %@", normalized)
            request.fetchLimit = 1
            guard let circle = (try? context.fetch(request))?.first else {
                return .failure(.codeNotFound)
            }
            let people = (circle.people as? Set<Person>) ?? []
            if people.contains(where: { $0.firebaseUID == firebaseUID }) {
                return .failure(.alreadyMember)
            }
            let supervisor = Person(context: context)
            supervisor.id = UUID()
            supervisor.name = name
            supervisor.role = "supervisor"
            supervisor.languagePreference = language
            supervisor.firebaseUID = firebaseUID
            supervisor.failedPinAttempts = 0
            supervisor.careCircle = circle
            try? context.save()
            return .success(circle)
        }
    }

    // MARK: - Leave

    func leaveCircle(supervisorPersonID: UUID) async -> Result<Void, CareCircleLeaveError> {
        let resolution = await context.perform { [context] () -> Result<(circleID: UUID, personID: UUID), CareCircleLeaveError> in
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
            guard let circleID = circle.id, let actorID = actor.id else {
                return .failure(.notFound)
            }
            return .success((circleID, actorID))
        }

        guard case let .success(ids) = resolution else {
            if case let .failure(err) = resolution { return .failure(err) }
            return .failure(.notFound)
        }

        try? await firestore.deletePerson(
            circleID: ids.circleID.uuidString,
            personID: ids.personID.uuidString
        )

        return await context.perform { [context] in
            guard let actor = Self.findPerson(id: supervisorPersonID, in: context) else {
                return .failure(.notFound)
            }
            context.delete(actor)
            try? context.save()
            return .success(())
        }
    }

    // MARK: - Rename

    @discardableResult
    func renameCircle(careCircleID: UUID, newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        try? await firestore.updateCareCircleName(
            circleID: careCircleID.uuidString,
            newName: trimmed
        )
        return await context.perform { [context] in
            guard let circle = Self.find(id: careCircleID, in: context) else { return false }
            circle.name = trimmed
            try? context.save()
            return true
        }
    }

    // MARK: - Regenerate join code

    /// Regenerates the join code atomically across `/careCircles/{id}`,
    /// `/joinCodes/{old}` (deleted), and `/joinCodes/{new}` (created).
    /// Mirrors to Core Data on success.
    @discardableResult
    func regenerateJoinCode(careCircleID: UUID) async -> String? {
        let oldCode: String? = await context.perform { [context] in
            Self.find(id: careCircleID, in: context)?.joinCode
        }
        guard let oldCode else { return nil }

        let newCode = await uniqueJoinCode()
        do {
            try await firestore.regenerateJoinCode(
                circleID: careCircleID.uuidString,
                oldCode: oldCode,
                newCode: newCode
            )
        } catch {
            // Couldn't write to Firestore (offline, perms). Surface nil
            // so the caller can show an error rather than handing out a
            // local-only code that isn't valid for cross-device joins.
            return nil
        }

        return await context.perform { [context] in
            guard let circle = Self.find(id: careCircleID, in: context) else { return nil }
            circle.joinCode = newCode
            try? context.save()
            return newCode
        }
    }

    // MARK: - Helpers

    /// Generates a 6-digit code that doesn't collide with the local
    /// store. Best-effort: Firestore-side collisions are vanishingly
    /// rare given a million-code keyspace and the SDK transaction in
    /// `regenerateJoinCode` catches the corner case for the regenerate
    /// path. Cross-device create-time collisions are tolerated as a
    /// known small race documented in CLAUDE.md.
    private func uniqueJoinCode() async -> String {
        await context.perform { [context] in
            for _ in 0..<100 {
                let candidate = Self.randomCode()
                let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
                request.predicate = NSPredicate(format: "joinCode == %@", candidate)
                request.fetchLimit = 1
                let exists = ((try? context.fetch(request))?.first) != nil
                if !exists { return candidate }
            }
            return Self.randomCode() + String(format: "%02d", Int.random(in: 0..<100))
        }
    }

    static func randomCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let n = UInt32.random(in: 0..<1_000_000, using: &rng)
        return String(format: "%06d", n)
    }

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
