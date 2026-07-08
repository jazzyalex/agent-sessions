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
        // Recovery must be via `.ok` — the only state that resets the episode.
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
    /// I9: `.unknown` is ambiguous/transient and must NOT reset the one-shot
    /// episode. A `signedOut -> unknown -> signedOut` sequence (e.g. a
    /// transient probe failure between two real signed-out polls) must still
    /// only post once, because the episode was never reset.
    func testUnknownDoesNotResetEpisode() async {
        let g = FakeGate(); let n = AuthStatusNotifier(gate: g, store: store())
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .unknown), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        XCTAssertEqual(g.posts, 1)
    }
    /// I8: when notifications aren't authorized, the alarming episode must
    /// NOT be consumed. Once authorization is granted during the SAME
    /// signed-out episode, the notifier must still be able to fire exactly once.
    func testNotAuthorizedDoesNotConsumeEpisode() async {
        let g = FakeGate(); g.authorized = false; let st = store(); let n = AuthStatusNotifier(gate: g, store: st)
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        XCTAssertEqual(g.posts, 0)
        g.authorized = true
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        XCTAssertEqual(g.posts, 1)
    }
}
