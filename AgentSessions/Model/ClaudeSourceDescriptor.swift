import Foundation
import Combine
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let claude: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("claude") || ctx.detectBinary("claude-code")
        }
        return SessionSourceDescriptor(
            source: .claude,
            // Claude stamps the model on the assistant record that used it and never
            // records a session-start configuration, so the "initial" one is inferred
            // from the first observation. Usage is per-message and complete, including
            // the 5m/1h cache-write split and the fast-mode tier.
            telemetry: TelemetryCapabilities(
                configuration: .partial("initial config is first-observed, not recorded at session start"),
                tokens: .supported,
                cost: .supported,
                weeklyQuota: .unavailable("no persisted account quota snapshots (Plan B)")
            ),
            shortLabel: "Claude",
            badgeInitials: "CC",
            // Warm brown.
            brandHue: .calibrated(red: 0.74, green: 0.46, blue: 0.22),
            monochromeWhite: 0.5,
            onboardingAccent: { $0.accentOrange },
            enablementKey: PreferencesKey.Agents.claudeEnabled,
            cliAvailableKey: PreferencesKey.claudeCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.claudeSessionsRootOverride],
            includeKey: PreferencesKey.Include.claude,
            binaryNames: ["claude", "claude-code"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.claudeSessionsRootOverride)
                let discovery = ClaudeSessionDiscovery(customRoot: custom,
                                                       fileProbe: ctx.fileProbe,
                                                       homeDirectory: ctx.homeDirectory)
                // Claude's multi-root probe knows about project folders the plain
                // sessions-root check would miss, while still honoring the injected
                // filesystem and home-directory seams.
                if discovery.hasDiscoverableSessionsRoot() { return true }
                if ctx.directoryExists(discovery.sessionsRoot()) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in ClaudeSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride)
                    let discovery = ClaudeSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        map[SessionArchiveBackfill.sha256Hex(url.path)] = url
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    ClaudeSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .claude, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Claude Code",
            otherAgentPill: nil
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for claude (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let claude = SessionSourceAdapter(
        descriptor: .claude,
        makeRuntime: {
            let indexer = ClaudeSessionIndexer()
            return SourceRuntime(
                source: .claude,
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
                        let reason: ClaudeSessionIndexer.ReloadReason
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
                    parseFull: { url, forcedID in ClaudeSessionParser.parseFileFull(at: url, forcedID: forcedID) }
                )
            )
        }
    )
}
