import CoreData
import Foundation

/// Keeps the Care circle card's `name` and `joinCode` reactive to Core Data
/// mutations of the CareCircle row.
///
/// SwiftUI tracks the `@Published` wrapper, NOT nested `NSManagedObject`
/// property writes. Yesterday's `.task(id: circleSyncToken)` re-sync only fired
/// when `AuthService.currentPerson` was *reassigned* (which publishes through
/// the @EnvironmentObject); an in-place mutation of the existing CareCircle row
/// — `createCareCircle` filling the field, or the SyncCoordinator listener
/// mirroring it in later — does not reassign `currentPerson`, so the view never
/// re-evaluated and the join code stayed stuck on its "Generating code…"
/// snapshot. This view model reads through Core Data on every viewContext
/// `ObjectsDidChange`, which catches both direct writes and listener-driven
/// background-context merges (the viewContext has
/// `automaticallyMergesChangesFromParent` on). Same cure as the May 28
/// `SupervisorDashboardViewModel.actorIsPrimary` fix.
@MainActor
final class CircleSettingsViewModel: ObservableObject {
    @Published private(set) var circleName: String = ""
    @Published private(set) var joinCode: String?

    private let stack: CoreDataStack
    private let careCircleID: UUID
    private var observer: NSObjectProtocol?

    init(stack: CoreDataStack = .shared, careCircleID: UUID) {
        self.stack = stack
        self.careCircleID = careCircleID
        loadFromCoreData()
        let viewContext = stack.viewContext
        observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: viewContext,
            queue: .main
        ) { [weak self] _ in
            // Fires on direct viewContext writes AND on background-context
            // merges into it (automaticallyMergesChangesFromParent), so both
            // the synchronous create and the listener mirror reach us here.
            Task { @MainActor [weak self] in
                self?.loadFromCoreData()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Re-read name + joinCode from the CareCircle row and republish only on a
    /// real change. The per-field no-op guard keeps an unrelated viewContext
    /// change (some other row) from thrashing the view — SwiftUI is invalidated
    /// only when one of these two values actually moves.
    private func loadFromCoreData() {
        let request = NSFetchRequest<CareCircle>(entityName: "CareCircle")
        request.predicate = NSPredicate(format: "id == %@", careCircleID as CVarArg)
        request.fetchLimit = 1
        guard let circle = (try? stack.viewContext.fetch(request))?.first else { return }
        let name = circle.name ?? ""
        let code = circle.joinCode
        if name != circleName { circleName = name }
        if code != joinCode { joinCode = code }
    }
}
