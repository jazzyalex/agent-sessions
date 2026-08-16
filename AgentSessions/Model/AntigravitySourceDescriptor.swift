import Foundation
import SwiftUI
import AppKit

// Antigravity has no top-level source folder (only `AntigravityResume/`), so its descriptor
// lives here alongside codex/claude/openclaw.

extension SessionSourceDescriptor {
    static let antigravity: SessionSourceDescriptor = {
        // The binary is "agy", not "antigravity".
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("agy")
        }
        return SessionSourceDescriptor(
            source: .antigravity,
            shortLabel: "Antigravity",
            badgeInitials: "AG",
            // Teal. Passthrough: the system dynamic color is returned unwrapped (K6).
            brandHue: .system(NSColor.systemTeal),
            monochromeWhite: 0.6,
            onboardingAccent: { $0.accentBlue },
            enablementKey: PreferencesKey.Agents.antigravityEnabled,
            cliAvailableKey: PreferencesKey.antigravityCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.antigravitySessionsRootOverride],
            includeKey: PreferencesKey.Include.antigravity,
            binaryNames: ["agy"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.antigravitySessionsRootOverride)
                let root = AntigravitySessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in AntigravitySessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.antigravitySessionsRootOverride)
                    let discovery = AntigravitySessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let session = AntigravitySessionParser.parseFile(at: url), !session.id.isEmpty {
                            map[session.id] = url
                        }
                        if let conversationID = AntigravitySessionIDHelper.conversationID(fromArtifactURL: url),
                           map[conversationID] == nil {
                            map[conversationID] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    AntigravitySessionParser.parseFile(at: upstreamURL, forcedID: sessionID)
                        ?? SessionArchiveBackfill.minimalSession(source: .antigravity, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Antigravity CLI",
            otherAgentPill: PillSpec(color: .teal, shortcut: "3")
        )
    }()
}
