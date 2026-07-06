import XCTest
@testable import AgentSessions

/// Task C2 (Rich review-card parity). Pure-logic tests for
/// `BlockTableController.reviewSummary(for:source:enabled:)` — the Rich-mode
/// review-card detector that mirrors the two Terminal-mode detectors
/// (`TerminalBuilder.reviewDisplayTextIfNeeded` and
/// `InternalPayloadFormatter.parseReviewCard`) without a table, cell, or
/// session fixture.
final class TranscriptBlockListReviewCardTests: XCTestCase {

    private func block(kind: SessionTranscriptBuilder.LogicalBlock.Kind,
                        text: String,
                        eventID: String = "e1") -> SessionTranscriptBuilder.LogicalBlock {
        SessionTranscriptBuilder.LogicalBlock(
            kind: kind, text: text, timestamp: nil, messageID: nil, toolName: nil,
            isDelta: false, toolInput: nil, isErrorOutput: false, eventID: eventID, rawJSON: "")
    }

    private let assistantReviewJSON = """
    {
      "findings": [],
      "overall_correctness": "correct",
      "overall_explanation": "Looks good.",
      "overall_confidence_score": 0.92
    }
    """

    private let userReviewPayload = """
    <user_action>
      <action>review</action>
      <results>All checks passed.</results>
    </user_action>
    """

    // MARK: Assistant review JSON -> summary

    func testAssistantReviewJSONProducesSummaryWhenEnabledAndCodex() {
        let b = block(kind: .assistant, text: assistantReviewJSON)
        let summary = BlockTableController.reviewSummary(for: b, source: .codex, enabled: true)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.hasPrefix("Review"))
        XCTAssertTrue(summary!.contains("Correctness: correct"))
        XCTAssertTrue(summary!.contains("Confidence: 0.92"))
        XCTAssertTrue(summary!.contains("Findings: 0"))
        XCTAssertTrue(summary!.contains("Looks good."))
    }

    func testAssistantReviewJSONNilWhenDisabled() {
        let b = block(kind: .assistant, text: assistantReviewJSON)
        XCTAssertNil(BlockTableController.reviewSummary(for: b, source: .codex, enabled: false))
    }

    func testAssistantReviewJSONNilForNonCodexSource() {
        let b = block(kind: .assistant, text: assistantReviewJSON)
        XCTAssertNil(BlockTableController.reviewSummary(for: b, source: .claude, enabled: true))
    }

    // MARK: User <user_action>review</user_action> -> cleaned "Review" text

    func testUserReviewActionProducesCleanedReviewText() {
        let b = block(kind: .user, text: userReviewPayload)
        let summary = BlockTableController.reviewSummary(for: b, source: .codex, enabled: true)
        XCTAssertEqual(summary, "Review\nAll checks passed.")
    }

    func testUserReviewActionWithEmptyResultsFallsBackToBareReview() {
        let text = "<user_action>\n  <action>review</action>\n  <results></results>\n</user_action>"
        let b = block(kind: .user, text: text)
        XCTAssertEqual(BlockTableController.reviewSummary(for: b, source: .codex, enabled: true), "Review")
    }

    func testUserReviewActionNilWhenDisabled() {
        let b = block(kind: .user, text: userReviewPayload)
        XCTAssertNil(BlockTableController.reviewSummary(for: b, source: .codex, enabled: false))
    }

    func testUserReviewActionNilForNonCodexSource() {
        let b = block(kind: .user, text: userReviewPayload)
        XCTAssertNil(BlockTableController.reviewSummary(for: b, source: .claude, enabled: true))
    }

    // MARK: Normal (non-review) blocks are unaffected

    func testNormalUserBlockReturnsNil() {
        let b = block(kind: .user, text: "Please refactor this function.")
        XCTAssertNil(BlockTableController.reviewSummary(for: b, source: .codex, enabled: true))
    }

    func testNormalAssistantBlockReturnsNil() {
        let b = block(kind: .assistant, text: "Sure, here is the updated function:\n```swift\nfunc x() {}\n```")
        XCTAssertNil(BlockTableController.reviewSummary(for: b, source: .codex, enabled: true))
    }

    func testAssistantJSONMissingRequiredKeysReturnsNil() {
        let text = """
        {
          "overall_correctness": "correct",
          "overall_explanation": "missing findings/confidence"
        }
        """
        let b = block(kind: .assistant, text: text)
        XCTAssertNil(BlockTableController.reviewSummary(for: b, source: .codex, enabled: true))
    }

    func testToolAndMetaBlocksReturnNilEvenIfTextLooksLikeReview() {
        let toolBlock = block(kind: .toolCall, text: assistantReviewJSON)
        let metaBlock = block(kind: .meta, text: userReviewPayload)
        XCTAssertNil(BlockTableController.reviewSummary(for: toolBlock, source: .codex, enabled: true))
        XCTAssertNil(BlockTableController.reviewSummary(for: metaBlock, source: .codex, enabled: true))
    }
}
