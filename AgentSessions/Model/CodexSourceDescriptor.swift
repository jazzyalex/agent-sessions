import Foundation
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
