import Foundation
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let copilot: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("copilot")
        }
        return SessionSourceDescriptor(
            source: .copilot,
            shortLabel: "Copilot",
            badgeInitials: "CP",
            // Magenta-ish.
            brandHue: .calibrated(red: 0.90, green: 0.20, blue: 0.60),
            monochromeWhite: 0.75,
            onboardingAccent: { _ in Color(red: 0.82, green: 0.36, blue: 0.78) },
            enablementKey: PreferencesKey.Agents.copilotEnabled,
            cliAvailableKey: PreferencesKey.copilotCLIAvailable,
            rootOverrideKeys: [PreferencesKey.Paths.copilotSessionsRootOverride],
            includeKey: PreferencesKey.Include.copilot,
            binaryNames: ["copilot"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.copilotSessionsRootOverride)
                let root = CopilotSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .always,
            parseFullByPath: { url in CopilotSessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let custom = defaults.string(forKey: PreferencesKey.Paths.copilotSessionsRootOverride)
                    let discovery = CopilotSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    for url in discovery.discoverSessionFiles() {
                        let base = url.deletingPathExtension().lastPathComponent
                        if !base.isEmpty { map[base] = url }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    CopilotSessionParser.parseFile(at: upstreamURL, forcedID: sessionID)
                        ?? SessionArchiveBackfill.minimalSession(source: .copilot, id: sessionID, url: upstreamURL)
                }
            ),
            supportsResume: true,
            resumeAgentLabel: "Copilot CLI",
            otherAgentPill: PillSpec(color: Color.agentCopilot, shortcut: "5")
        )
    }()
}
