import Foundation
import Combine
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let grok: SessionSourceDescriptor = {
        // Homebrew also ships an unrelated `grok` formula (jordansissel/grok, a regex
        // utility), so a bare PATH hit is not evidence of the Grok CLI. Require the CLI's
        // own home directory alongside the binary — injected, never `FileManager.default`.
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            guard ctx.detectBinary("grok") else { return false }
            let grokHome = ctx.homeDirectory.appendingPathComponent(".grok", isDirectory: true)
            return ctx.directoryExists(grokHome)
        }
        return SessionSourceDescriptor(
            source: .grok,
            shortLabel: "Grok CLI",
            badgeInitials: "GK",
            // Slate blue-grey, echoing xAI's monochrome mark while staying clear of
            // Codex's deep blue and Cursor's teal.
            brandHue: .calibrated(red: 0.35, green: 0.40, blue: 0.52),
            monochromeWhite: 0.62,
            onboardingAccent: { _ in Color.agentGrok },
            enablementKey: PreferencesKey.Agents.grokEnabled,
            cliAvailableKey: PreferencesKey.grokCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.grokSessionsRootOverride],
            includeKey: PreferencesKey.Include.grok,
            binaryNames: ["grok"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.grokSessionsRootOverride)
                let root = GrokSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in GrokSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.grokSessionsRootOverride)
                    let discovery = GrokSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let id = GrokSessionDiscovery.sessionID(forTranscript: url) {
                            map[id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    GrokSessionParser.parseFileFull(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .grok, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Grok CLI",
            // K10: same exhausted ⌘-range as Hermes/Kimi.
            otherAgentPill: PillSpec(color: Color.agentGrok, shortcut: nil)
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for grok (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let grok = SessionSourceAdapter(
        descriptor: .grok,
        makeRuntime: {
            let indexer = GrokSessionIndexer()
            return SourceRuntime(
                source: .grok,
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
                        let reason: GrokSessionIndexer.ReloadReason
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
                    parseFull: { url, _ in GrokSessionParser.parseFileFull(at: url, allowLargeFile: true) }
                )
            )
        }
    )
}
