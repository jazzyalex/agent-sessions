import Foundation

enum MenuBarScope: String, CaseIterable, Identifiable {
    case fiveHour
    case weekly
    case both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fiveHour: return "5h only"
        case .weekly: return "Weekly only"
        case .both: return "Both"
        }
    }
}

enum MenuBarStyleKind: String, CaseIterable, Identifiable {
    case bars
    case numbers
    var id: String { rawValue }
    var title: String { self == .bars ? "Bars" : "Numbers only" }
}

enum MenuBarSource: String, CaseIterable, Identifiable {
    case codex
    case claude
    case both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .both: return "Both"
        }
    }
}
