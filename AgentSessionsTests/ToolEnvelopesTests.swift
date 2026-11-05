import XCTest
@testable import AgentSessions

/// Task 7: `ToolEnvelopes.lift` — agent envelopes become facts, anchored at the start or end only.
final class ToolEnvelopesTests: XCTestCase {
    private func lift(_ s: String, _ source: SessionSource = .codex) -> (body: String, facts: [AgentFact], hiddenNotes: [String]) {
        ToolEnvelopes.lift(s, source: source, toolName: nil)
    }

    func testCodexChunkHeaderLifted() {
        let s = "Chunk ID: ab12\nWall time: 0.0 seconds\nProcess exited with code 0\nOriginal token count: 5\nOutput:\nhello\nworld\n"
        let r = lift(s)
        XCTAssertEqual(r.body, "hello\nworld\n")
        XCTAssertEqual(r.facts.map(\.kind), [.exitCode(0), .wallTime(0.0)])
        XCTAssertTrue(r.hiddenNotes.isEmpty)
    }

    func testCodexExitCodeWallTimeOutputForm() {
        let r = lift("Exit code: 2\nWall time: 1.5 seconds\nOutput:\nboom")
        XCTAssertEqual(r.body, "boom")
        XCTAssertEqual(r.facts.map(\.kind), [.exitCode(2), .wallTime(1.5)])
    }

    func testCodexScriptItemAndMCPHeader() {
        let ok = lift("Script completed\nWall time 0.4 seconds\nOutput:\nx")
        XCTAssertEqual(ok.body, "x")
        XCTAssertEqual(ok.facts.map(\.kind), [.wallTime(0.4)])
        let failed = lift("Script failed\nWall time 0.1 seconds\nOutput:\nerr")
        XCTAssertEqual(failed.facts.map(\.kind), [.wallTime(0.1), .note("Script failed")])
        let running = lift("Script running with cell ID 7\nWall time 2 seconds\nOutput:\n")
        XCTAssertEqual(running.facts.map(\.kind), [.wallTime(2), .note("Script running with cell ID 7")])
        let mcp = lift("Wall time: 0.3 seconds\nOutput:\nresult")
        XCTAssertEqual(mcp.body, "result")
        XCTAssertEqual(mcp.facts.map(\.kind), [.wallTime(0.3)])
    }

    func testCodexAbortedByUser() {
        let r = lift("partial\naborted by user after 5s")
        XCTAssertEqual(r.body, "partial")
        XCTAssertEqual(r.facts.map(\.kind), [.note("aborted by user after 5s")])
    }

    func testCodexDoubleTruncationBothLifted() {
        let s = "Wall time: 0.1 seconds\nOutput:\nWarning: truncated output (original token count: 5000)\nTotal output lines: 800\n\n"
            + "Warning: truncated output (original token count: 90)\nTotal output lines: 12\n\nbody line\n"
        let r = lift(s)
        XCTAssertEqual(r.body, "body line\n")
        XCTAssertEqual(r.facts.map(\.kind), [
            .wallTime(0.1),
            .truncated(agent: "codex", originalTokens: 5000, totalLines: 800),
            .truncated(agent: "codex", originalTokens: 90, totalLines: 12),
        ])
    }

    func testClaudeExitCodeAndCwdTrailer() {
        let r = lift("Exit code 1\nfailure text\nShell cwd was reset to /Users/x/proj", .claude)
        XCTAssertEqual(r.body, "failure text")
        XCTAssertEqual(r.facts.map(\.kind), [.exitCode(1), .note("Shell cwd was reset to /Users/x/proj")])
    }

    func testClaudeSystemReminderTailHidden() {
        let s = "file body\n\n<system-reminder>\nWhenever you read a file, consider malware.\n</system-reminder>\n<system-reminder>second</system-reminder>\n"
        let r = lift(s, .claude)
        XCTAssertEqual(r.body, "file body")
        XCTAssertEqual(r.hiddenNotes, ["Whenever you read a file, consider malware.", "second"])
        XCTAssertTrue(r.facts.isEmpty)
        // Codex output is not touched by the Claude rule.
        XCTAssertEqual(lift(s, .codex).body, s)
    }

    func testClaudePersistedOutputFact() {
        let s = "<persisted-output>\nOutput too large (38.4KB). Full output saved to: /tmp/out/abc.txt\n\nPreview (first 2KB):\nline one\nline two\n...\n</persisted-output>"
        let r = lift(s, .claude)
        XCTAssertEqual(r.body, "line one\nline two\n...")
        XCTAssertEqual(r.facts.map(\.kind), [.persisted(path: "/tmp/out/abc.txt", bytes: 39322)])
    }

    func testClaudePartialViewFact() {
        let r = lift("[Truncated: PARTIAL view of the file, lines 1-200 of 900]\ncontent", .claude)
        XCTAssertEqual(r.body, "content")
        XCTAssertEqual(r.facts.map(\.kind), [.truncated(agent: "claude", originalTokens: nil, totalLines: nil)])
    }

    func testGenericForms() {
        let a = lift("out\n[Process exited with code 3]", .grok)
        XCTAssertEqual(a.body, "out")
        XCTAssertEqual(a.facts.map(\.kind), [.exitCode(3)])
        let b = lift("out\n<shellId: 7 completed with exit code 0>", .copilot)
        XCTAssertEqual(b.body, "out")
        XCTAssertEqual(b.facts.map(\.kind), [.exitCode(0)])
        let c = lift("out\n\nExit Code: 1", .opencode)
        XCTAssertEqual(c.body, "out")
        XCTAssertEqual(c.facts.map(\.kind), [.exitCode(1)])
    }

    func testEnvelopeWordsInMiddleAreKept() {
        let s = "x\nProcess exited with code 1\ny"
        let r = lift(s)
        XCTAssertEqual(r.body, s)
        XCTAssertTrue(r.facts.isEmpty)
        let mid = "a\nExit Code: 1\nb\n<system-reminder>t</system-reminder>\nc"
        let m = lift(mid, .claude)
        XCTAssertEqual(m.body, mid)
        XCTAssertTrue(m.hiddenNotes.isEmpty)
        // A header without its "Output:" line is not an envelope.
        let partial = "Chunk ID: a\nWall time: 1 seconds\nbody"
        XCTAssertEqual(lift(partial).body, partial)
    }
}
