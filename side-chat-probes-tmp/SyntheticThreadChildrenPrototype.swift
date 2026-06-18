import Foundation

enum RelationshipKind: String {
    case main
    case subagent
    case sideChat
}

struct ProbeSession: Identifiable {
    let id: String
    let title: String
    let parentID: String?
    let relationship: RelationshipKind
    let modifiedAt: Int
}

struct ProbeRow {
    let session: ProbeSession
    let depth: Int
    let childCount: Int
}

func flattenedHierarchy(_ sessions: [ProbeSession]) -> [ProbeRow] {
    var childrenByParent: [String: [ProbeSession]] = [:]
    var childIDs = Set<String>()

    for session in sessions {
        guard let parentID = session.parentID else { continue }
        childrenByParent[parentID, default: []].append(session)
        childIDs.insert(session.id)
    }

    for parentID in childrenByParent.keys {
        childrenByParent[parentID]?.sort {
            if $0.modifiedAt == $1.modifiedAt { return $0.id < $1.id }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    var rows: [ProbeRow] = []
    for session in sessions.sorted(by: { $0.modifiedAt > $1.modifiedAt }) where !childIDs.contains(session.id) {
        let children = childrenByParent[session.id] ?? []
        rows.append(ProbeRow(session: session, depth: 0, childCount: children.count))
        for child in children {
            rows.append(ProbeRow(session: child, depth: 1, childCount: 0))
        }
    }
    return rows
}

let sample = [
    ProbeSession(id: "main-a", title: "Refactor parser", parentID: nil, relationship: .main, modifiedAt: 100),
    ProbeSession(id: "side-a1", title: "Quick API question", parentID: "main-a", relationship: .sideChat, modifiedAt: 104),
    ProbeSession(id: "sub-a1", title: "Review worker", parentID: "main-a", relationship: .subagent, modifiedAt: 103),
    ProbeSession(id: "main-b", title: "Standalone task", parentID: nil, relationship: .main, modifiedAt: 90),
    ProbeSession(id: "orphan-side", title: "Unresolved side chat", parentID: "missing", relationship: .sideChat, modifiedAt: 110)
]

print("Synthetic generic thread-child rows")
for row in flattenedHierarchy(sample) {
    let indent = String(repeating: "  ", count: row.depth)
    let marker: String
    switch row.session.relationship {
    case .main:
        marker = row.childCount > 0 ? "main children=\(row.childCount)" : "main"
    case .subagent:
        marker = "subagent"
    case .sideChat:
        marker = "side"
    }
    print("\(indent)- [\(marker)] \(row.session.title) (\(row.session.id))")
}
