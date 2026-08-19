import Foundation
import Combine
import SwiftUI
import AppKit

/// Persisted Devin keys live with the source descriptor, not in the legacy shared
/// preferences table. These strings are durable search/archive/UI contracts.
enum DevinPreferencesKey {
    static let enabled = "AgentEnabledDevin"
    static let cliAvailable = "DevinCLIAvailable"
    static let sessionsRootOverride = "DevinSessionsRootOverride"
    static let includeSessions = "IncludeDevinSessions"
}

extension SessionSourceDescriptor {
    static let devin: SessionSourceDescriptor = {
        return SessionSourceDescriptor(
            source: .devin,
            shortLabel: "Devin CLI",
            badgeInitials: "DV",
            // Warm amber, clear of Claude's brown and OpenClaw's orange.
            brandHue: .calibrated(red: 0.85, green: 0.62, blue: 0.16),
            monochromeWhite: 0.58,
            onboardingAccent: { _ in Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .devin)) },
            enablementKey: DevinPreferencesKey.enabled,
            cliAvailableKey: DevinPreferencesKey.cliAvailable,
            rootOverrideKeys: [DevinPreferencesKey.sessionsRootOverride],
            includeKey: DevinPreferencesKey.includeSessions,
            binaryNames: ["devin"],
            isBinaryInstalled: { ctx in
                ctx.detectBinary("devin")
            },
            isAvailable: { ctx in
                let custom = ctx.customRoot(DevinPreferencesKey.sessionsRootOverride)
                let discovery = DevinSessionDiscovery(customRoot: custom,
                                                      fileProbe: ctx.fileProbe,
                                                      homeDirectory: ctx.homeDirectory)
                if ctx.fileProbe.fileExists(atPath: discovery.databaseURL().path) { return true }
                return ctx.detectBinary("devin")
            },
            defaultEnabled: .whenAvailable,
            // Every session lives in one shared database, so path-identified
            // parsing is meaningless; search ingests through the identity
            // channel instead (SPEC §4, guide §5).
            parseFullByPath: nil,
            parseFullByIdentity: { url, sessionID in
                DevinSqliteReader.loadFullSession(databasePath: url.path, sessionID: sessionID)
            },
            searchUsesIdentityAtURL: { $0.pathExtension == "db" },
            // Archiving is a no-op: sessions are rows in a shared database,
            // so there is nothing per-session to copy out.
            archive: nil,
            supportsResume: true,
            resumeAgentLabel: "Devin CLI",
            // K10: same exhausted ⌘-range as Hermes/Kimi/Grok.
            otherAgentPill: PillSpec(color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .devin)),
                                     shortcut: nil)
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for devin (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let devin = SessionSourceAdapter(
        descriptor: .devin,
        makeRuntime: {
            let indexer = DevinSessionIndexer()
            return SourceRuntime(
                source: .devin,
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
                    searchIdentitySnapshots: .provider { indexer.searchIdentitySnapshot },
                    refresh: { mode, trigger, profile in
                        indexer.refresh(mode: mode, trigger: trigger, executionProfile: profile)
                    },
                    reloadFocusedSession: { id, force, trigger in
                        let reason: DevinSessionIndexer.ReloadReason
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
                    parseFull: { url, forcedID in
                        DevinSqliteReader.loadFullSession(databasePath: url.path, sessionID: forcedID)
                    }
                )
            )
        }
    )
}
