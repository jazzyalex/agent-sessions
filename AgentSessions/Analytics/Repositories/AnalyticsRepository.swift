import Foundation

/// Repository for fast analytics queries backed by IndexDB rollups.
actor AnalyticsRepository {
    private let db: IndexDB

    init(db: IndexDB) { self.db = db }

    func isReady() async -> Bool {
        // Consider ready when DB is not empty
        (try? await db.isEmpty()) == false
    }

    struct Summary {
        let sessionsDistinct: Int
        let messages: Int
        let commands: Int
        let durationSeconds: TimeInterval
    }

    /// Aggregate summary for given sources between inclusive day bounds (YYYY-MM-DD local).
    func summary(sources: [String], dayStart: String?, dayEnd: String?) async -> Summary {
        // Respect message-count filters for sessions/messages totals
        let d = UserDefaults.standard
        let hideZero = d.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
        let hideLow  = d.object(forKey: "HideLowMessageSessions") as? Bool ?? true

        if hideZero || hideLow {
            let sessions = (try? await db.countDistinctSessionsFiltered(sources: sources, dayStart: dayStart, dayEnd: dayEnd, hideZero: hideZero, hideLow: hideLow)) ?? 0
            let messages = (try? await db.sumMessagesFiltered(sources: sources, dayStart: dayStart, dayEnd: dayEnd, hideZero: hideZero, hideLow: hideLow)) ?? 0
            let commands = (try? await db.sumCommandsFiltered(sources: sources, dayStart: dayStart, dayEnd: dayEnd, hideZero: hideZero, hideLow: hideLow)) ?? 0
            let duration = (try? await db.sumDurationFiltered(sources: sources, dayStart: dayStart, dayEnd: dayEnd, hideZero: hideZero, hideLow: hideLow)) ?? 0.0
            return Summary(sessionsDistinct: sessions, messages: messages, commands: commands, durationSeconds: duration)
        } else {
            let sessions = (try? await db.countDistinctSessions(sources: sources, dayStart: dayStart, dayEnd: dayEnd)) ?? 0
            let roll = (try? await db.sumRollups(sources: sources, dayStart: dayStart, dayEnd: dayEnd)) ?? (0, 0, 0.0)
            return Summary(sessionsDistinct: sessions, messages: roll.0, commands: roll.1, durationSeconds: roll.2)
        }
    }

    struct AgentSlice {
        let source: String
        let sessionsDistinct: Int
        let messages: Int
        let durationSeconds: TimeInterval
    }

    /// Breakdown by source across bounds.
    func breakdownByAgent(sources: [String], dayStart: String?, dayEnd: String?) async -> [AgentSlice] {
        let distinct = (try? await db.distinctSessionsBySource(sources: sources, dayStart: dayStart, dayEnd: dayEnd)) ?? [:]
        let dur = (try? await db.durationBySource(sources: sources, dayStart: dayStart, dayEnd: dayEnd)) ?? [:]
        let messages = (try? await db.messagesBySource(sources: sources, dayStart: dayStart, dayEnd: dayEnd)) ?? [:]
        var out: [AgentSlice] = []
        let keys = Set(distinct.keys).union(dur.keys).union(messages.keys)
        for k in keys {
            out.append(AgentSlice(source: k,
                                  sessionsDistinct: distinct[k] ?? 0,
                                  messages: messages[k] ?? 0,
                                  durationSeconds: dur[k] ?? 0))
        }
        return out
    }

    /// Average session duration for given sources between inclusive day bounds.
    /// Respects HideZeroMessageSessions / HideLowMessageSessions preferences so analytics
    /// matches the Sessions list filtering policy.
    func avgSessionLength(sources: [String], dayStart: String?, dayEnd: String?) async -> TimeInterval {
        let d = UserDefaults.standard
        let hideZero = d.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
        let hideLow  = d.object(forKey: "HideLowMessageSessions") as? Bool ?? true
        if hideZero || hideLow {
            return (try? await db.avgSessionDurationFiltered(sources: sources, dayStart: dayStart, dayEnd: dayEnd, hideZero: hideZero, hideLow: hideLow)) ?? 0
        } else {
            return (try? await db.avgSessionDuration(sources: sources, dayStart: dayStart, dayEnd: dayEnd)) ?? 0
        }
    }
}
