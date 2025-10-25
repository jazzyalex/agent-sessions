import Foundation

/// Persists per-session collapsed/expanded state for sections.
/// Keeps up to a small LRU of recent sessions to bound storage.
actor CollapsedStateStore {
    static let shared = CollapsedStateStore()

    private struct Record: Codable { var expandedHistorical: Bool; var expandedSafety: Bool; var updatedAt: TimeInterval }

    private let defaultsKey = "GitInspector.CollapsedState.v1"
    private let lruCapacity = 200
    private var map: [String: Record] = [:]
    private var loaded = false

    private func loadIfNeeded() {
        guard !loaded else { return }
        defer { loaded = true }
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            if let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
                map = decoded
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func get(for sessionKey: SessionKey) -> (historical: Bool?, safety: Bool?) {
        loadIfNeeded()
        guard let r = map[sessionKey.rawValue] else { return (nil, nil) }
        return (r.expandedHistorical, r.expandedSafety)
    }

    func set(for sessionKey: SessionKey, expandedHistorical: Bool?, expandedSafety: Bool?) {
        loadIfNeeded()
        var rec = map[sessionKey.rawValue] ?? Record(expandedHistorical: true, expandedSafety: false, updatedAt: Date().timeIntervalSince1970)
        if let eh = expandedHistorical { rec.expandedHistorical = eh }
        if let es = expandedSafety { rec.expandedSafety = es }
        rec.updatedAt = Date().timeIntervalSince1970
        map[sessionKey.rawValue] = rec
        trimIfNeeded()
        persist()
    }

    private func trimIfNeeded() {
        guard map.count > lruCapacity else { return }
        let sorted = map.sorted { $0.value.updatedAt < $1.value.updatedAt }
        let toDrop = sorted.prefix(max(0, map.count - lruCapacity))
        for (k, _) in toDrop { map.removeValue(forKey: k) }
    }
}

