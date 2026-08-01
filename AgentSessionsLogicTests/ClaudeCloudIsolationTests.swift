import XCTest

/// Source-level guards for the ClaudeCloud module.
///
/// These assert the module's contract rather than its behaviour, because the
/// constraints they protect are invisible at runtime right up until they are
/// violated: a stray POST, a write to the index, or a filter that quietly widens
/// to include bridge sessions all compile and all pass every behavioural test.
final class ClaudeCloudIsolationTests: XCTestCase {

    private func cloudSources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentSessionsLogicTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("AgentSessions/ClaudeCloud")
        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "guard is vacuous if it finds no sources")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func test_noCloudCodeTouchesTheIndexDatabase() throws {
        for file in try cloudSources() {
            XCTAssertFalse(file.text.contains("index.db"), "\(file.name) references index.db")
            XCTAssertFalse(file.text.contains("sqlite3_"), "\(file.name) uses sqlite directly")
        }
    }

    func test_noMutatingHTTPMethods() throws {
        for file in try cloudSources() {
            for verb in ["\"POST\"", "\"PUT\"", "\"DELETE\"", "\"PATCH\""] {
                XCTAssertFalse(file.text.contains(verb), "\(file.name) issues \(verb)")
            }
        }
    }

    func test_forbiddenEndpointsAreNeverCalled() throws {
        for file in try cloudSources() {
            XCTAssertFalse(file.text.contains("safety_flags"),
                           "\(file.name) calls the per-message endpoint (N requests per transcript)")
            XCTAssertFalse(file.text.contains("poll=true"),
                           "\(file.name) long-polls, inverting the cost model")
        }
    }

    /// The filter must key off environment_kind. Every row the endpoint returns is
    /// cse_-prefixed, so a prefix test selects the bridge sessions too — which the
    /// local indexer already shows, producing duplicate rows.
    func test_filterUsesEnvironmentKindNotTheIdPrefix() throws {
        let sources = try cloudSources()
        for file in sources {
            XCTAssertFalse(file.text.contains("hasPrefix(\"cse_\")"),
                           "\(file.name) filters on the cse_ prefix — must use environment_kind")
        }
        XCTAssertTrue(sources.contains { $0.text.contains("anthropic_cloud") },
                      "no source references anthropic_cloud — the cloud filter went missing")
    }
}
