import Foundation
import SwiftUI
import AppKit

// MARK: - SessionSourceAppearance
//
// App-only palette and toolbar data for a source, split out of `SessionSourceDescriptor`
// so the descriptor stays UI-free and compiles into the shared Linux core. Each source
// declares its appearance on its `SessionSourceAdapter`, next to its runtime factory.

// MARK: - BrandHue

/// How a source's brand accent is produced by `TranscriptColorSystem.agentBrandAccent(source:)`.
///
/// The distinction is load-bearing (K6): ten sources use a hand-tuned, light-calibrated RGB
/// triple that gets wrapped in `adaptiveBrand(_:)` (light value preserved, dark mode gets a
/// brightened/desaturated variant); two sources (antigravity, opencode) pass an AppKit
/// *system dynamic* color straight through, because system colors already adapt.
enum BrandHue {
    /// A system dynamic `NSColor` (e.g. `.systemTeal`), returned unwrapped.
    case system(NSColor)
    /// A light-mode-calibrated RGB triple. Reconstituting the real `NSColor` means passing
    /// it through `TranscriptColorSystem.adaptiveBrand(NSColor(calibratedRed:green:blue:alpha:))`
    /// exactly as the live switch does — see `SessionSourceRegistry.resolvedBrandAccent(for:)`.
    case calibrated(red: CGFloat, green: CGFloat, blue: CGFloat)
}

// MARK: - PillSpec

/// The toolbar "other agent" pill (K10). Codex and Claude are excluded: they always render
/// as fixed segmented pills, never through this path.
///
/// `shortcut` is frozen history, not derivable — ⌘3–⌘9 were allocated in toolbar order and
/// the range ran out, so hermes, kimi and grok have none.
///
/// `color` is stored as a closure and resolved on read, which is load-bearing rather than
/// stylistic. Nine of the ten pill colors are written as `Color.agentX` (or
/// `TranscriptColorSystem.agentBrandAccent(source:)` outright), and since Task 3 those
/// resolve *through this registry*. Evaluating them eagerly while a descriptor's own
/// `static let` is being initialized re-enters the `swift_once` that is already running on
/// this thread — a hard deadlock at first palette access, not a warning. Deferring the
/// evaluation to `.color` breaks the cycle: by the time anything reads a pill color, the
/// registry is fully built. The `@autoclosure` keeps every call site written as a plain
/// color expression.
struct PillSpec {
    private let makeColor: () -> Color
    let shortcut: String?

    var color: Color { makeColor() }

    init(color: @autoclosure @escaping () -> Color, shortcut: String?) {
        self.makeColor = color
        self.shortcut = shortcut
    }
}

// MARK: - SessionSourceAppearance

struct SessionSourceAppearance {
    let brandHue: BrandHue
    /// `Color(white:)` value used by Analytics' monochrome mode.
    let monochromeWhite: Double
    /// Onboarding accent, taken from the palette instance so appearance-dependent accents
    /// (claude/codex/antigravity) keep reading the palette's own colorScheme.
    ///
    /// WARNING — this must stay a closure. Four of these bodies return `Color.agentHermes`
    /// / `agentPi` / `agentKimi` / `agentGrok`, which resolve *through the registry*; they
    /// are inert only because a closure defers them past registry initialization. Flattening
    /// this field to a stored `Color` would evaluate them during adapter init and
    /// resurrect the `swift_once` deadlock documented on `PillSpec`.
    let onboardingAccent: (OnboardingPalette) -> Color
    /// nil for codex/claude (fixed segmented pills).
    let otherAgentPill: PillSpec?
}

// MARK: - Descriptor convenience

/// Keeps existing call sites reading palette data off the descriptor
/// (`source.descriptor.brandHue`, `descriptor.otherAgentPill`) now that it lives on the
/// adapter. App-target only.
extension SessionSourceDescriptor {
    var appearance: SessionSourceAppearance { SessionSourceRegistry.adapter(for: source).appearance }
    var brandHue: BrandHue { appearance.brandHue }
    var monochromeWhite: Double { appearance.monochromeWhite }
    var onboardingAccent: (OnboardingPalette) -> Color { appearance.onboardingAccent }
    var otherAgentPill: PillSpec? { appearance.otherAgentPill }
}
