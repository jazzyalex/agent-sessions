import XCTest
@testable import AgentSessions

final class ColumnVisibilityStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ColumnVisibilityStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create UserDefaults suite \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testDefaultsLoadAsEnabled() {
        let (defaults, suite) = makeDefaults()
        let store = ColumnVisibilityStore(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(store.showTitleColumn)
        XCTAssertTrue(store.showModifiedColumn)
        XCTAssertTrue(store.showProjectColumn)
        XCTAssertTrue(store.showMsgsColumn)
        XCTAssertTrue(store.showSizeColumn)
    }

    func testPersistsChanges() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var store: ColumnVisibilityStore? = ColumnVisibilityStore(defaults: defaults)
        let initialToken = store?.changeToken
        store?.showTitleColumn = false
        let toggledToken = store?.changeToken
        store?.showProjectColumn = false
        XCTAssertNotEqual(initialToken, toggledToken)
        store = nil // release to simulate app restart

        let rehydrated = ColumnVisibilityStore(defaults: defaults)
        XCTAssertFalse(rehydrated.showTitleColumn)
        XCTAssertFalse(rehydrated.showProjectColumn)
        XCTAssertTrue(rehydrated.showMsgsColumn)
    }
}
