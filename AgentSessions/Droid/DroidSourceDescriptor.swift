import Foundation
import SwiftUI
import AppKit

extension SessionSourceDescriptor {
    static let droid: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { ctx in
            ctx.detectBinary("droid")
        }
        return SessionSourceDescriptor(
            source: .droid,
            shortLabel: "Droid",
            badgeInitials: "D",
            // Green brand (disambiguation handled via styling, not hue).
            brandHue: .calibrated(red: 0.16, green: 0.68, blue: 0.28),
            monochromeWhite: 0.8,
            onboardingAccent: { _ in Color(red: 0.26, green: 0.72, blue: 0.38) },
            enablementKey: PreferencesKey.Agents.droidEnabled,
            cliAvailableKey: PreferencesKey.droidCLIAvailable,
            // K3: the only source with two root-override keys. Order matters — the
            // sessions root is the primary probe, the projects root the fallback.
            rootOverrideKeys: [PreferencesKey.Paths.droidSessionsRootOverride,
                               PreferencesKey.Paths.droidProjectsRootOverride],
            includeKey: PreferencesKey.Include.droid,
            binaryNames: ["droid"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let sessionsCustom = ctx.customRoot(PreferencesKey.Paths.droidSessionsRootOverride)
                let projectsCustom = ctx.customRoot(PreferencesKey.Paths.droidProjectsRootOverride)
                let discovery = DroidSessionDiscovery(customSessionsRoot: sessionsCustom,
                                                      customProjectsRoot: projectsCustom)
                if ctx.directoryExists(discovery.sessionsRoot()) { return true }
                if ctx.directoryExists(discovery.projectsRoot()) { return true }
                return isBinaryInstalled(ctx)
            },
            // K7: droid is default-ON at runtime (`isEnabled`'s `default:` branch) even
            // though `seedIfNeeded` seeds it from availability. The disagreement is
            // preserved deliberately — `defaultEnabled` models the runtime rule.
            defaultEnabled: .always,
            parseFullByPath: { url in DroidSessionParser.parseFileFull(at: url) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    var map: [String: URL] = [:]
                    let sessionsCustom = defaults.string(forKey: PreferencesKey.Paths.droidSessionsRootOverride)
                    let projectsCustom = defaults.string(forKey: PreferencesKey.Paths.droidProjectsRootOverride)
                    let discovery = DroidSessionDiscovery(customSessionsRoot: sessionsCustom?.isEmpty == false ? sessionsCustom : nil,
                                                          customProjectsRoot: projectsCustom?.isEmpty == false ? projectsCustom : nil)
                    for url in discovery.discoverSessionFiles() {
                        if let s = DroidSessionParser.parseFile(at: url), !s.id.isEmpty {
                            map[s.id] = url
                        }
                    }
                    return map
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    DroidSessionParser.parseFile(at: upstreamURL, forcedID: sessionID)
                        ?? SessionArchiveBackfill.minimalSession(source: .droid, id: sessionID, url: upstreamURL)
                }
            ),
            // Droid never resumes: `canResumeSession` leaves it to the `default: false`
            // arm, and `resumeAgentLabel` has no arm for it either.
            supportsResume: false,
            resumeAgentLabel: nil,
            otherAgentPill: PillSpec(color: Color.agentDroid, shortcut: "6")
        )
    }()
}
