import CoreData
import FirebaseFirestore
import Foundation

/// One-shot upload that runs the first time a Firestore-aware build
/// signs in on a device that already has local-only data (i.e. the
/// founding aunt's pre-Firestore install).
///
/// Detection is `local CareCircle exists, but /careCircles/{id} does
/// not`. On a clean install where the user's first action is signing
/// in to a *new* account, there's nothing to upload and the migration
/// becomes a no-op. On a clean install where the user joins an
/// existing circle, `joinCareCircle` sets up the local row from the
/// Firestore copy — also nothing to upload.
///
/// Idempotent via `UserDefaults["firestore_upload_v1_complete"]`. Once
/// the flag flips we never revisit; even if a write failed, the
/// SyncCoordinator listener catches up the gap as soon as anyone in
/// the circle next writes a document.
enum FirestoreUploadMigration {
    static let flagKey = "firestore_upload_v1_complete"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    /// Runs the upload if needed. `firebaseUID` identifies the
    /// supervisor whose local circle to upload. Returns true if any
    /// upload happened, false otherwise.
    @discardableResult
    static func runIfNeeded(
        firebaseUID: String,
        stack: CoreDataStack = .shared,
        firestore: FirestoreService = .shared
    ) async -> Bool {
        if isComplete { return false }

        let circleSnapshot = await snapshotLocalCircle(firebaseUID: firebaseUID, stack: stack)
        guard let snapshot = circleSnapshot else {
            // No local circle to migrate. The flag flips so we don't
            // re-run on every launch; if a circle materialises later
            // it'll have been written through the repositories, which
            // already hit Firestore directly.
            UserDefaults.standard.set(true, forKey: flagKey)
            return false
        }

        // If the circle already exists on Firestore, no upload needed.
        do {
            if try await firestore.loadCareCircle(circleID: snapshot.circle.id) != nil {
                UserDefaults.standard.set(true, forKey: flagKey)
                return false
            }
        } catch FirestoreServiceError.offline {
            // Defer the migration until we have network. Don't flip the
            // flag — try again on next launch.
            return false
        } catch {
            return false
        }

        do {
            try await upload(snapshot: snapshot, firestore: firestore)
            UserDefaults.standard.set(true, forKey: flagKey)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Snapshot

    struct CircleSnapshot {
        let circle: FirestoreModels.FCareCircle
        let people: [FirestoreModels.FPerson]
        let medications: [FirestoreModels.FMedication]
        let schedules: [FirestoreModels.FDoseSchedule]
        let logs: [FirestoreModels.FDoseLog]
        /// (firebaseUID, personID) tuples for every supervisor in the
        /// snapshot. Drives /userMemberships writes and the final
        /// supervisorCount.
        let supervisorBindings: [(firebaseUID: String, personID: String)]
        /// firebaseUID of the founder doing the upload — they bootstrap
        /// first; the rest follow under their supervisor authority.
        let founderUID: String
        let founderPersonID: String
    }

    private static func snapshotLocalCircle(
        firebaseUID: String,
        stack: CoreDataStack
    ) async -> CircleSnapshot? {
        let context = stack.viewContext
        return await context.perform {
            let supervisorRequest = NSFetchRequest<Person>(entityName: "Person")
            supervisorRequest.predicate = NSPredicate(
                format: "firebaseUID == %@ AND role == %@",
                firebaseUID, "supervisor"
            )
            supervisorRequest.fetchLimit = 1
            guard let supervisor = (try? context.fetch(supervisorRequest))?.first,
                  let circle = supervisor.careCircle,
                  let circleID = circle.id,
                  let founderPersonUUID = supervisor.id else { return nil }

            let peopleRequest = NSFetchRequest<Person>(entityName: "Person")
            peopleRequest.predicate = NSPredicate(format: "careCircle.id == %@", circleID as CVarArg)
            let people = (try? context.fetch(peopleRequest)) ?? []
            let fpeople = people.map { FirestoreModels.FPerson(from: $0, careCircleID: circleID) }
            let personIDs = Set(people.compactMap { $0.id })

            let supervisors = people.filter { $0.role == "supervisor" }
            let bindings: [(firebaseUID: String, personID: String)] = supervisors.compactMap { p in
                guard let uid = p.firebaseUID, let pid = p.id else { return nil }
                return (firebaseUID: uid, personID: pid.uuidString)
            }

            let fcircle = FirestoreModels.FCareCircle(
                from: circle,
                supervisorCount: 0
            )

            let medRequest = NSFetchRequest<Medication>(entityName: "Medication")
            let allMeds = (try? context.fetch(medRequest)) ?? []
            let circleMeds = allMeds.filter { med in
                guard let pid = med.personID else { return false }
                return personIDs.contains(pid)
            }
            let fmeds = circleMeds.map { FirestoreModels.FMedication(from: $0) }

            var fschedules: [FirestoreModels.FDoseSchedule] = []
            for med in circleMeds {
                if let set = med.schedules as? Set<DoseSchedule> {
                    fschedules.append(contentsOf: set.map { FirestoreModels.FDoseSchedule(from: $0) })
                }
            }

            let logRequest = NSFetchRequest<DoseLog>(entityName: "DoseLog")
            let allLogs = (try? context.fetch(logRequest)) ?? []
            let circleLogs = allLogs.filter { log in
                guard let pid = log.medication?.personID else { return false }
                return personIDs.contains(pid)
            }
            let flogs = circleLogs.map { FirestoreModels.FDoseLog(from: $0) }

            return CircleSnapshot(
                circle: fcircle,
                people: fpeople,
                medications: fmeds,
                schedules: fschedules,
                logs: flogs,
                supervisorBindings: bindings,
                founderUID: firebaseUID,
                founderPersonID: founderPersonUUID.uuidString
            )
        }
    }

    // MARK: - Upload

    private static func upload(
        snapshot: CircleSnapshot,
        firestore: FirestoreService
    ) async throws {
        // 1. Create the careCircle with supervisorCount=0. The
        //    founder-bootstrap path on the /userMemberships create rule
        //    requires this initial state.
        try await firestore.createCareCircle(snapshot.circle)

        // 2. Founder bootstrap: write /userMemberships, then the founder's
        //    Person doc. supervisorCount stays at 0 throughout — the
        //    rules-layer founder check requires that.
        let founderMembership = FirestoreModels.FUserMembership(
            careCircleID: snapshot.circle.id,
            personID: snapshot.founderPersonID,
            role: "supervisor",
            joinedAt: Date(),
            joinCode: nil
        )
        try await firestore.upsertMembership(
            firebaseUID: snapshot.founderUID,
            membership: founderMembership
        )
        if let founderPerson = snapshot.people.first(where: { $0.id == snapshot.founderPersonID }) {
            try await firestore.upsertPerson(founderPerson)
        }

        // 3. Other people. Founder is now an authenticated supervisor at
        //    the rules layer (membership + Person doc both written), so
        //    `isSupervisor` covers writes for the rest of the snapshot.
        //    /userMemberships entries for additional supervisors go via
        //    the supervisor-onboards-member branch.
        for binding in snapshot.supervisorBindings where binding.firebaseUID != snapshot.founderUID {
            let membership = FirestoreModels.FUserMembership(
                careCircleID: snapshot.circle.id,
                personID: binding.personID,
                role: "supervisor",
                joinedAt: Date(),
                joinCode: nil
            )
            try await firestore.upsertMembership(
                firebaseUID: binding.firebaseUID,
                membership: membership
            )
        }
        for person in snapshot.people where person.id != snapshot.founderPersonID {
            try await firestore.upsertPerson(person)
        }

        // 4. Upload subcollections.
        for med in snapshot.medications {
            try await firestore.upsertMedication(circleID: snapshot.circle.id, med: med)
        }
        for schedule in snapshot.schedules {
            try await firestore.upsertSchedule(circleID: snapshot.circle.id, schedule: schedule)
        }
        for log in snapshot.logs {
            try await firestore.upsertDoseLog(circleID: snapshot.circle.id, log: log)
        }

        // 5. Bring supervisorCount up to the actual number of supervisors.
        let actualSupervisorCount = snapshot.supervisorBindings.count
        if actualSupervisorCount > 0 {
            try await firestore.adjustSupervisorCount(
                circleID: snapshot.circle.id,
                delta: actualSupervisorCount
            )
        }
    }

    /// Test helper.
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: flagKey)
    }
}
