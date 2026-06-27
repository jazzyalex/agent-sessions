// AgentSessionsTests/AntigravityResumeTypesTests.swift
import XCTest
@testable import AgentSessions

final class AntigravityResumeTypesTests: XCTestCase {
    func testConversationIDFromNewNestedPath() {
        let url = URL(fileURLWithPath: "/h/.gemini/antigravity-cli/brain/abc-123/.system_generated/logs/transcript.jsonl")
        XCTAssertEqual(AntigravitySessionIDHelper.conversationID(fromArtifactURL: url), "abc-123")
    }
    func testConversationIDFromLegacyMarkdownPath() {
        let url = URL(fileURLWithPath: "/h/.gemini/antigravity/brain/def-456/task.md")
        XCTAssertEqual(AntigravitySessionIDHelper.conversationID(fromArtifactURL: url), "def-456")
    }
}
