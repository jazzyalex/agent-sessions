import XCTest
@testable import AgentSessions

/// K1/K2: every persisted key keeps its historical string forever. A failure here means
/// users' per-source preferences would silently reset on upgrade.
final class SessionSourceKeyStabilityTests: XCTestCase {
    // One row per source: (source, enablement, cliAvailable, rootOverrides, include)
    private let table: [(SessionSource, String, String?, [String], String)] = [
        (.codex, "AgentEnabledCodex", "CodexCLIAvailable", ["SessionsRootOverride"], "IncludeCodexSessions"),
        (.claude, "AgentEnabledClaude", "ClaudeCLIAvailable", ["ClaudeSessionsRootOverride"], "IncludeClaudeSessions"),
        (.antigravity, "AgentEnabledAntigravity", "AntigravityCLIAvailable", ["AntigravitySessionsRootOverride"], "IncludeAntigravitySessions"),
        (.opencode, "AgentEnabledOpenCode", "OpenCodeCLIAvailable", ["OpenCodeSessionsRootOverride"], "IncludeOpenCodeSessions"),
        (.hermes, "AgentEnabledHermes", "HermesCLIAvailable", ["HermesSessionsRootOverride"], "IncludeHermesSessions"),
        (.copilot, "AgentEnabledCopilot", "CopilotCLIAvailable", ["CopilotSessionsRootOverride"], "IncludeCopilotSessions"),
        (.droid, "AgentEnabledDroid", "DroidCLIAvailable", ["DroidSessionsRootOverride", "DroidProjectsRootOverride"], "IncludeDroidSessions"),
        (.openclaw, "AgentEnabledOpenClaw", nil, ["OpenClawSessionsRootOverride"], "IncludeOpenClawSessions"),
        (.cursor, "AgentEnabledCursor", "CursorCLIAvailable", ["CursorSessionsRootOverride"], "IncludeCursorSessions"),
        (.pi, "AgentEnabledPi", "PiCLIAvailable", ["PiSessionsRootOverride"], "IncludePiSessions"),
        (.kimi, "AgentEnabledKimi", "KimiCLIAvailable", ["KimiSessionsRootOverride"], "IncludeKimiSessions"),
        (.grok, "AgentEnabledGrok", "GrokCLIAvailable", ["GrokSessionsRootOverride"], "IncludeGrokSessions"),
    ]

