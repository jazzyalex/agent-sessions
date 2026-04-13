import XCTest
@testable import AgentSessions

/// Tests for the "Copy Resume Command" feature (Issue #25 V1).
/// Covers shell-quoting, shellQuoteIfNeeded, and the command strings
/// produced for each scenario.
@MainActor
final class CopyResumeCommandTests: XCTestCase {

    // MARK: - shellQuote (always quotes)

    func testShellQuoteSimplePath() {
        let q = ClaudeResumeCommandBuilder().shellQuote("/usr/local/bin/claude")
        XCTAssertEqual(q, "'/usr/local/bin/claude'")
    }

    func testShellQuotePathWithSpaces() {
        let q = ClaudeResumeCommandBuilder().shellQuote("/my projects/claude")
        XCTAssertEqual(q, "'/my projects/claude'")
    }

    func testShellQuotePathWithApostrophe() {
        let q = ClaudeResumeCommandBuilder().shellQuote("/alex's/bin/claude")
        XCTAssertEqual(q, "'/alex'\\''s/bin/claude'")
    }

    func testShellQuoteEmptyString() {
        let q = ClaudeResumeCommandBuilder().shellQuote("")
        XCTAssertEqual(q, "''")
    }

    // MARK: - shellQuoteIfNeeded (smart quoting for copy commands)

    func testQuoteIfNeeded_bareCommand_noQuotes() {
        XCTAssertEqual(ClaudeResumeCommandBuilder().shellQuoteIfNeeded("claude"), "claude")
    }

    func testQuoteIfNeeded_uuid_noQuotes() {
        XCTAssertEqual(ClaudeResumeCommandBuilder().shellQuoteIfNeeded("0ef3d2af-ad6f-4da7-813e-e27e466ed223"),
                       "0ef3d2af-ad6f-4da7-813e-e27e466ed223")
    }

    func testQuoteIfNeeded_simplePath_noQuotes() {
        XCTAssertEqual(ClaudeResumeCommandBuilder().shellQuoteIfNeeded("/usr/local/bin/claude"),
                       "/usr/local/bin/claude")
    }

    func testQuoteIfNeeded_pathWithSpaces_quotes() {
        XCTAssertEqual(ClaudeResumeCommandBuilder().shellQuoteIfNeeded("/my projects/repo"),
                       "'/my projects/repo'")
    }

    func testQuoteIfNeeded_pathWithApostrophe_quotes() {
        XCTAssertEqual(ClaudeResumeCommandBuilder().shellQuoteIfNeeded("/alex's/repo"),
                       "'/alex'\\''s/repo'")
    }

    func testQuoteIfNeeded_emptyString_quotes() {
        XCTAssertEqual(ClaudeResumeCommandBuilder().shellQuoteIfNeeded(""), "''")
    }

    func testQuoteIfNeeded_codex_bareCommand() {
        XCTAssertEqual(CodexResumeCommandBuilder().shellQuoteIfNeeded("codex"), "codex")
    }

    func testQuoteIfNeeded_dollarSign_quotes() {
        XCTAssertEqual(ClaudeResumeCommandBuilder().shellQuoteIfNeeded("$HOME/bin"), "'$HOME/bin'")
    }

    // MARK: - Claude copy command scenarios

    func testClaude_sessionID_and_cwd() {
        let cmd = claudeCopyCommand(sessionID: "abc-123", binaryPath: "claude", cwd: "/Users/alex/my-repo")
        XCTAssertEqual(cmd, "cd /Users/alex/my-repo && claude --resume abc-123")
    }

    func testClaude_sessionID_no_cwd() {
        let cmd = claudeCopyCommand(sessionID: "abc-123", binaryPath: "claude", cwd: nil)
        XCTAssertEqual(cmd, "claude --resume abc-123")
    }

    func testClaude_no_sessionID_with_cwd() {
        let cmd = claudeCopyCommand(sessionID: nil, binaryPath: "claude", cwd: "/tmp/project")
        XCTAssertEqual(cmd, "cd /tmp/project && claude --continue")
    }

    func testClaude_no_sessionID_no_cwd() {
        let cmd = claudeCopyCommand(sessionID: nil, binaryPath: "claude", cwd: nil)
        XCTAssertEqual(cmd, "claude --continue")
    }

    func testClaude_custom_binary_path() {
        let cmd = claudeCopyCommand(sessionID: "sid", binaryPath: "/opt/homebrew/bin/claude", cwd: nil)
        XCTAssertEqual(cmd, "/opt/homebrew/bin/claude --resume sid")
    }

    func testClaude_cwd_with_spaces() {
        let cmd = claudeCopyCommand(sessionID: "sid", binaryPath: "claude", cwd: "/Users/alex/my project")
        XCTAssertEqual(cmd, "cd '/Users/alex/my project' && claude --resume sid")
    }

    func testClaude_sessionID_with_apostrophe() {
        let cmd = claudeCopyCommand(sessionID: "it's-a-test", binaryPath: "claude", cwd: nil)
        XCTAssertEqual(cmd, "claude --resume 'it'\\''s-a-test'")
    }

    // MARK: - Codex copy command scenarios

