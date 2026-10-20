import Foundation

/// Which buttons the one-time notch intro dialog offers.
enum NotchIntroVariant: Equatable {
    /// Tracking on, the Quota Meter on the desktop: Move to Notch · Keep on Desktop.
    case moveToNotch
    /// Tracking on, placement already puts it in the notch but the notch is hidden from the
    /// View menu: Move to Notch · Not Now. Nothing is on the desktop, so no "Keep on Desktop".
    case unhideNotch
    /// Tracking on, the Quota Meter already in the notch and visible: Got It.
    case alreadyInNotch
    /// Tracking off for every provider the user has sessions for: Turn On · Not Now.
    case turnOnTracking
}

/// Everything the intro decision reads. Gathered by the session-list pane, which owns the
/// session audience; kept as plain values so the rule is testable without the app.
struct NotchIntroInput: Equatable {
    var alreadyShown: Bool
    var audienceReady: Bool
    var hasCodex: Bool
    var hasClaude: Bool
    var codexTracking: Bool
    var claudeTracking: Bool
    var resolvesToNotch: Bool
    /// The notch is hidden from the View menu, so "already in the notch" would point at
    /// nothing; Move to Notch shows it again.
    var notchHidden: Bool
    /// The fresh-install setup window or the What's New panel is on screen.
    var blockingSurfaceOpen: Bool
    /// The session-list Quota Meter card was chosen this launch.
    var quotaMeterCardOnScreen: Bool
}

/// What the launch does with the intro at one evaluation.
enum NotchIntroDecision: Equatable {
    case show(NotchIntroVariant)
    /// Not yet: evaluate again on the next trigger.
    case wait
    /// Decided for this launch: no more evaluations, so the dialog never interrupts work later.
    case settle
}

/// The one-time notch intro: who sees it and with which buttons. Spec:
/// docs/superpowers/specs/2026-10-12-quota-meter-notch-design.md, "Notch intro".
enum QuotaMeterNotchIntro {
    /// Set the moment the dialog appears, and by any user placement change before it.
    static let shownKey = "QuotaMeterNotchIntroShown"

    /// How long after the audience is first ready, with nothing blocking, late-arriving Codex
    /// or Claude sessions may still bring the dialog up. After that it would interrupt work.
    static let lateSessionWindow: TimeInterval = 60

    /// `secondsSinceAudienceReady` counts from the first evaluation that had a ready audience
    /// and no blocking surface (nil before that), so a long setup window does not use it up.
    static func decision(for input: NotchIntroInput, secondsSinceAudienceReady: TimeInterval?) -> NotchIntroDecision {
        if input.alreadyShown || input.quotaMeterCardOnScreen { return .settle }
        guard input.audienceReady, !input.blockingSurfaceOpen, let elapsed = secondsSinceAudienceReady else {
            return .wait
        }
        guard elapsed <= lateSessionWindow else { return .settle }
        if let variant = variant(for: input) { return .show(variant) }
        return .wait
    }

    /// nil means "not now": either never (already shown, no Codex or Claude sessions) or not
    /// yet (audience unknown, another surface on screen, the Quota Meter card holds the launch).
    static func variant(for input: NotchIntroInput) -> NotchIntroVariant? {
        guard !input.alreadyShown, input.audienceReady, !input.blockingSurfaceOpen,
              !input.quotaMeterCardOnScreen, input.hasCodex || input.hasClaude else { return nil }
        let everyProviderUntracked = (!input.hasCodex || !input.codexTracking)
            && (!input.hasClaude || !input.claudeTracking)
        if everyProviderUntracked { return .turnOnTracking }
        guard input.resolvesToNotch else { return .moveToNotch }
        return input.notchHidden ? .unhideNotch : .alreadyInNotch
    }
}
