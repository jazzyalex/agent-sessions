import Foundation

/// One agent that has no steward, as recorded in `STEWARDS.md`.
struct StewardAgent: Equatable, Identifiable {
    /// The session source whose transcripts on this Mac prove the user runs it.
    let source: SessionSource

    /// The agent's name **exactly as `STEWARDS.md` spells it**. The signup form
    /// asks for that spelling, and it is not always `source.displayName`:
    /// "Cursor" is "Cursor Agent" there, "Copilot CLI" is "GitHub Copilot CLI".
    let stewardName: String

    var id: String { source.rawValue }
}

/// Decides whether this user is worth asking to steward an agent, and which one.
///
/// The whole point of the ask is that it is targeted: a steward has to run
/// `steward_check.py` against their own sessions two or three times a year, so
/// the only people worth asking are the ones who already have those sessions.
/// The generic "help add your agent" card covers everybody else.
enum StewardAskEligibility {
    /// Sessions of one agent before we believe the user actually runs it rather
    /// than having tried it once. Low on purpose — the check needs transcripts,
    /// not volume — but not one, which a single experiment would clear.
    static let minimumSessions = 3

    /// Agents with no steward **as of this release**, and the names the signup
    /// form expects.
    ///
    /// Compiled in rather than fetched. A shipped build that keeps asking for an
    /// agent someone adopted last week costs one release of mild redundancy; a
    /// network call on the session list to avoid that costs far more. The list
    /// is regenerated from `STEWARDS.md` at release time, and
    /// `StewardAskEligibilityTests` fails the build if the two disagree.
    ///
    /// Codex and Claude Code are absent because the maintainer stewards them.
    /// Droid is absent because it is legacy-only and takes no steward.
    static let stewardlessAgents: [StewardAgent] = [
        StewardAgent(source: .cursor, stewardName: "Cursor Agent"),
        StewardAgent(source: .copilot, stewardName: "GitHub Copilot CLI"),
        StewardAgent(source: .opencode, stewardName: "OpenCode"),
        StewardAgent(source: .antigravity, stewardName: "Antigravity CLI"),
        StewardAgent(source: .pi, stewardName: "Pi"),
        StewardAgent(source: .kimi, stewardName: "Kimi Code"),
        StewardAgent(source: .grok, stewardName: "Grok CLI"),
        StewardAgent(source: .openclaw, stewardName: "OpenClaw"),
        StewardAgent(source: .hermes, stewardName: "Hermes"),
        StewardAgent(source: .qwen, stewardName: "Qwen Code"),
        StewardAgent(source: .devin, stewardName: "Devin CLI"),
        StewardAgent(source: .fx, stewardName: "fx (vercel-labs)")
    ]

    /// The sources worth counting while scanning the index — everything else can
    /// be skipped outright.
    static let stewardlessSources: Set<SessionSource> = Set(stewardlessAgents.map(\.source))

    /// The one agent to ask about, or nil when nothing qualifies.
    ///
    /// Qwen Code jumps the queue whatever the counts say. It is the only
    /// supported agent the maintainer cannot verify at all — the Qwen OAuth free
    /// tier was withdrawn in April 2026, so no current transcript can be
    /// captured on his machine — which makes a Qwen steward worth more than a
    /// steward for any agent that at least has a fallback.
    ///
    /// Otherwise the most-used qualifying agent wins, ties going to whichever
    /// comes first in `stewardlessAgents`. Deterministic on purpose: the pick
    /// must not flip between launches, or the card would ask about a different
    /// agent every time the index reloaded.
    static func target(sessionCounts: [SessionSource: Int]) -> StewardAgent? {
        let qualified = stewardlessAgents.filter { (sessionCounts[$0.source] ?? 0) >= minimumSessions }
        guard var best = qualified.first else { return nil }
        if let qwen = qualified.first(where: { $0.source == .qwen }) { return qwen }

        var bestCount = sessionCounts[best.source] ?? 0
        for candidate in qualified.dropFirst() {
            let count = sessionCounts[candidate.source] ?? 0
            guard count > bestCount else { continue }
            best = candidate
            bestCount = count
        }
        return best
    }

    /// Counts the sessions of every stewardless agent in one pass.
    static func sessionCounts(in sources: some Sequence<SessionSource>) -> [SessionSource: Int] {
        var counts: [SessionSource: Int] = [:]
        for source in sources where stewardlessSources.contains(source) {
            counts[source, default: 0] += 1
        }
        return counts
    }
}
