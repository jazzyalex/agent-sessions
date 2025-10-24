import Foundation

/// Represents a single file's change status in git
public struct GitFileStatus: Equatable, Identifiable {
    public let id: String
    public let path: String
    public let changeType: FileChangeType

    public init(path: String, changeType: FileChangeType) {
        self.id = path
        self.path = path
        self.changeType = changeType
    }

    /// Display icon for this change type
    public var icon: String {
        changeType.icon
    }

    /// Display color for this change type
    public var displayColor: String {
        changeType.displayColor
    }
}

/// Type of file change in git status
public enum FileChangeType: String, Equatable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "??"
    case typeChanged = "T"
    case unmerged = "U"

    /// SF Symbols icon name for this change type
    public var icon: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "??"
        case .typeChanged: return "T"
        case .unmerged: return "U"
        }
    }

    /// Color for displaying this change type
    public var displayColor: String {
        switch self {
        case .modified: return "orange"
        case .added: return "green"
        case .deleted: return "red"
        case .renamed: return "blue"
        case .copied: return "blue"
        case .untracked: return "gray"
        case .typeChanged: return "purple"
        case .unmerged: return "red"
        }
    }

    /// Human-readable description
    public var description: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .untracked: return "Untracked"
        case .typeChanged: return "Type changed"
        case .unmerged: return "Unmerged"
        }
    }
}
