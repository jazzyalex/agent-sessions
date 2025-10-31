import Foundation
import Combine

/// Tracks visibility for Codex-specific table columns and persists preferences.
final class ColumnVisibilityStore: ObservableObject {
    enum Column: CaseIterable {
        case title
        case modified
        case project
        case messages
        case size

        var defaultsKey: String {
            switch self {
            case .title: return "ShowTitleColumn"
            case .modified: return "ShowModifiedColumn"
            case .project: return "ShowProjectColumn"
            case .messages: return "ShowMsgsColumn"
            case .size: return "ShowSizeColumn"
            }
        }
    }

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    @Published var showTitleColumn: Bool
    @Published var showModifiedColumn: Bool
    @Published var showProjectColumn: Bool
    @Published var showMsgsColumn: Bool
    @Published var showSizeColumn: Bool
    @Published private(set) var changeToken: UUID = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        showTitleColumn = ColumnVisibilityStore.initialValue(for: .title, defaults: defaults, fallback: true)
        showModifiedColumn = ColumnVisibilityStore.initialValue(for: .modified, defaults: defaults, fallback: true)
        showProjectColumn = ColumnVisibilityStore.initialValue(for: .project, defaults: defaults, fallback: true)
        showMsgsColumn = ColumnVisibilityStore.initialValue(for: .messages, defaults: defaults, fallback: true)
        showSizeColumn = ColumnVisibilityStore.initialValue(for: .size, defaults: defaults, fallback: true)

        bind(\.$showTitleColumn, column: .title)
        bind(\.$showModifiedColumn, column: .modified)
        bind(\.$showProjectColumn, column: .project)
        bind(\.$showMsgsColumn, column: .messages)
        bind(\.$showSizeColumn, column: .size)
    }

    /// Reset all persisted values back to defaults without removing other preferences.
    func restoreDefaults() {
        showTitleColumn = true
        showModifiedColumn = true
        showProjectColumn = true
        showMsgsColumn = true
        showSizeColumn = true
        notifyChange()
    }

    private static func initialValue(for column: Column,
                                     defaults: UserDefaults,
                                     fallback: Bool) -> Bool {
        if let value = defaults.object(forKey: column.defaultsKey) as? Bool {
            return value
        }
        return fallback
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<ColumnVisibilityStore, Published<Bool>.Publisher>,
                      column: Column) {
        self[keyPath: keyPath]
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.defaults.set(newValue, forKey: column.defaultsKey)
                self?.notifyChange()
            }
            .store(in: &cancellables)
    }

    private func notifyChange() {
        changeToken = UUID()
    }
}
