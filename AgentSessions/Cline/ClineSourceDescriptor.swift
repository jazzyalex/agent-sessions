import Foundation
import Combine
import SwiftUI
import AppKit

/// Persisted Cline keys live with the source descriptor, not in the legacy shared
/// preferences table. These strings are durable search/archive/UI contracts.
enum ClinePreferencesKey {
    static let enabled = "AgentEnabledCline"
    static let cliAvailable = "ClineCLIAvailable"
    static let binaryPath = "ClineBinaryPath"
    static let resolvedBinaryPath = "ClineResolvedBinaryPath"
    static let sessionsRootOverride = "ClineSessionsRootOverride"
    static let includeSessions = "IncludeClineSessions"
}

extension SessionSourceDescriptor {
    static let cline: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            let configured = (ctx.defaults.string(forKey: ClinePreferencesKey.binaryPath) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !configured.isEmpty {
                let resolved = (ctx.defaults.string(forKey: ClinePreferencesKey.resolvedBinaryPath) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resolved.isEmpty else { return false }
                let configuredPath = UserPathExpansion.expand(configured, relativeTo: ctx.homeDirectory)
                let resolvedPath = UserPathExpansion.expand(resolved, relativeTo: ctx.homeDirectory)
                guard URL(fileURLWithPath: configuredPath).standardizedFileURL.path
                        == URL(fileURLWithPath: resolvedPath).standardizedFileURL.path else {
                    return false
                }
                return ctx.fileProbe.isExecutableFile(atPath: resolvedPath)
            }
            return ctx.detectBinary("cline")
        }
        return SessionSourceDescriptor(
            source: .cline,
            telemetry: .allUnavailable("Cline transcript telemetry not yet audited"),
            shortLabel: "Cline",
            badgeInitials: "CN",
            // Sky blue, clear of Codex's deep blue, Cursor's teal and Kimi/Qwen violets.
            brandHue: .calibrated(red: 0.22, green: 0.58, blue: 0.90),
            monochromeWhite: 0.64,
            onboardingAccent: { _ in Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .cline)) },
            enablementKey: ClinePreferencesKey.enabled,
            cliAvailableKey: ClinePreferencesKey.cliAvailable,
            rootOverrideKeys: [ClinePreferencesKey.sessionsRootOverride],
            includeKey: ClinePreferencesKey.includeSessions,
            binaryNames: ["cline"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(ClinePreferencesKey.sessionsRootOverride)
                let discovery = ClineSessionDiscovery(customRoot: custom,
                                                      fileProbe: ctx.fileProbe,
                                                      homeDirectory: ctx.homeDirectory,
                                                      environment: ctx.environment)
                if !discovery.discoverSessionFiles().isEmpty { return true }
                if ctx.directoryExists(discovery.sessionsRoot()) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in ClineSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            logicalFileStat: { ClineSessionDiscovery.logicalFileStat(forManifest: $0) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: ClinePreferencesKey.sessionsRootOverride)
                    let discovery = ClineSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let parsed = ClineSessionParser.parseFile(at: url) {
                            map[parsed.id] = url
                        } else if let id = ClineSessionDiscovery.sessionID(forManifest: url) {
                            map[id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    ClineSessionParser.parseFileFull(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .cline, id: sessionID, url: upstreamURL)
                },
                archiveUnit: { primaryURL in
                    // The manifest is half of a manifest+messages pair; snapshot the
                    // whole session directory so the transcript survives alongside it
                    // and the archived primary still full-parses.
                    let base = primaryURL.deletingPathExtension().lastPathComponent
                    let dir = primaryURL.deletingLastPathComponent()
                    guard !base.isEmpty, dir.lastPathComponent == base else { return nil }
                    return ArchiveUnit(root: dir,
                                       isDirectory: true,
                                       primaryRelativePath: primaryURL.lastPathComponent)
                }
            ),
            supportsResume: false,
            resumeAgentLabel: nil,
            // K10: same exhausted ⌘-range as Hermes/Kimi/Grok/Qwen/Devin/fx.
            otherAgentPill: PillSpec(color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .cline)),
                                     shortcut: nil)
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for cline (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let cline = SessionSourceAdapter(
        descriptor: .cline,
        makeRuntime: {
            let indexer = ClineSessionIndexer()
            return SourceRuntime(
                source: .cline,
                indexerObject: indexer,
                handle: UnifiedSessionIndexer.ProviderHandle(
                    allSessions: indexer.$allSessions.eraseToAnyPublisher(),
                    isIndexing: indexer.$isIndexing.eraseToAnyPublisher(),
                    isProcessingTranscripts: indexer.$isProcessingTranscripts.eraseToAnyPublisher(),
                    filesProcessed: indexer.$filesProcessed.eraseToAnyPublisher(),
                    totalFiles: indexer.$totalFiles.eraseToAnyPublisher(),
                    indexingError: indexer.$indexingError.eraseToAnyPublisher(),
                    launchPhase: indexer.$launchPhase.eraseToAnyPublisher(),
                    currentSessions: { indexer.allSessions },
                    currentIsIndexing: { indexer.isIndexing },
                    currentLaunchPhase: { indexer.launchPhase },
                    searchIdentitySnapshots: .notApplicable,
                    refresh: { mode, trigger, profile in
                        indexer.refresh(mode: mode, trigger: trigger, executionProfile: profile)
                    },
                    reloadFocusedSession: { id, force, trigger in
                        let reason: ClineSessionIndexer.ReloadReason
                        switch trigger {
                        case .selection: reason = .selection
                        case .monitor: reason = .focusedSessionMonitor
                        case .manual: reason = .manualRefresh
                        }
                        indexer.reloadSession(id: id, force: force, reason: reason)
                    }
                ),
                // Transcribed verbatim from UnifiedSessionsView.init's adapter dictionary.
                searchAdapter: .init(
                    transcriptCache: indexer.searchTranscriptCache,
                    update: { indexer.updateSession($0) },
                    parseFull: { url, _ in ClineSessionParser.parseFileFull(at: url) }
                )
            )
        }
    )
}
