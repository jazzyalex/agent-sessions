import Foundation
import Combine
import SwiftUI
import AppKit

/// Persisted Qwen keys live with the source descriptor, not in the legacy shared
/// preferences table. These strings are durable search/archive/UI contracts.
enum QwenPreferencesKey {
    static let enabled = "AgentEnabledQwen"
    static let cliAvailable = "QwenCLIAvailable"
    static let sessionsRootOverride = "QwenSessionsRootOverride"
    static let includeSessions = "IncludeQwenSessions"
}

extension SessionSourceDescriptor {
    static let qwen: SessionSourceDescriptor = {
        // Routes through the one resolver so availability cannot disagree with the
        // root discovery and resume eligibility actually read. See
        // `QwenSessionDiscovery.resolvedSessionsRoot`.
        let projectsRoot: (AvailabilityContext) -> URL = { context in
            QwenSessionDiscovery.resolvedSessionsRoot(
                customRoot: context.customRoot(QwenPreferencesKey.sessionsRootOverride),
                homeDirectory: context.homeDirectory,
                environment: context.environment,
                directoryExists: { context.directoryExists($0) }
            )
        }

        return SessionSourceDescriptor(
            source: .qwen,
            telemetry: .allUnavailable("dense per-call token telemetry is retained but unparsed (Plan C)"),
            shortLabel: "Qwen Code",
            badgeInitials: "QW",
            brandHue: .calibrated(red: 0.45, green: 0.31, blue: 0.77),
            monochromeWhite: 0.61,
            onboardingAccent: { _ in Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .qwen)) },
            enablementKey: QwenPreferencesKey.enabled,
            cliAvailableKey: QwenPreferencesKey.cliAvailable,
            rootOverrideKeys: [QwenPreferencesKey.sessionsRootOverride],
            includeKey: QwenPreferencesKey.includeSessions,
            binaryNames: ["qwen"],
            isBinaryInstalled: { $0.detectBinary("qwen") },
            isAvailable: { context in
                context.directoryExists(projectsRoot(context)) || context.detectBinary("qwen")
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { QwenSessionParser.parseFileFull(at: $0) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    let value = defaults.string(forKey: QwenPreferencesKey.sessionsRootOverride)
                    let discovery = QwenSessionDiscovery(customRoot: value?.isEmpty == false ? value : nil)
                    var byID: [String: URL] = [:]
                    for url in discovery.discoverSessionFiles() {
                        guard let id = QwenSessionDiscovery.sessionID(forTranscript: url), byID[id] == nil else {
                            continue
                        }
                        byID[id] = url
                    }
                    return byID
                },
                sessionForBackfill: { id, url in
                    QwenSessionParser.parseFileFull(at: url)
                        ?? SessionArchiveBackfill.minimalSession(source: .qwen, id: id, url: url)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Qwen Code",
            otherAgentPill: PillSpec(
                color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .qwen)),
                shortcut: nil
            )
        )
    }()
}

extension SessionSourceAdapter {
    static let qwen = SessionSourceAdapter(
        descriptor: .qwen,
        makeRuntime: {
            let indexer = QwenSessionIndexer()
            return SourceRuntime(
                source: .qwen,
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
                        let reason: QwenSessionIndexer.ReloadReason
                        switch trigger {
                        case .selection: reason = .selection
                        case .monitor: reason = .focusedSessionMonitor
                        case .manual: reason = .manualRefresh
                        }
                        indexer.reloadSession(id: id, force: force, reason: reason)
                    }
                ),
                searchAdapter: .init(
                    transcriptCache: indexer.searchTranscriptCache,
                    update: { indexer.updateSession($0) },
                    parseFull: { url, _ in QwenSessionParser.parseFileFull(at: url) }
                )
            )
        }
    )
}
