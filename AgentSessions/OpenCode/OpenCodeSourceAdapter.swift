import Foundation
import Combine
import SwiftUI
import AppKit

// App-only half of the OpenCode source: runtime factory and palette. The UI-free
// descriptor lives in OpenCodeSourceDescriptor.swift and is shared with the Linux core.

// MARK: - Adapter

extension SessionSourceAdapter {
    /// Descriptor + runtime factory for opencode (SPEC §3.2). `makeRuntime` runs once,
    /// from `SessionProviderCatalog.init`; every closure below captures only the local
    /// `indexer`, never `self` or the catalog (SPEC §3.4 retain-cycle rule).
    static let opencode = SessionSourceAdapter(
        descriptor: .opencode,
        appearance: SessionSourceAppearance(
            // Purple. Calibrated from `systemPurple`, same reasoning as antigravity's teal.
            brandHue: .calibrated(red: 0.616472, green: 0.200378, blue: 0.838919),
            monochromeWhite: 0.7,
            onboardingAccent: { _ in Color(red: 0.62, green: 0.52, blue: 0.96) },
            otherAgentPill: PillSpec(color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .opencode)),
                                     shortcut: "4")
        ),
        makeRuntime: {
            let indexer = OpenCodeSessionIndexer()
            return SourceRuntime(
                source: .opencode,
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
                    refresh: { _, _, _ in
                        // SPEC §8.6: OpenCode's refresh takes no arguments; the unified
                        // indexer has always dropped mode/trigger/profile for this source.
                        indexer.refresh()
                    },
                    reloadFocusedSession: { id, force, trigger in
                        let reason: OpenCodeSessionIndexer.ReloadReason
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
                        if url.lastPathComponent == "opencode.db", !forcedID.isEmpty {
                            let customRoot = indexer.sessionsRootOverride.isEmpty ? nil : indexer.sessionsRootOverride
                            return OpenCodeSqliteReader.loadFullSession(customRoot: customRoot, sessionID: forcedID)
                        }
                        return OpenCodeSessionParser.parseFileFull(at: url)
                    }
                )
            )
        }
    )
}
