// AgentSessionsTests/GeminiResumeTypesTests.swift
import XCTest
@testable import AgentSessions

final class GeminiResumeTypesTests: XCTestCase {
    func testConversationIDFromNewNestedPath() {
        let url = URL(fileURLWithPath: "/h/.gemini/antigravity-cli/brain/abc-123/.system_generated/logs/transcript.jsonl")
        XCTAssertEqual(GeminiSessionIDHelper.conversationID(fromArtifactURL: url), "abc-123")
    }
    func testConversationIDFromLegacyMarkdownPath() {
        let url = URL(fileURLWithPath: "/h/.gemini/antigravity/brain/def-456/task.md")
        XCTAssertEqual(GeminiSessionIDHelper.conversationID(fromArtifactURL: url), "def-456")
    }
}
