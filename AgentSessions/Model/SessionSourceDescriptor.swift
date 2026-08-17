import Foundation
import SwiftUI
import AppKit
import CryptoKit

// MARK: - SessionSourceDescriptor
//
// Value data only (SPEC §3.1). One descriptor per `SessionSource`, each declared in that
// source's own folder; this file holds the shared types they are built from.
//
// Every value in every descriptor is transcribed VERBATIM from the switch statement it
// will later replace. Where the live code and the design draft disagreed, the live code
// won. Identity metadata (displayName / iconName / versionIntroduced / featureDescription)
// is deliberately absent: it stays on `SessionSource` itself, whose file compiles into the
// standalone logic-test target and must not gain app-target dependencies (K15).
//
// Nothing in this file is wired into the app yet — Tasks 3–8 flip consumers over.

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

// MARK: - EnablementDefault

/// What `AgentEnablement.isEnabled(_:)` does when the user has expressed no preference (K7).
enum EnablementDefault: Equatable {
    /// Falls into `isEnabled`'s `default: return true` branch — on regardless of availability
    /// (codex, claude, antigravity, opencode, copilot, droid).
    case always
    /// Has an explicit arm returning `isAvailable(_:)` — off unless the agent is present on
    /// this machine (hermes, openclaw, cursor, pi, kimi, grok).
    case whenAvailable
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

// MARK: - ArchiveCapability

/// A source's participation in pin/archive backfill. Optional on the descriptor because a
/// DB-backed source can decline it outright (SPEC §4) — every currently registered source
/// supplies one.
struct ArchiveCapability {
    /// Filesystem sweep producing `sessionID -> upstream file URL`, transcribed from
    /// `SessionArchiveManager.resolveBackfillURLsFromFilesystem(source:)`.
    let backfillURLs: (UserDefaults) -> [String: URL]
    /// Best-effort session for a known `(sessionID, upstreamURL)` pair, transcribed from
    /// `SessionArchiveManager.resolveSessionForBackfill(source:sessionID:upstreamURL:)`.
    /// Sources whose parser accepts a forced ID keep passing it.
    let sessionForBackfill: (String, URL) -> Session?
}

// MARK: - AvailabilityContext

/// Injected environment for the detection closures (K5). Descriptor closures never touch
/// `FileManager.default`: every existence check goes through `fileProbe`, every home-relative
/// path through `homeDirectory`, every PATH lookup through `detectBinary`. That is what makes
/// availability testable without depending on the developer's own machine.
struct AvailabilityContext {
    let defaults: UserDefaults
    let fileProbe: any FileProbing
    let homeDirectory: URL
    let environment: [String: String]
    let detectBinary: (String) -> Bool

    init(defaults: UserDefaults,
         fileProbe: any FileProbing,
         homeDirectory: URL,
         environment: [String: String] = [:],
         detectBinary: @escaping (String) -> Bool) {
        self.defaults = defaults
        self.fileProbe = fileProbe
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.detectBinary = detectBinary
    }

    /// The production seams.
    ///
    /// NOTE: `detectBinary` forwards to `AgentEnablement.binaryDetectedInPATH(_:)` rather
    /// than the process-wide memoized `binaryDetectedCached(_:)`, which is `private` to
    /// `AgentEnablement`. The two agree on every answer; only the caching differs. When
    /// Task 4 moves `AgentEnablement` onto the registry it should build its context
    /// in-file, where the cached form is visible, and keep this factory for callers outside.
    @MainActor
    static func live(defaults: UserDefaults = .standard) -> AvailabilityContext {
        AvailabilityContext(
            defaults: defaults,
            fileProbe: DefaultFileProbe(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            detectBinary: { AgentEnablement.binaryDetectedInPATH($0) }
        )
    }

    /// `defaults.string(forKey:)` with the empty string normalized to nil — the shape every
    /// `isAvailable` arm uses today (`custom.isEmpty ? nil : custom`).
    func customRoot(_ key: String) -> String? {
        let custom = defaults.string(forKey: key) ?? ""
        return custom.isEmpty ? nil : custom
    }

    /// `FileManager.fileExists(atPath:isDirectory:) && isDir.boolValue`, through the seam.
    func directoryExists(_ url: URL) -> Bool {
        fileProbe.directoryExists(atPath: url.path)
    }
}

// MARK: - SessionSourceDescriptor

struct SessionSourceDescriptor {
    /// The source this descriptor describes.
    let source: SessionSource

