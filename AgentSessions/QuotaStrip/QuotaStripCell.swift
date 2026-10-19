import Foundation

/// What one strip wing shows for a provider. Pure: compiled into the app and the
/// hostless logic-test target.
struct StripCellInput {
    enum State { case live, needsAction, probing, idle, limited, retrying }

    var state: State
    var fiveHourLeft: Int?
    var weekLeft: Int?
    var projectedRunout: Date?
    var fiveHourResetAt: Date?
    var now: Date
    /// `UsageDisplayMode.used`: show the used percent. Choice and tone still follow what is left.
    var showsUsed = false
    /// `usageLimitCockpitProjectionEnabled`: the run-out chip is optional.
    var showsProjection = true
}

struct StripCell: Equatable {
    enum Tone { case healthy, warning, critical, muted }

    let text: String
    /// "wk" when the shown window is the weekly one.
    let tag: String?
    let tone: Tone
    /// Run-out chip, e.g. "▸2h".
    let chip: String?
    /// The provider runs out before its 5h window resets.
    let chipWarns: Bool
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
            return StripCell(text: "∞", tag: nil, tone: .muted, chip: nil, chipWarns: false)
        }

        var chip: String?
        var chipWarns = false
        if input.showsProjection, let runout = input.projectedRunout, runout > input.now {
            let minutes = Int(runout.timeIntervalSince(input.now) / 60)
            chip = minutes < 60 ? "▸\(minutes)m" : "▸\(minutes / 60)h"
            if let reset = input.fiveHourResetAt { chipWarns = runout < reset }
        }
        let shownPercent = input.showsUsed ? 100 - shown.left : shown.left
        return StripCell(text: "\(shownPercent)%", tag: shown.weekly ? "wk" : nil, tone: tone(shown.left),
                         chip: chip, chipWarns: chipWarns)
    }

    static func tone(_ left: Int) -> StripCell.Tone {
        if left <= 10 { return .critical }
        if left < 30 { return .warning }
        return .healthy
    }

    private static func word(_ text: String) -> StripCell {
        StripCell(text: text, tag: nil, tone: .muted, chip: nil, chipWarns: false)
    }
}
