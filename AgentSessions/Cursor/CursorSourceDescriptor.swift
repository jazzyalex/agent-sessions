import Foundation
import Combine
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let cursor: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("agent") || ctx.detectBinary("cursor") || ctx.detectBinary("cursor-agent")
        }
        return SessionSourceDescriptor(
            source: .cursor,
            shortLabel: "Cursor",
            badgeInitials: "CR",
            // Teal-ish (Cursor brand).
            brandHue: .calibrated(red: 0.20, green: 0.60, blue: 0.70),
            monochromeWhite: 0.9,
            onboardingAccent: { _ in Color(red: 0.20, green: 0.60, blue: 0.70) },
            enablementKey: PreferencesKey.Agents.cursorEnabled,
            cliAvailableKey: PreferencesKey.cursorCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.cursorSessionsRootOverride],
            includeKey: PreferencesKey.Include.cursor,
            binaryNames: ["agent", "cursor", "cursor-agent"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.cursorSessionsRootOverride)
                let disc = CursorSessionDiscovery(customRoot: custom)
                // Also check the chats root (DB-only sessions live there). The live switch
                // does this before the shared sessions-root check, so the order is kept.
                if ctx.directoryExists(disc.chatsRoot()) { return true }
                if ctx.directoryExists(disc.sessionsRoot()) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in CursorSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
                    let discovery = CursorSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let s = CursorSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    CursorSessionParser.parseFile(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .cursor, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Cursor CLI",
            otherAgentPill: PillSpec(color: Color.agentCursor, shortcut: "8")
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for cursor (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let cursor = SessionSourceAdapter(
        descriptor: .cursor,
        makeRuntime: {
            let indexer = CursorSessionIndexer()
            return SourceRuntime(
                source: .cursor,
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
                        let reason: CursorSessionIndexer.ReloadReason
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
                    parseFull: { url, forcedID in CursorSessionParser.parseFileFull(at: url, forcedID: forcedID) }
                )
            )
        }
    )
}
