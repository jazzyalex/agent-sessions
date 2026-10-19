import Foundation

/// What one strip wing shows for a provider. Pure: compiled into the app and the
/// hostless logic-test target.
struct StripCellInput {
    enum State { case live, needsAction, probing, idle, limited, retrying }

    var state: State
    var fiveHourLeft: Int?
    var weekLeft: Int?
    /// The 5h run-out label from the panel's formatter (`formatUsageProjectionLabel`), which
    /// already drops a projection older than 3 minutes; nil when there is none.
    var projection: String?
    /// `UsageDisplayMode.used`: show the used percent. Choice and tone still follow what is left.
    var showsUsed = false
    /// `usageLimitCockpitProjectionEnabled`: the run-out chip is optional.
    var showsProjection = true
    /// Sessions of this provider that are working right now.
    var workingSessions = 0
    /// Sessions of this provider that finished a turn recently and have not started again:
    /// the user's turn.
    var finishedSessions = 0
    /// Tag for "∞" when the wing is bound to one window that the provider does not have
    /// (one provider filling both wings), so it never shows a bare "∞".
    var emptyTag: String?
}

struct StripCell: Equatable {
    enum Tone { case healthy, warning, critical, muted }

    /// One agent-level mark per wing (owner 2026-10-19): session detail lives in the panel.
    enum Activity: Equatable {
        case none
        /// At least one session of this agent is working.
        case working
        /// A session finished recently and waits for the user; wins over `working`.
        case yourTurn
    }

    let text: String
    /// "5h" or "wk": which window the number is (owner 2026-10-19: both are tagged).
    let tag: String?
    let tone: Tone
    /// 5h run-out chip, e.g. "▸2h"; only beside a 5h number.
    let chip: String?
    /// Agent activity; only beside a number.
    var activity: Activity = .none
    /// The shown percent as 0...1 (left, or used in `UsageDisplayMode.used`), for the Minimal
    /// hairline; nil when the cell is not a number.
    var fillFraction: Double?
}

enum QuotaStripCellBuilder {
    static func cell(_ input: StripCellInput) -> StripCell {
        switch input.state {
        case .needsAction: return word(String(localized: "Sign in", comment: "Menu bar strip wing: provider needs sign-in."))
        case .probing: return word(String(localized: "Probing", comment: "Menu bar strip wing: a usage probe is running."))
        case .idle: return word(String(localized: "Idle", comment: "Menu bar strip wing: provider has no active session."))
        case .limited: return word(String(localized: "Limited", comment: "Menu bar strip wing: provider is rate limited."))
        case .retrying: return word(String(localized: "Retrying", comment: "Menu bar strip wing: provider is reconnecting."))
        case .live: break
        }

        let candidates: [(left: Int, weekly: Bool)] =
            [input.fiveHourLeft.map { ($0, false) }, input.weekLeft.map { ($0, true) }].compactMap { $0 }
        guard let shown = candidates.min(by: { $0.left < $1.left }) else {
            return StripCell(text: "∞", tag: input.emptyTag, tone: .muted, chip: nil)
        }

        // The chip is the 5h run-out; beside a weekly number it would read as the week's.
        let chip = input.showsProjection && !shown.weekly ? input.projection.map(compactChip) : nil
        let shownPercent = input.showsUsed ? 100 - shown.left : shown.left
        // Tone follows what is left only: the projection tracker publishes run-outs that fall
        // before the reset, so a "will run out" colour would be on nearly all the time.
        return StripCell(text: "\(shownPercent)%", tag: shown.weekly ? "wk" : "5h",
                         tone: tone(shown.left), chip: chip,
                         activity: input.finishedSessions > 0 ? .yourTurn
                             : input.workingSessions > 0 ? .working : .none,
                         fillFraction: Double(min(100, max(0, shownPercent))) / 100)
    }

    /// The panel's label cut to its leading unit for the narrow wing: "▸2h 5m" → "▸2h".
    static func compactChip(_ label: String) -> String {
        label.split(separator: " ", maxSplits: 1).first.map(String.init) ?? label
    }

    static func tone(_ left: Int) -> StripCell.Tone {
        if left <= 10 { return .critical }
        if left < 30 { return .warning }
        return .healthy
    }

    private static func word(_ text: String) -> StripCell {
        StripCell(text: text, tag: nil, tone: .muted, chip: nil)
    }
}
