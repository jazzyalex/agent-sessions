import XCTest
@testable import AgentSessions

final class AuthStatusNotifierTests: XCTestCase {
    final class FakeGate: NotificationGate {
        var authorized = true; private(set) var posts = 0
        func isAuthorized() async -> Bool { authorized }
        func post(title: String, body: String) { posts += 1 }
    }
    private func store() -> AuthEpisodeStore {
        UserDefaults.standard.removeObject(forKey: "AuthEpisode.claude")
        return AuthEpisodeStore()
    }
    func testFiresOncePerEpisode() async {
        let g = FakeGate(); let n = AuthStatusNotifier(gate: g, store: store())
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        XCTAssertEqual(g.posts, 1)
    }
    func testSignedOutThenExpiredShareEpisode() async {
        let g = FakeGate(); let n = AuthStatusNotifier(gate: g, store: store())
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .expired), provider: .claude)
        XCTAssertEqual(g.posts, 1)
    }
    func testRecoveryThenSignedOutRefires() async {
        let g = FakeGate(); let st = store(); let n = AuthStatusNotifier(gate: g, store: st)
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .ok), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        XCTAssertEqual(g.posts, 2)
    }
    func testNotAuthorizedNeverPosts() async {
        let g = FakeGate(); g.authorized = false; let n = AuthStatusNotifier(gate: g, store: store())
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        XCTAssertEqual(g.posts, 0)
    }
    func testUnknownNeverPosts() async {
        let g = FakeGate(); let n = AuthStatusNotifier(gate: g, store: store())
        await n.onStatus(.make(provider: .claude, state: .unknown), provider: .claude)
        XCTAssertEqual(g.posts, 0)
    }
}
