import Foundation

/// Thread-safe on-disk cache of openFDA drug payloads. Keys are normalised
/// (lowercased, alphanumeric only) so "Eliquis", "  ELIQUIS  " and "eliquis"
/// all hit the same entry. Storage lives in the user's Caches directory —
/// these are derivable from the network and safe to lose.
actor DrugInfoCache {
    static let shared = DrugInfoCache(url: defaultURL)

    private struct Entry: Codable {
        let key: String
        let drug: OpenFDADrug
        var lastAccess: Date
    }

    private var entries: [Entry] = []
    private let url: URL
    private let maxEntries: Int

    init(url: URL, maxEntries: Int = 50) {
        self.url = url
        self.maxEntries = maxEntries
        self.entries = Self.loadFromDisk(at: url)
    }

    var count: Int { entries.count }

    func get(_ key: String) -> OpenFDADrug? {
        let normalized = Self.normalize(key)
        guard let idx = entries.firstIndex(where: { $0.key == normalized }) else { return nil }
        entries[idx].lastAccess = Date()
        persist()
        return entries[idx].drug
    }

    func set(_ key: String, _ drug: OpenFDADrug) {
        let normalized = Self.normalize(key)
        let entry = Entry(key: normalized, drug: drug, lastAccess: Date())
        if let idx = entries.firstIndex(where: { $0.key == normalized }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        // LRU eviction: drop the oldest entries until we're back under cap.
        if entries.count > maxEntries {
            entries.sort { $0.lastAccess < $1.lastAccess }
            entries.removeFirst(entries.count - maxEntries)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    // MARK: - Persistence

    private static func loadFromDisk(at url: URL) -> [Entry] {
        guard
            let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static var defaultURL: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDir.appendingPathComponent("dosely-drug-cache.json")
    }
}