    // MARK: Labels

    /// Row/legend label (`UnifiedSessionsView`'s session-row switch). Differs from
    /// `source.displayName` for codex ("Codex"), claude ("Claude") and copilot ("Copilot").
    let shortLabel: String
    /// Two letters on `AgentBadge`, except droid's single "D".
    let badgeInitials: String

    // MARK: Palette

    let brandHue: BrandHue
    /// `Color(white:)` value used by Analytics' monochrome mode.
    let monochromeWhite: Double
    /// Onboarding accent, taken from the palette instance so appearance-dependent accents
    /// (claude/codex/antigravity) keep reading the palette's own colorScheme.
    ///
    /// WARNING — this must stay a closure. Four of these bodies return `Color.agentHermes`
    /// / `agentPi` / `agentKimi` / `agentGrok`, which resolve *through this registry*; they
    /// are inert only because a closure defers them past registry initialization. Flattening
    /// this field to a stored `Color` would evaluate them during descriptor init and
    /// resurrect the `swift_once` deadlock documented on `PillSpec`.
    let onboardingAccent: (OnboardingPalette) -> Color

    // MARK: UserDefaults keys (K1/K2 — named constants, never derived from rawValue)

    let enablementKey: String
    /// nil for openclaw, the only source with no persisted CLI-detection flag (K4).
    let cliAvailableKey: String?
    /// One key for every source except droid, which probes a sessions root and a projects
    /// root (K3).
    let rootOverrideKeys: [String]
    let includeKey: String

    // MARK: Detection (K5)

    /// Executable name(s) accepted as evidence of this agent.
    let binaryNames: [String]
    let isBinaryInstalled: (AvailabilityContext) -> Bool
    /// Filesystem-first availability: session roots, then the binary. Transcribed from
    /// `AgentEnablement.isAvailable(_:defaults:)` minus its `AppRuntime.isHostedByTooling`
    /// early return, which is a global harness concern rather than per-source data and stays
    /// with the caller.
    let isAvailable: (AvailabilityContext) -> Bool

    // MARK: Enablement

    let defaultEnabled: EnablementDefault

    // MARK: Search ingest

    /// Full parse of a session identified by its file path. nil means the source declines
    /// path-identified parsing because every one of its sessions shares one database path
    /// (SPEC §4).
    let parseFullByPath: ((URL) -> Session?)?
    /// Full parse of a session identified by both its storage URL and stable session ID.
    /// DB-backed sources use this because many sessions can share the same database path.
    /// File-backed sources leave it nil and continue through `parseFullByPath`.
    let parseFullByIdentity: ((URL, String) -> Session?)?
    /// Selects the storage URLs for which search freshness and parsing are session-ID based.
    /// This stays separate because a source such as Hermes can support both JSON files and
    /// a shared SQLite database.
    let searchUsesIdentityAtURL: ((URL) -> Bool)?

    // MARK: Archive

    /// nil = archiving unsupported for this source (SPEC §4).
    let archive: ArchiveCapability?

    // MARK: Resume

    let supportsResume: Bool
    /// Agent name shown in resume affordances; nil exactly where the legacy switch had no
    /// arm (droid, openclaw — which never resume).
    let resumeAgentLabel: String?

    // MARK: Toolbar

    /// nil for codex/claude (fixed segmented pills).
    let otherAgentPill: PillSpec?
}

// MARK: - Archive backfill helpers

/// Internal copies of two `SessionArchiveManager` privates the archive closures need.
/// Bodies are identical to the originals; Task 5 points `SessionArchiveManager` here and
/// deletes its own copies.
enum SessionArchiveBackfill {
    /// Identical body to `SessionArchiveManager.minimalSession(source:id:url:)`.
    static func minimalSession(source: SessionSource, id: String, url: URL) -> Session {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        return Session(
            id: id,
            source: source,
            startTime: mtime,
            endTime: mtime,
            model: nil,
            filePath: url.path,
            fileSizeBytes: size,
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            lightweightCommands: nil
        )
    }

    /// Identical body to `SessionArchiveManager.sha256Hex(_:)`.
    static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
