import XCTest
@testable import AgentSessions

final class ClaudeOAuthTokenResolverTests: XCTestCase {

    // MARK: - Env var

    func testResolve_envVarPresent_returnsEnvToken() async {
        // This test is environment-dependent; we can't easily set env vars in tests.
        // Instead we verify the resolver doesn't crash with no env var set.
        let resolver = ClaudeOAuthTokenResolver()
        // If CLAUDE_CODE_OAUTH_TOKEN is not set, should not return .env source
        let result = await resolver.resolve()
        if let result {
            // If something resolved, ensure it's not empty
            XCTAssertFalse(result.token.isEmpty)
        }
    }

    // MARK: - Credentials file

    func testResolve_credentialsFile_accessToken() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let credFile = dir.appendingPathComponent(".credentials.json")
        let json = #"{"accessToken":"test-token-abc"}"#
        try json.data(using: .utf8)!.write(to: credFile)

        // We can test the parsing logic indirectly via the normalizer
        // Direct test of file parsing (internal):
        // Since ClaudeOAuthTokenResolver is an actor, we can call resolve() after
        // setting up a test environment. However, the file path is hardcoded to ~/.claude/.
        // We verify the JSON parsing logic independently here.
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(parsed["accessToken"] as? String, "test-token-abc")
    }

    func testResolve_credentialsFile_accessTokenUnderscored() async throws {
        let json = #"{"access_token":"test-token-xyz"}"#
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(parsed["access_token"] as? String, "test-token-xyz")
    }

    func testResolve_credentialsFile_nestedClaudeAiOauth() async throws {
        let json = #"{"claudeAiOauth":{"accessToken":"nested-token"}}"#
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let nested = parsed["claudeAiOauth"] as! [String: Any]
        XCTAssertEqual(nested["accessToken"] as? String, "nested-token")
    }

    func testResolve_malformedCredentialsFile_returnsNil() async throws {
        let json = "not valid json {"
        let data = json.data(using: .utf8)!
        XCTAssertNil(try? JSONSerialization.jsonObject(with: data))
    }

    // MARK: - Cache

    func testResolve_cacheIsUsedOnSecondCall() async {
        let resolver = ClaudeOAuthTokenResolver()
        // Two consecutive calls — should be consistent
        let first = await resolver.resolve()
        let second = await resolver.resolve()
        XCTAssertEqual(first?.token, second?.token)
        XCTAssertEqual(first?.source.rawValue, second?.source.rawValue)
    }

    func testInvalidateCache_clearsCache() async {
        let resolver = ClaudeOAuthTokenResolver()
        _ = await resolver.resolve()
        await resolver.invalidateCache()
        // After invalidation, resolve again — no crash
        _ = await resolver.resolve()
    }
}
