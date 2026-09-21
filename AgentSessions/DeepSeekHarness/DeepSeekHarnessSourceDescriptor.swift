import Foundation

extension SessionSourceDescriptor {
    static let deepseekHarness: SessionSourceDescriptor = {
        let isBinaryInstalled: (AvailabilityContext) -> Bool = { $0.detectBinary("dsh") }
        return SessionSourceDescriptor(
            source: .deepseekHarness,
            telemetry: .allUnavailable("DeepSeek telemetry not yet audited"),
            shortLabel: "DeepSeek",
            badgeInitials: "DS",
            enablementKey: DeepSeekHarnessSettings.Keys.enabled,
            cliAvailableKey: DeepSeekHarnessSettings.Keys.cliAvailable,
            rootOverrideKeys: [DeepSeekHarnessSettings.Keys.rootOverride],
            includeKey: DeepSeekHarnessSettings.Keys.include,
            binaryNames: ["dsh"],
            isBinaryInstalled: isBinaryInstalled,
            isAvailable: { ctx in
                let custom = ctx.customRoot(DeepSeekHarnessSettings.Keys.rootOverride)
                let root = DeepSeekHarnessDiscovery(customRoot: custom,
                                                     homeDirectory: ctx.homeDirectory,
                                                     environment: ctx.environment).sessionsRoot()
                return ctx.directoryExists(root) || isBinaryInstalled(ctx)
            },
            defaultEnabled: .whenAvailable,
            parseFullByPath: { DeepSeekHarnessSessionParser.parseFileFull(at: $0) },
            parseFullByIdentity: nil,
            searchUsesIdentityAtURL: nil,
            makeDiscovery: { ctx in
                DeepSeekHarnessDiscovery(customRoot: ctx.customRoot(DeepSeekHarnessSettings.Keys.rootOverride),
                                         homeDirectory: ctx.homeDirectory,
                                         environment: ctx.environment)
            },
            parseLightweightByPath: { DeepSeekHarnessSessionParser.parseFile(at: $0) },
            logicalFileStat: { url in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate else { return nil }
                return SessionFileStat(mtime: Int64(date.timeIntervalSince1970), size: Int64(values.fileSize ?? 0))
            },
            // Directory artifact: the selected generation can move underneath a stored
            // anchor, so freshness resolves through the logical directory, not the file.
            artifactRevision: { DeepSeekHarnessDiscovery.resolveArtifactRevision(forSelectedURL: $0) },
            archive: ArchiveCapability(
                backfillURLs: { defaults in
                    let custom = defaults.string(forKey: DeepSeekHarnessSettings.Keys.rootOverride)
                    let discovery = DeepSeekHarnessDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
                    return DeepSeekHarnessArchiveBackfill.authoritativeURLs(from: discovery.discover())
                },
                sessionForBackfill: { sessionID, upstreamURL in
                    // Restore points at the archived primary (the selected
                    // generation); it full-parses standalone while the archived
                    // older siblings stay retained alongside it.
                    DeepSeekHarnessSessionParser.parseFileFull(at: upstreamURL)
                        ?? SessionArchiveBackfill.minimalSession(source: .deepseekHarness, id: sessionID, url: upstreamURL)
                },
                archiveUnit: { DeepSeekHarnessArchiveFilter.archiveUnit(forPrimary: $0) },
                manifestEntries: { DeepSeekHarnessArchiveFilter.manifestEntries(upstream: $0, primaryRelativePath: $1) },
                // DSH generations churn under a live harness: an unsettled
                // snapshot across the retry budget fails closed, never commits
                // a best-effort copy over a healthy archive.
                requiresStableSnapshot: true
            ),
            supportsResume: false,
            resumeAgentLabel: nil
        )
    }()
}

enum DeepSeekHarnessArchiveBackfill {
    static func authoritativeURLs(from result: DeepSeekHarnessDiscoveryResult) -> [String: URL] {
        // A partial scan can select v2 only because v3 failed stat/read. It may
        // preserve UI rows, but cannot choose the primary for a Saved snapshot.
        guard result.issues.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.id, $0.selectedURL) })
    }
}

// MARK: - DSH archive filter
//
// Safety boundary: the logical session is the selected generation's containing
// directory, but only canonical generation siblings travel with it. The filter
// is flat (exact directory, no recursion, no subdirectories) and anchored at
// the selected primary: same compression encoding, supported generations
// 0...3, generation <= selected (no successors), regular files only, never
// symlinks. DSH workspace.json state is ignored; nothing here resumes.
// Pure file-attribute reads via FileManager.default (no shared mutable state).
private enum DeepSeekHarnessArchiveFilter {
    static func archiveUnit(forPrimary primaryURL: URL) -> ArchiveUnit? {
        guard let parsed = DeepSeekHarnessDiscovery.parseGenerationFilename(primaryURL.lastPathComponent) else { return nil }
        guard (0...3).contains(parsed.generation) else { return nil }
        let fm = FileManager.default
        guard let type = (try? fm.attributesOfItem(atPath: primaryURL.path))?[.type] as? FileAttributeType,
              type == .typeRegular else { return nil }
        let dir = primaryURL.deletingLastPathComponent()
        guard let dirType = (try? fm.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType,
              dirType == .typeDirectory else { return nil }
        guard primaryURL.standardizedFileURL.deletingLastPathComponent() == dir.standardizedFileURL else { return nil }
        return ArchiveUnit(root: dir, isDirectory: true, primaryRelativePath: primaryURL.lastPathComponent)
    }

    static func manifestEntries(upstream: URL, primaryRelativePath: String) -> [String]? {
        guard !primaryRelativePath.isEmpty,
              !primaryRelativePath.contains("/"),
              primaryRelativePath != ".",
              primaryRelativePath != ".." else { return nil }
        guard let primaryParsed = DeepSeekHarnessDiscovery.parseGenerationFilename(primaryRelativePath) else { return nil }
        guard (0...3).contains(primaryParsed.generation) else { return nil }
        let fm = FileManager.default
        guard let dirType = (try? fm.attributesOfItem(atPath: upstream.path))?[.type] as? FileAttributeType,
              dirType == .typeDirectory else { return nil }
        let primaryURL = upstream.appendingPathComponent(primaryRelativePath, isDirectory: false)
        guard primaryURL.standardizedFileURL.deletingLastPathComponent() == upstream.standardizedFileURL else { return nil }
        guard let primaryType = (try? fm.attributesOfItem(atPath: primaryURL.path))?[.type] as? FileAttributeType,
              primaryType == .typeRegular else { return nil }
        guard let children = try? fm.contentsOfDirectory(at: upstream, includingPropertiesForKeys: nil, options: []) else { return nil }
        var out: [String] = []
        for child in children {
            let name = child.lastPathComponent
            guard let parsed = DeepSeekHarnessDiscovery.parseGenerationFilename(name) else { continue }
            guard parsed.compression == primaryParsed.compression else { continue }
            guard (0...3).contains(parsed.generation) else { continue }
            guard parsed.generation <= primaryParsed.generation else { continue }
            guard let type = (try? fm.attributesOfItem(atPath: child.path))?[.type] as? FileAttributeType,
                  type == .typeRegular else { continue }
            out.append(name)
        }
        guard out.contains(primaryRelativePath) else { return nil }
        out.sort()
        return out
    }
}
