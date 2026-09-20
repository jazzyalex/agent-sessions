import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

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
// UI-free (shared with the Linux core). Palette and toolbar data — brand hue, monochrome
// white, onboarding accent, toolbar pill — live in the app-only `SessionSourceAppearance`
// carried by each source's `SessionSourceAdapter`.

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

// MARK: - ArchiveCapability

/// The filesystem unit an archive snapshots for one session: the root to copy and the
/// primary file to parse back. Single-file sources snapshot the file itself; paired
/// sources (Cline: manifest plus an adjacent messages file) snapshot the session
/// directory so the companion survives alongside the primary.
struct ArchiveUnit {
    let root: URL
    let isDirectory: Bool
    let primaryRelativePath: String
}

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
    /// The archive unit for a primary file URL. nil (the default) snapshots the primary
    /// file itself; a paired source returns its session directory with the primary's
    /// filename so the copy carries the companion files the full parse needs.
    let archiveUnit: ((URL) -> ArchiveUnit?)?

    init(backfillURLs: @escaping (UserDefaults) -> [String: URL],
         sessionForBackfill: @escaping (String, URL) -> Session?,
         archiveUnit: ((URL) -> ArchiveUnit?)? = nil) {
        self.backfillURLs = backfillURLs
        self.sessionForBackfill = sessionForBackfill
        self.archiveUnit = archiveUnit
    }
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

// MARK: - Telemetry capability

/// What one telemetry dimension can be produced for a source.
///
/// `partial` and `unavailable` carry a reason because the two read identically at
/// a call site otherwise — and "we audited this format and it cannot express X" is
/// a very different fact from "nobody has looked yet".
enum TelemetryCapability: Equatable, Sendable {
    case supported
    case partial(String)
    case unavailable(String)

    /// True when this dimension can produce something worth showing.
    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// Per-source telemetry declarations, one per dimension.
///
/// Declared for every source rather than inferred, so `SessionTelemetryEngine`
/// dispatches on capability instead of a hardcoded provider list: adding a provider
/// later is a descriptor edit plus an accumulator, with no engine change.
struct TelemetryCapabilities: Equatable, Sendable {
    /// Initial/current model + reasoning effort, and the changes between them.
    let configuration: TelemetryCapability
    /// Token usage split into fresh input / cache read / cache write / output.
    let tokens: TelemetryCapability
    /// API-equivalent dollars, which needs both a priceable model and component tokens.
    let cost: TelemetryCapability
    /// Per-session share of an account's weekly quota. Unavailable everywhere until
    /// account quota snapshots are persisted (Plan B).
    let weeklyQuota: TelemetryCapability

    /// The common Plan A shape: one reason, all four dimensions unavailable.
    static func allUnavailable(_ reason: String) -> TelemetryCapabilities {
        TelemetryCapabilities(configuration: .unavailable(reason),
                              tokens: .unavailable(reason),
                              cost: .unavailable(reason),
                              weeklyQuota: .unavailable("no account-level quota feed"))
    }
}

// MARK: - SessionSourceDescriptor

struct SessionSourceDescriptor {
    /// The source this descriptor describes.
    let source: SessionSource

    /// What telemetry this source can produce. Non-optional on purpose: the
    /// compiler makes every source state a verdict.
    let telemetry: TelemetryCapabilities

    // MARK: Labels

    /// Row/legend label (`UnifiedSessionsView`'s session-row switch). Differs from
    /// `source.displayName` for codex ("Codex"), claude ("Claude") and copilot ("Copilot").
    let shortLabel: String
    /// Two letters on `AgentBadge`, except droid's single "D".
    let badgeInitials: String

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

    // MARK: Session enumeration

    /// Builds this source's discovery for a context, so any host (the app's indexers, the
    /// headless CLI) enumerates transcripts the same way. nil only for a source whose
    /// sessions exist solely as database rows.
    let makeDiscovery: ((AvailabilityContext) -> any SessionDiscovery)?
    /// Metadata-only parse of one transcript file — what the app's list uses at launch.
    let parseLightweightByPath: ((URL) -> Session?)?
    /// Lightweight rows for sessions stored inside a shared database.
    let listDatabaseSessions: ((AvailabilityContext) -> [Session])?

    // MARK: Pair-aware freshness

    /// Logical freshness stat for a session's primary file URL. nil (the default) stats
    /// the primary file itself. A paired source (Cline: manifest plus an adjacent
    /// messages file) combines the pair so companion-only writes still trip the
    /// focused-session monitor and search re-ingest/currency, both of which only see
    /// the primary path.
    let logicalFileStat: ((URL) -> SessionFileStat?)?

    // MARK: Archive

    /// nil = archiving unsupported for this source (SPEC §4).
    let archive: ArchiveCapability?

    // MARK: Resume

    let supportsResume: Bool
    /// Agent name shown in resume affordances; nil exactly where the legacy switch had no
    /// arm (droid, openclaw — which never resume).
    let resumeAgentLabel: String?

    init(source: SessionSource,
         telemetry: TelemetryCapabilities,
         shortLabel: String,
         badgeInitials: String,
         enablementKey: String,
         cliAvailableKey: String?,
         rootOverrideKeys: [String],
         includeKey: String,
         binaryNames: [String],
         isBinaryInstalled: @escaping (AvailabilityContext) -> Bool,
         isAvailable: @escaping (AvailabilityContext) -> Bool,
         defaultEnabled: EnablementDefault,
         parseFullByPath: ((URL) -> Session?)?,
         parseFullByIdentity: ((URL, String) -> Session?)?,
         searchUsesIdentityAtURL: ((URL) -> Bool)?,
         makeDiscovery: ((AvailabilityContext) -> any SessionDiscovery)? = nil,
         parseLightweightByPath: ((URL) -> Session?)? = nil,
         listDatabaseSessions: ((AvailabilityContext) -> [Session])? = nil,
         logicalFileStat: ((URL) -> SessionFileStat?)? = nil,
         archive: ArchiveCapability?,
         supportsResume: Bool,
         resumeAgentLabel: String?) {
        self.source = source
        self.telemetry = telemetry
        self.shortLabel = shortLabel
        self.badgeInitials = badgeInitials
        self.enablementKey = enablementKey
        self.cliAvailableKey = cliAvailableKey
        self.rootOverrideKeys = rootOverrideKeys
        self.includeKey = includeKey
        self.binaryNames = binaryNames
        self.isBinaryInstalled = isBinaryInstalled
        self.isAvailable = isAvailable
        self.defaultEnabled = defaultEnabled
        self.parseFullByPath = parseFullByPath
        self.parseFullByIdentity = parseFullByIdentity
        self.searchUsesIdentityAtURL = searchUsesIdentityAtURL
        self.makeDiscovery = makeDiscovery
        self.parseLightweightByPath = parseLightweightByPath
        self.listDatabaseSessions = listDatabaseSessions
        self.logicalFileStat = logicalFileStat
        self.archive = archive
        self.supportsResume = supportsResume
        self.resumeAgentLabel = resumeAgentLabel
    }
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
