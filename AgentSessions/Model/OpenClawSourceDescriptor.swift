import Foundation
import SwiftUI
import AppKit

// OpenClaw has no top-level source folder, so its descriptor lives here.

extension SessionSourceDescriptor {
    static let openclaw: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("openclaw") || ctx.detectBinary("clawdbot")
        }
        return SessionSourceDescriptor(
            source: .openclaw,
            shortLabel: "OpenClaw",
            badgeInitials: "CL",
            // Coral-orange accent, kept warm but separated from Claude/Hermes.
            brandHue: .calibrated(red: 0.88, green: 0.33, blue: 0.20),
            monochromeWhite: 0.85,
            onboardingAccent: { _ in Color(red: 0.95, green: 0.55, blue: 0.18) },
            enablementKey: PreferencesKey.Agents.openClawEnabled,
            // K4: the only source with no CLI-availability key at all —
            // `AgentEnablement.storedBinaryPresence(for:)` returns nil outright rather than
            // reading defaults. Modeled as nil rather than fabricating a key name.
            cliAvailableKey: nil,
            // `PreferencesKey.Paths.openClawBinaryOverride` also exists but is a *binary
            // path* override, not a sessions root — deliberately not listed here.
            rootOverrideKeys: [PreferencesKey.Paths.openClawSessionsRootOverride],
            includeKey: PreferencesKey.Include.openclaw,
            binaryNames: ["openclaw", "clawdbot"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(PreferencesKey.Paths.openClawSessionsRootOverride)
                let root = OpenClawSessionDiscovery(customRoot: custom).sessionsRoot()
                if ctx.directoryExists(root) { return true }
                return isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { url in OpenClawSessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    defaults.register(defaults: [
                        PreferencesKey.Advanced.includeOpenClawDeletedSessions: true
                    ])
                    let custom = defaults.string(forKey: PreferencesKey.Paths.openClawSessionsRootOverride)
                    let includeDeleted = defaults.bool(forKey: PreferencesKey.Advanced.includeOpenClawDeletedSessions)
                    let discovery = OpenClawSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil,
                                                             includeDeleted: includeDeleted)
                    for url in discovery.discoverSessionFiles() {
                        if let s = OpenClawSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    OpenClawSessionParser.parseFile(at: upstreamURL, forcedID: sessionID)
                        ?? SessionArchiveBackfill.minimalSession(source: .openclaw, id: sessionID, url: upstreamURL)
                }
            ),
            // OpenClaw never resumes (the `default: false` arm of `canResumeSession`).
            supportsResume: false,
            resumeAgentLabel: nil,
            otherAgentPill: PillSpec(color: Color.agentOpenClaw, shortcut: "7")
        )
    }()
}
