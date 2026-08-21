import XCTest
@testable import AgentSessions

/// K1/K2: every persisted key keeps its historical string forever. A failure here means
/// users' per-source preferences would silently reset on upgrade.
final class SessionSourceKeyStabilityTests: XCTestCase {
    func testEverySourceKeyKeepsItsHistoricalString() {
        XCTAssertEqual(SourceKeyTable.rows.map(\.source), SessionSource.allCases,
                       "table must cover every source, in order")
        for row in SourceKeyTable.rows {
            let descriptor = SessionSourceRegistry.descriptor(for: row.source)
            XCTAssertEqual(descriptor.enablementKey, row.enablement, "\(row.source)")
            XCTAssertEqual(descriptor.cliAvailableKey, row.cliAvailable, "\(row.source)")
            XCTAssertEqual(descriptor.rootOverrideKeys, row.rootOverrides, "\(row.source)")
            XCTAssertEqual(descriptor.includeKey, row.include, "\(row.source)")
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
        XCTAssertEqual(QwenPreferencesKey.includeSessions, "IncludeQwenSessions")
        XCTAssertEqual(FxPreferencesKey.includeSessions, "IncludeFxSessions")

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
        XCTAssertEqual(QwenPreferencesKey.sessionsRootOverride, "QwenSessionsRootOverride")
        XCTAssertEqual(FxPreferencesKey.sessionsRootOverride, "FxSessionsRootOverride")

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
        XCTAssertEqual(QwenPreferencesKey.cliAvailable, "QwenCLIAvailable")
        XCTAssertEqual(QwenPreferencesKey.enabled, "AgentEnabledQwen")
        XCTAssertEqual(FxPreferencesKey.cliAvailable, "FxCLIAvailable")
        XCTAssertEqual(FxPreferencesKey.enabled, "AgentEnabledFx")

        // The shared include lookup must cover the same complete frozen row table.
        XCTAssertEqual(SourceKeyTable.include.count, SessionSource.allCases.count)
    }

    /// The table's `cliAvailable` column is nil for exactly OpenClaw (SPEC §10.2): it's
    /// the only source with no persisted CLI-detection flag. A 13th source adds one row
    /// to `SourceKeyTable.rows`; if it also has no CLI probe, add it here too.
    func testOpenClawIsTheOnlySourceWithoutACLIAvailabilityKey() {
        let sourcesWithoutCLIAvailable = SourceKeyTable.rows.filter { $0.cliAvailable == nil }.map(\.source)
        XCTAssertEqual(sourcesWithoutCLIAvailable, [.openclaw])
    }
}

/// Shared source→key fixture. Frozen independently of `PreferencesKey` (literal
/// strings, not references) so a silent change to a production constant shows up here
/// as a mismatch rather than being carried along invisibly. Exposed at file scope
/// (internal) so later Session Source Registry tasks' tests in this target can reuse
/// it instead of re-deriving the table.
enum SourceKeyTable {
    struct Row {
        let source: SessionSource
        let enablement: String
        let cliAvailable: String?
        let rootOverrides: [String]
        let include: String
    }

    static let rows: [Row] = [
        Row(source: .codex, enablement: "AgentEnabledCodex", cliAvailable: "CodexCLIAvailable", rootOverrides: ["SessionsRootOverride"], include: "IncludeCodexSessions"),
        Row(source: .claude, enablement: "AgentEnabledClaude", cliAvailable: "ClaudeCLIAvailable", rootOverrides: ["ClaudeSessionsRootOverride"], include: "IncludeClaudeSessions"),
        Row(source: .antigravity, enablement: "AgentEnabledAntigravity", cliAvailable: "AntigravityCLIAvailable", rootOverrides: ["AntigravitySessionsRootOverride"], include: "IncludeAntigravitySessions"),
        Row(source: .opencode, enablement: "AgentEnabledOpenCode", cliAvailable: "OpenCodeCLIAvailable", rootOverrides: ["OpenCodeSessionsRootOverride"], include: "IncludeOpenCodeSessions"),
        Row(source: .hermes, enablement: "AgentEnabledHermes", cliAvailable: "HermesCLIAvailable", rootOverrides: ["HermesSessionsRootOverride"], include: "IncludeHermesSessions"),
        Row(source: .copilot, enablement: "AgentEnabledCopilot", cliAvailable: "CopilotCLIAvailable", rootOverrides: ["CopilotSessionsRootOverride"], include: "IncludeCopilotSessions"),
        Row(source: .droid, enablement: "AgentEnabledDroid", cliAvailable: "DroidCLIAvailable", rootOverrides: ["DroidSessionsRootOverride", "DroidProjectsRootOverride"], include: "IncludeDroidSessions"),
        Row(source: .openclaw, enablement: "AgentEnabledOpenClaw", cliAvailable: nil, rootOverrides: ["OpenClawSessionsRootOverride"], include: "IncludeOpenClawSessions"),
        Row(source: .cursor, enablement: "AgentEnabledCursor", cliAvailable: "CursorCLIAvailable", rootOverrides: ["CursorSessionsRootOverride"], include: "IncludeCursorSessions"),
        Row(source: .pi, enablement: "AgentEnabledPi", cliAvailable: "PiCLIAvailable", rootOverrides: ["PiSessionsRootOverride"], include: "IncludePiSessions"),
        Row(source: .kimi, enablement: "AgentEnabledKimi", cliAvailable: "KimiCLIAvailable", rootOverrides: ["KimiSessionsRootOverride"], include: "IncludeKimiSessions"),
        Row(source: .grok, enablement: "AgentEnabledGrok", cliAvailable: "GrokCLIAvailable", rootOverrides: ["GrokSessionsRootOverride"], include: "IncludeGrokSessions"),
        Row(source: .qwen, enablement: "AgentEnabledQwen", cliAvailable: "QwenCLIAvailable", rootOverrides: ["QwenSessionsRootOverride"], include: "IncludeQwenSessions"),
        Row(source: .fx, enablement: "AgentEnabledFx", cliAvailable: "FxCLIAvailable", rootOverrides: ["FxSessionsRootOverride"], include: "IncludeFxSessions"),
    ]

    static let include = Dictionary(uniqueKeysWithValues: rows.map { ($0.source, $0.include) })

    static func row(for source: SessionSource) -> Row? {
        rows.first { $0.source == source }
    }
}
