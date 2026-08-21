import XCTest
@testable import AgentSessions

/// Who the steward ask may name, and which one it picks.
///
/// The list of unstewarded agents is compiled into the app, so the failure mode
/// that matters is drift: a build that keeps asking for an agent somebody already
/// adopted, or that never asks for one that needs adopting. `STEWARDS.md` is the
/// record, so the last test here reads it.
final class StewardAskEligibilityTests: XCTestCase {
    private func counts(_ pairs: [SessionSource: Int]) -> [SessionSource: Int] { pairs }

    // MARK: - The usage bar

    func testThreeSessionsQualifies() {
        let target = StewardAskEligibility.target(sessionCounts: counts([.kimi: 3]))
        XCTAssertEqual(target?.source, .kimi)
    }

    func testTwoSessionsIsNotEnough() {
        XCTAssertNil(StewardAskEligibility.target(sessionCounts: counts([.kimi: 2])))
    }

    func testNoSessionsAtAllMeansNoAsk() {
        XCTAssertNil(StewardAskEligibility.target(sessionCounts: [:]))
    }

    func testMinimumIsPinned() {
        XCTAssertEqual(StewardAskEligibility.minimumSessions, 3)
    }

    /// The maintainer stewards these two himself; asking a user to adopt them
    /// would be asking for a job that is already taken.
    func testCodexAndClaudeAreNeverAskedAbout() {
        XCTAssertNil(StewardAskEligibility.target(sessionCounts: counts([.codex: 500, .claude: 500])))
    }

    /// Droid is legacy-only: existing sessions still read, but it is out of the
    /// active format checks, so there is no check for a steward to run.
    func testDroidIsNeverAskedAbout() {
        XCTAssertNil(StewardAskEligibility.target(sessionCounts: counts([.droid: 200])))
    }

    // MARK: - Which one gets picked

    func testMostUsedAgentWins() {
        let target = StewardAskEligibility.target(sessionCounts: counts([.kimi: 4, .grok: 40, .pi: 9]))
        XCTAssertEqual(target?.source, .grok)
    }

    /// Qwen is the one agent the maintainer cannot verify at all, so it takes the
    /// ask even against an agent the user runs far more.
    func testQwenJumpsTheQueue() {
        let target = StewardAskEligibility.target(sessionCounts: counts([.cursor: 900, .qwen: 3]))
        XCTAssertEqual(target?.source, .qwen)
    }

    /// ...but only when it clears the same bar as everyone else.
    func testQwenBelowTheBarDoesNotJump() {
        let target = StewardAskEligibility.target(sessionCounts: counts([.cursor: 900, .qwen: 2]))
        XCTAssertEqual(target?.source, .cursor)
    }

    /// The card must name the same agent on every launch. A tie broken by
    /// dictionary order would rename it each time the index reloaded.
    func testTiesAreBrokenDeterministically() {
        let tied = counts([.hermes: 7, .pi: 7, .opencode: 7])
        let first = StewardAskEligibility.target(sessionCounts: tied)
        XCTAssertNotNil(first)
        for _ in 0..<50 {
            XCTAssertEqual(StewardAskEligibility.target(sessionCounts: tied)?.source, first?.source)
        }
    }

    func testSessionCountsIgnoreStewardedAndUnsupportedSources() {
        let tallied = StewardAskEligibility.sessionCounts(in: [
            .codex, .codex, .claude, .droid, .qwen, .qwen, .grok
        ])
        XCTAssertEqual(tallied, [.qwen: 2, .grok: 1])
    }

    // MARK: - The signup link

    /// The form asks for the name "as it appears in STEWARDS.md", so the prefill
    /// has to use that spelling — which is not always the app's display name.
    func testSignupURLPrefillsTheAgentField() throws {
        let agent = try XCTUnwrap(StewardAskEligibility.stewardlessAgents.first { $0.source == .qwen })
        let url = OnboardingCoordinator.stewardSignupURL(for: agent)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("/issues/new"), "got \(url.path)")
        XCTAssertEqual(items.first { $0.name == "template" }?.value, "steward-signup.yml")
        XCTAssertEqual(items.first { $0.name == "agent" }?.value, "Qwen Code")
    }

    /// Names with spaces must survive as query values rather than breaking the URL.
    func testSignupURLEscapesMultiWordNames() throws {
        let agent = try XCTUnwrap(StewardAskEligibility.stewardlessAgents.first { $0.source == .copilot })
        let url = OnboardingCoordinator.stewardSignupURL(for: agent)
        XCTAssertFalse(url.absoluteString.contains(" "))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "agent" }?.value, "GitHub Copilot CLI")
    }

    /// Nothing about the user's machine may travel in the URL — it opens a public
    /// issue form. Only the agent name and the template are allowed.
    func testSignupURLCarriesNothingButTheAgentAndTemplate() throws {
        for agent in StewardAskEligibility.stewardlessAgents {
            let url = OnboardingCoordinator.stewardSignupURL(for: agent)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(Set(items.map(\.name)), ["template", "agent"], "for \(agent.stewardName)")
        }
    }

    // MARK: - Drift against STEWARDS.md

    /// The compiled list against the record it is copied from.
    ///
    /// This is the test that earns the hardcoded list: a signup that updates
    /// `STEWARDS.md` and forgets the app now fails here rather than shipping a
    /// build that asks strangers to adopt an agent someone already owns.
    func testCompiledListMatchesStewardsMarkdown() throws {
        let wanted = try stewardWantedNamesFromMarkdown()
        XCTAssertFalse(wanted.isEmpty, "parsed no rows from STEWARDS.md — the table shape changed")
        XCTAssertEqual(
            Set(StewardAskEligibility.stewardlessAgents.map(\.stewardName)),
            wanted,
            "StewardAskEligibility.stewardlessAgents has drifted from the STEWARDS.md table"
        )
    }

    /// Names in `stewardlessAgents` are the prefill values, so a typo there would
    /// silently submit a form naming an agent that does not exist.
    func testEveryCompiledNameAppearsInTheMarkdownTable() throws {
        let allRows = try stewardTableRows()
        let names = Set(allRows.map(\.agent))
        for agent in StewardAskEligibility.stewardlessAgents {
            XCTAssertTrue(names.contains(agent.stewardName), "\(agent.stewardName) is not a STEWARDS.md row")
        }
    }

    func testNoDuplicateSources() {
        let sources = StewardAskEligibility.stewardlessAgents.map(\.source)
        XCTAssertEqual(sources.count, Set(sources).count)
    }

    // MARK: - Markdown parsing

    private func stewardTableRows(file: StaticString = #filePath) throws -> [(agent: String, steward: String)] {
        let url = FixturePaths.repoRootURL(file: file).appendingPathComponent("STEWARDS.md")
        let markdown = try String(contentsOf: url, encoding: .utf8)

        return markdown.split(separator: "\n").compactMap { line -> (String, String)? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            let cells = trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // "| Agent | Steward | Last verified | Tier |" plus its `|---|` rule.
            guard cells.count == 4, cells[0] != "Agent", !cells[0].hasPrefix("---") else { return nil }
            return (cells[0], cells[1])
        }
    }

    private func stewardWantedNamesFromMarkdown(file: StaticString = #filePath) throws -> Set<String> {
        Set(try stewardTableRows(file: file).filter { $0.steward == "steward wanted" }.map(\.agent))
    }
}
