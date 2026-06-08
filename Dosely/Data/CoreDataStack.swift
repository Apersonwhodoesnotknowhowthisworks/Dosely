import CoreData
import os

/// Single shared OSSignposter for performance instrumentation (perf audit,
/// June 8). Named begin/end interval pairs surface under the "performance"
/// category in Instruments' os_signpost / Points of Interest tracks. Left
/// unguarded (no #if DEBUG) deliberately: OSSignposter is near-zero cost when
/// no Instruments tool is attached, so keeping it in release builds lets a
/// future field-measurement run happen on a real device without a special build.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.medication.dosely", category: "performance")
}

final class CoreDataStack {
    static let shared = CoreDataStack()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    private init() {
        self.container = CoreDataStack.makeContainer(inMemory: false)
    }

    init(inMemory: Bool) {
        self.container = CoreDataStack.makeContainer(inMemory: inMemory)
    }

    private static func makeContainer(inMemory: Bool) -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Dosely")
        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
        }
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Core Data failed to load: \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return container
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return ctx
    }

    func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask(block)
    }
}