    func testEverySourceKeyKeepsItsHistoricalString() {
        XCTAssertEqual(table.map(\.0), SessionSource.allCases, "table must cover every source, in order")
        for (source, enablement, _, _, _) in table {
            XCTAssertEqual(AgentEnablement.enablementKey(for: source), enablement, "\(source)")
        }

        // Include constants frozen DIRECTLY — no production key(for:) mapping exists or
        // may be added (it would be a new permanent 12-arm shared switch, violating K2's
        // "new keys stay source-local"). One assertion per constant:
        XCTAssertEqual(PreferencesKey.Include.codex, "IncludeCodexSessions")
        XCTAssertEqual(PreferencesKey.Include.claude, "IncludeClaudeSessions")
        XCTAssertEqual(PreferencesKey.Include.antigravity, "IncludeAntigravitySessions")
        XCTAssertEqual(PreferencesKey.Include.opencode, "IncludeOpenCodeSessions")
        XCTAssertEqual(PreferencesKey.Include.hermes, "IncludeHermesSessions")
        XCTAssertEqual(PreferencesKey.Include.copilot, "IncludeCopilotSessions")
        XCTAssertEqual(PreferencesKey.Include.droid, "IncludeDroidSessions")
        XCTAssertEqual(PreferencesKey.Include.openclaw, "IncludeOpenClawSessions")
        XCTAssertEqual(PreferencesKey.Include.cursor, "IncludeCursorSessions")
        XCTAssertEqual(PreferencesKey.Include.pi, "IncludePiSessions")
        XCTAssertEqual(PreferencesKey.Include.kimi, "IncludeKimiSessions")
        XCTAssertEqual(PreferencesKey.Include.grok, "IncludeGrokSessions")

        // Root-override constants asserted individually the same way (Droid has two —
        // sessions root and projects root, both frozen).
        XCTAssertEqual(PreferencesKey.Paths.codexSessionsRootOverride, "SessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.claudeSessionsRootOverride, "ClaudeSessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.antigravitySessionsRootOverride, "AntigravitySessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.opencodeSessionsRootOverride, "OpenCodeSessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.hermesSessionsRootOverride, "HermesSessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.copilotSessionsRootOverride, "CopilotSessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.droidSessionsRootOverride, "DroidSessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.droidProjectsRootOverride, "DroidProjectsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.openClawSessionsRootOverride, "OpenClawSessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.cursorSessionsRootOverride, "CursorSessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.piSessionsRootOverride, "PiSessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.kimiSessionsRootOverride, "KimiSessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.grokSessionsRootOverride, "GrokSessionsRootOverride")

        // CLI-availability constants, one line per constant. OpenClaw has none — it is
        // never probed as a CLI binary, so `storedBinaryPresence` returns nil for it and
        // no `PreferencesKey.openclawCLIAvailable` constant exists.
        XCTAssertEqual(PreferencesKey.codexCLIAvailable, "CodexCLIAvailable")
        XCTAssertEqual(PreferencesKey.claudeCLIAvailable, "ClaudeCLIAvailable")
        XCTAssertEqual(PreferencesKey.antigravityCLIAvailable, "AntigravityCLIAvailable")
        XCTAssertEqual(PreferencesKey.openCodeCLIAvailable, "OpenCodeCLIAvailable")
        XCTAssertEqual(PreferencesKey.hermesCLIAvailable, "HermesCLIAvailable")
        XCTAssertEqual(PreferencesKey.copilotCLIAvailable, "CopilotCLIAvailable")
        XCTAssertEqual(PreferencesKey.droidCLIAvailable, "DroidCLIAvailable")
        XCTAssertEqual(PreferencesKey.cursorCLIAvailable, "CursorCLIAvailable")
        XCTAssertEqual(PreferencesKey.piCLIAvailable, "PiCLIAvailable")
        XCTAssertEqual(PreferencesKey.kimiCLIAvailable, "KimiCLIAvailable")
        XCTAssertEqual(PreferencesKey.grokCLIAvailable, "GrokCLIAvailable")

        // `SourceKeyTable.include` is a second copy of this file's `table` column, kept
        // separate so later tasks' tests can reuse it without re-deriving the table. Pin
        // the two together so the shared fixture cannot drift away from the frozen rows
        // above (Task 1 review finding).
        XCTAssertEqual(SourceKeyTable.include,
                       Dictionary(uniqueKeysWithValues: table.map { ($0.0, $0.4) }))
    }

    /// The table's `cliAvailable` column is nil for exactly OpenClaw (SPEC §10.2): it's
    /// the only source with no persisted CLI-detection flag. A 13th source adds one row
    /// to `table` above; if it also has no CLI probe, add it here too.
    func testOpenClawIsTheOnlySourceWithoutACLIAvailabilityKey() {
        let sourcesWithoutCLIAvailable = table.filter { $0.2 == nil }.map(\.0)
        XCTAssertEqual(sourcesWithoutCLIAvailable, [.openclaw])
    }
}

/// Shared source→key fixture. Frozen independently of `PreferencesKey` (literal
/// strings, not references) so a silent change to a production constant shows up here
/// as a mismatch rather than being carried along invisibly. Exposed at file scope
/// (internal) so later Session Source Registry tasks' tests in this target can reuse
/// it instead of re-deriving the table.
enum SourceKeyTable {
    static let include: [SessionSource: String] = [
        .codex: "IncludeCodexSessions",
        .claude: "IncludeClaudeSessions",
        .antigravity: "IncludeAntigravitySessions",
        .opencode: "IncludeOpenCodeSessions",
        .hermes: "IncludeHermesSessions",
        .copilot: "IncludeCopilotSessions",
        .droid: "IncludeDroidSessions",
        .openclaw: "IncludeOpenClawSessions",
        .cursor: "IncludeCursorSessions",
        .pi: "IncludePiSessions",
        .kimi: "IncludeKimiSessions",
        .grok: "IncludeGrokSessions",
    ]
}
