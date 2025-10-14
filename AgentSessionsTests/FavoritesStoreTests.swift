import XCTest
@testable import AgentSessions

final class FavoritesStoreTests: XCTestCase {
    func testToggleAndPersistence() {
        let suite = UserDefaults(suiteName: "FavoritesStoreTests")!
        suite.removePersistentDomain(forName: "FavoritesStoreTests")

        var store = FavoritesStore(defaults: suite)
        XCTAssertFalse(store.contains("abc"))

        store.toggle("abc")
        XCTAssertTrue(store.contains("abc"))

        // Recreate to verify persistence
        let store2 = FavoritesStore(defaults: suite)
        XCTAssertTrue(store2.contains("abc"))

        // Remove
        var store3 = store2
        store3.toggle("abc")
        XCTAssertFalse(store3.contains("abc"))
        let store4 = FavoritesStore(defaults: suite)
        XCTAssertFalse(store4.contains("abc"))
    }
}

