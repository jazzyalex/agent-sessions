import Foundation
import Combine
import SwiftUI
import AppKit

/// Persisted fx keys live with the source descriptor, not in the legacy shared
/// preferences table. These strings are durable search/archive/UI contracts.
enum FxPreferencesKey {
    static let enabled = "AgentEnabledFx"
    static let cliAvailable = "FxCLIAvailable"
    static let sessionsRootOverride = "FxSessionsRootOverride"
    static let includeSessions = "IncludeFxSessions"
}

extension SessionSourceDescriptor {
    static let fx: SessionSourceDescriptor = {
        // A bare `fx` on PATH is weak evidence by itself (the name is short and
        // generic), so require the CLI's own data directory alongside the binary —
        // injected, never `FileManager.default`.
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            guard ctx.detectBinary("fx") else { return false }
            let fxHome = ctx.homeDirectory.appendingPathComponent(".fx", isDirectory: true)
            return ctx.directoryExists(fxHome)
        }
        return SessionSourceDescriptor(
            source: .fx,
            shortLabel: "fx",
            badgeInitials: "FX",
            // fx ships no usable brand chroma — its mark and site are monochrome —
            // so this slot is a free choice, not an inherited color: crimson,
            // clear of OpenClaw's orange and Codex's deep blue.
            brandHue: .calibrated(red: 0.80, green: 0.22, blue: 0.27),
            monochromeWhite: 0.60,
            onboardingAccent: { _ in Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .fx)) },
            enablementKey: FxPreferencesKey.enabled,
            cliAvailableKey: FxPreferencesKey.cliAvailable,
            rootOverrideKeys: [FxPreferencesKey.sessionsRootOverride],
            includeKey: FxPreferencesKey.includeSessions,
            binaryNames: ["fx"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(FxPreferencesKey.sessionsRootOverride)
                let discovery = FxSessionDiscovery(customRoot: custom,
                                                   fileProbe: ctx.fileProbe,
                                                   homeDirectory: ctx.homeDirectory)
                if !discovery.discoverSessionFiles().isEmpty { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in FxSessionParser.parseFileFull(at: url) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: FxPreferencesKey.sessionsRootOverride)
                    let discovery = FxSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let id = FxSessionDiscovery.sessionID(forCheckpoint: url) {
                            map[id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    FxSessionParser.parseFileFull(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .fx, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "fx",
            // K10: same exhausted ⌘-range as Hermes/Kimi/Grok/Qwen.
            otherAgentPill: PillSpec(color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .fx)),
                                     shortcut: nil)
        )
    }()
}

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for fx (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let fx = SessionSourceAdapter(
        descriptor: .fx,
        makeRuntime: {
            let indexer = FxSessionIndexer()
            return SourceRuntime(
                source: .fx,
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
                        let reason: FxSessionIndexer.ReloadReason
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
                    parseFull: { url, _ in FxSessionParser.parseFileFull(at: url, allowLargeFile: true) }
                )
            )
        }
    )
}