    func testCodex_sessionID_and_cwd() {
        let cmd = codexCopyCommand(sessionID: "sess-xyz", binaryOverride: "", cwd: "/repo/project")
        XCTAssertEqual(cmd, "cd /repo/project && codex resume sess-xyz")
    }

    func testCodex_sessionID_no_cwd() {
        let cmd = codexCopyCommand(sessionID: "0ef3d2af-ad6f-4da7-813e-e27e466ed223", binaryOverride: "", cwd: nil)
        XCTAssertEqual(cmd, "codex resume 0ef3d2af-ad6f-4da7-813e-e27e466ed223")
    }

    func testCodex_custom_binary_override() {
        let cmd = codexCopyCommand(sessionID: "sess-xyz", binaryOverride: "/opt/codex", cwd: nil)
        XCTAssertEqual(cmd, "/opt/codex resume sess-xyz")
    }

    func testCodex_cwd_with_spaces() {
        let cmd = codexCopyCommand(sessionID: "sess-xyz", binaryOverride: "", cwd: "/Users/alex/my project")
        XCTAssertEqual(cmd, "cd '/Users/alex/my project' && codex resume sess-xyz")
    }

    // MARK: - Cursor copy command scenarios

    func testCursor_sessionID_and_cwd() {
        let cmd = cursorCopyCommand(sessionID: "178ea7fa-c37b-43e1-a9e6-bfbe996c0c55", binaryPath: "agent", cwd: "/repo/project")
        XCTAssertEqual(cmd, "cd /repo/project && agent --resume 178ea7fa-c37b-43e1-a9e6-bfbe996c0c55")
    }

    func testCursor_sessionID_no_cwd() {
        let cmd = cursorCopyCommand(sessionID: "chat-123", binaryPath: "agent", cwd: nil)
        XCTAssertEqual(cmd, "agent --resume chat-123")
    }

    func testCursor_no_sessionID_uses_continue() {
        let cmd = cursorCopyCommand(sessionID: nil, binaryPath: "agent", cwd: nil)
        XCTAssertEqual(cmd, "agent --continue")
    }

    func testCursor_binaryUsesAgentSubcommand() {
        let cmd = cursorCopyCommand(sessionID: "chat-123", binaryPath: "cursor", cwd: nil)
        XCTAssertEqual(cmd, "cursor agent --resume chat-123")
    }

    func testCursor_autoModePrefersCursorExecutable() {
        let cmd = cursorCopyCommand(sessionID: "chat-123", binaryPath: "", cachedBinaryPath: "cursor", cwd: nil)
        XCTAssertEqual(cmd, "cursor agent --resume chat-123")
    }

    func testCursor_autoModeFallsBackToAgentWhenCacheEmpty() {
        let cmd = cursorCopyCommand(sessionID: "chat-123", binaryPath: "", cachedBinaryPath: nil, cwd: nil)
        XCTAssertEqual(cmd, "agent --resume chat-123")
    }

    // MARK: - Helpers

    /// Replicates the command-building logic used in copyResumeCommand (Claude)
    private func claudeCopyCommand(sessionID: String?, binaryPath: String, cwd: String?) -> String {
        let builder = ClaudeResumeCommandBuilder()
        let binary = binaryPath.isEmpty ? "claude" : binaryPath
        let core: String
        if let id = sessionID, !id.isEmpty {
            core = "\(builder.shellQuoteIfNeeded(binary)) --resume \(builder.shellQuoteIfNeeded(id))"
        } else {
            core = "\(builder.shellQuoteIfNeeded(binary)) --continue"
        }
        if let cwd, !cwd.isEmpty {
            return "cd \(builder.shellQuoteIfNeeded(cwd)) && \(core)"
        }
        return core
    }

    /// Replicates the command-building logic used in copyResumeCommand (Codex)
    private func codexCopyCommand(sessionID: String, binaryOverride: String, cwd: String?) -> String {
        let builder = CodexResumeCommandBuilder()
        let binary = binaryOverride.isEmpty ? "codex" : binaryOverride
        let core = "\(builder.shellQuoteIfNeeded(binary)) resume \(builder.shellQuoteIfNeeded(sessionID))"
        if let cwd, !cwd.isEmpty {
            return "cd \(builder.shellQuoteIfNeeded(cwd)) && \(core)"
        }
        return core
    }

    /// Replicates the command-building logic used in copyResumeCommand (Cursor)
    private func cursorCopyCommand(sessionID: String?,
                                   binaryPath: String,
                                   cachedBinaryPath: String? = nil,
                                   cwd: String?) -> String {
        let builder = CursorResumeCommandBuilder()
        let binary = binaryPath.isEmpty ? (cachedBinaryPath ?? "agent") : binaryPath
        let strategy: CursorResumeCommandBuilder.Strategy = {
            if let id = sessionID, !id.isEmpty {
                return .resumeByID(id: id)
            }
            return .continueMostRecent
        }()
        let core = (try? builder.makeCoreCommand(strategy: strategy, binaryCommand: binary)) ?? ""
        if let cwd, !cwd.isEmpty {
            return "cd \(builder.shellQuoteIfNeeded(cwd)) && \(core)"
        }
        return core
    }
}
