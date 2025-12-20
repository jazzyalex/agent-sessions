import Foundation

struct StarredSessionKey: Hashable {
    let source: SessionSource
    let id: String

    var persistedString: String { "\(source.rawValue):\(id)" }

    init(source: SessionSource, id: String) {
        self.source = source
        self.id = id
    }

    init?(persistedString: String) {
        let parts = persistedString.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard let source = SessionSource(rawValue: String(parts[0])) else { return nil }
        let id = String(parts[1])
        guard !id.isEmpty else { return nil }
        self.source = source
        self.id = id
    }
}

/// UserDefaults-backed store for Starred sessions.
///
/// Backward compatible: legacy entries that are just an ID (no `source:` prefix) are treated as "star any source with this id".
struct StarredSessionsStore {
    static let defaultsKey = "favoriteSessionIDs"

    private(set) var legacyIDs: Set<String>
    private(set) var scopedKeys: Set<StarredSessionKey>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.stringArray(forKey: Self.defaultsKey) ?? []

        var legacy: Set<String> = []
        var scoped: Set<StarredSessionKey> = []
        for s in raw {
            if let key = StarredSessionKey(persistedString: s) {
                scoped.insert(key)
            } else if !s.isEmpty {
                legacy.insert(s)
            }
        }
        self.legacyIDs = legacy
        self.scopedKeys = scoped
    }

    func contains(id: String, source: SessionSource) -> Bool {
        if scopedKeys.contains(.init(source: source, id: id)) { return true }
        return legacyIDs.contains(id)
    }

    mutating func setStarred(_ starred: Bool, id: String, source: SessionSource) {
        let key = StarredSessionKey(source: source, id: id)
        if starred {
            scopedKeys.insert(key)
        } else {
            scopedKeys.remove(key)
            // Legacy entries are unscoped; removing one session can't be made precise.
            // Best-effort: remove the legacy entry if present, which unstars all sessions that share this id.
            legacyIDs.remove(id)
        }
        persist()
    }

    @discardableResult
    mutating func toggle(id: String, source: SessionSource) -> Bool {
        let nowStarred = !contains(id: id, source: source)
        setStarred(nowStarred, id: id, source: source)
        return nowStarred
    }

    func pinnedIDs(for source: SessionSource) -> Set<String> {
        var ids: Set<String> = []
        for key in scopedKeys where key.source == source { ids.insert(key.id) }
        ids.formUnion(legacyIDs)
        return ids
    }

    private func persist() {
        let raw = Array(scopedKeys.map(\.persistedString) + legacyIDs)
        defaults.set(raw, forKey: Self.defaultsKey)
    }
}

