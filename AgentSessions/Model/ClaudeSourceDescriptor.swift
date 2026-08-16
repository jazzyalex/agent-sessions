import Foundation
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let claude: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("claude") || ctx.detectBinary("claude-code")
        }
        return SessionSourceDescriptor(
            source: .claude,
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
                let discovery = ClaudeSessionDiscovery(customRoot: custom)
                // Claude's own multi-root probe, which knows about project folders the
                // plain sessions-root check would miss. It reads the filesystem directly
                // (not through `ctx.fileProbe`) — see the task report.
                if discovery.hasDiscoverableSessionsRoot() { return true }
                if ctx.directoryExists(discovery.sessionsRoot()) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in ClaudeSessionParser.parseFileFull(at: url) },
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
