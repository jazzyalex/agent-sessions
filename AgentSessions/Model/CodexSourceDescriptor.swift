import Foundation
import Combine
import SwiftUI
import AppKit

// Codex lives in `Model/` rather than a `Codex/` folder because it has none: its parser,
// discovery and indexer predate the per-source folder convention and sit in `Services/`.

extension SessionSourceDescriptor {
    static let codex: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("codex")
        }
        return SessionSourceDescriptor(
            source: .codex,
            // turn_context states the effective model AND effort for every turn, so
            // the configuration timeline is exact. Tokens are partial only because
            // legacy rollouts exist that record a total with no component breakdown;
            // those can report a token count but cannot be priced.
            telemetry: TelemetryCapabilities(
                configuration: .supported,
                tokens: .partial("legacy total-only logs have no component breakdown"),
                cost: .partial("legacy total-only logs cannot be priced"),
                weeklyQuota: .partial("estimated from account-wide quota calibration; other-device activity is unobservable")
            ),
            shortLabel: "Codex",
            badgeInitials: "CX",
            // Deep blue.
            brandHue: .calibrated(red: 0.14, green: 0.30, blue: 0.60),
            monochromeWhite: 0.4,
            onboardingAccent: { $0.accentGreen },
            enablementKey: PreferencesKey.Agents.codexEnabled,
            cliAvailableKey: PreferencesKey.codexCLIAvailable,
            // Historical, un-namespaced key: "SessionsRootOverride" (K1 — frozen forever).
            rootOverrideKeys: [PreferencesKey.Paths.codexSessionsRootOverride],
            includeKey: PreferencesKey.Include.codex,
            binaryNames: ["codex"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.codexSessionsRootOverride)
                let root = CodexSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in SessionIndexer().parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.codexSessionsRootOverride)
                    let discovery = CodexSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        map[SessionArchiveBackfill.sha256Hex(url.path)] = url
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    // SessionIndexer's lightweight parsing helpers are currently private; for
                    // backfill we only need a stable upstream path so the archive can be
                    // created. Metadata will be refreshed on later scans.
                    SessionArchiveBackfill.minimalSession(source: .codex, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Codex CLI",
            otherAgentPill: nil
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for codex (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let codex = SessionSourceAdapter(
        descriptor: .codex,
        makeRuntime: {
            let indexer = SessionIndexer()
            return SourceRuntime(
                source: .codex,
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
                        let reason: SessionIndexer.ReloadReason
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
                    parseFull: { url, forcedID in indexer.parseFileFull(at: url, forcedID: forcedID) }
                )
            )
        }
    )
}
