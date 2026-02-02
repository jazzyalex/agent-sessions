import Foundation

/// Scanner for base64 `data:image/*;base64,...` URLs embedded inside OpenCode storage part files.
///
/// OpenCode stores most message text in `storage/part/<messageID>/*.json`. Image attachments can appear as:
/// - `type: "file"` part objects (top-level `url` contains `data:image/...`)
/// - `type: "tool"` part objects (nested `state.attachments[].url` contains `data:image/...`)
enum OpenCodeBase64ImageScanner {
    struct LocatedSpan: Identifiable, Hashable, Sendable {
        let messageID: String
        let partFileURL: URL
        let span: Base64ImageDataURLScanner.Span
        let fileLineIndex: Int

        var id: String { "\(messageID)-\(span.id)" }
    }

    static func fileContainsBase64ImageDataURL(sessionFileURL: URL,
                                               messageIDs: [String],
                                               shouldCancel: () -> Bool = { false }) -> Bool {
        guard let storageRoot = storageRoot(for: sessionFileURL) else { return false }
        if shouldCancel() { return false }

        let layout = storageLayout(storageRoot: storageRoot)
        let partFilesByMessageID = partFilesIndex(storageRoot: storageRoot, layout: layout, messageIDs: messageIDs, shouldCancel: shouldCancel)

        for (messageID, partFiles) in partFilesByMessageID {
            if shouldCancel() { return false }
            if messageID.isEmpty { continue }
            for file in partFiles {
                if shouldCancel() { return false }
                if Base64ImageDataURLScanner.fileContainsBase64ImageDataURL(at: file, shouldCancel: shouldCancel) {
                    return true
                }
            }
        }
        return false
    }

    static func scanSessionPartFiles(sessionFileURL: URL,
                                     messageIDs: [String],
                                     maxMatches: Int = 400,
                                     shouldCancel: () -> Bool = { false }) throws -> [LocatedSpan] {
        guard maxMatches > 0 else { return [] }
        guard let storageRoot = storageRoot(for: sessionFileURL) else { return [] }
        if shouldCancel() { return [] }

        let layout = storageLayout(storageRoot: storageRoot)
        let partFilesByMessageID = partFilesIndex(storageRoot: storageRoot, layout: layout, messageIDs: messageIDs, shouldCancel: shouldCancel)

        var results: [LocatedSpan] = []
        results.reserveCapacity(min(maxMatches, 32))

        for (messageID, files) in partFilesByMessageID.sorted(by: { $0.key < $1.key }) {
            if shouldCancel() { break }
            if messageID.isEmpty { continue }

            for file in files {
                if shouldCancel() { break }
                do {
                    let located = try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: file, maxMatches: maxMatches - results.count, shouldCancel: shouldCancel)
                    for item in located {
                        if shouldCancel() { break }
                        let span = item.span
                        guard span.base64PayloadLength >= 64, span.approxBytes >= 32 else { continue }
                        results.append(LocatedSpan(messageID: messageID, partFileURL: file, span: span, fileLineIndex: item.lineIndex))
                        if results.count >= maxMatches { break }
                    }
                } catch {
                    // Best-effort scan.
                    continue
                }

                if results.count >= maxMatches { break }
            }

            if results.count >= maxMatches { break }
        }

        return results
    }
}

private extension OpenCodeBase64ImageScanner {
    enum StorageSchemaVersion: Int {
        case legacy = 1
        case v2 = 2
    }

    enum StorageLayout {
        case v2
        case legacy
    }

    static func storageRoot(for sessionFileURL: URL) -> URL? {
        // sessionFileURL: ~/.local/share/opencode/storage/session/<projectID>/ses_<ID>.json
        // Strip /ses_<ID>.json -> .../storage/session/<projectID>
        // Strip project -> .../storage/session
        // Strip session -> .../storage
        let candidate = sessionFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return candidate.lastPathComponent == "storage" ? candidate : candidate
    }

    static func storageLayout(storageRoot: URL) -> StorageLayout {
        let migrationURL = storageRoot.appendingPathComponent("migration", isDirectory: false)
        guard let data = try? Data(contentsOf: migrationURL),
              let str = String(data: data, encoding: .utf8) else {
            return .legacy
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = Int(trimmed), let parsed = StorageSchemaVersion(rawValue: v), parsed == .v2 {
            return .v2
        }
        return .legacy
    }

    static func partFilesIndex(storageRoot: URL,
                               layout: StorageLayout,
                               messageIDs: [String],
                               shouldCancel: () -> Bool) -> [String: [URL]] {
        switch layout {
        case .v2:
            var out: [String: [URL]] = [:]
            out.reserveCapacity(min(messageIDs.count, 64))
            for messageID in messageIDs {
                if shouldCancel() { break }
                let partDir = storageRoot
                    .appendingPathComponent("part", isDirectory: true)
                    .appendingPathComponent(messageID, isDirectory: true)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: partDir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                guard let files = try? FileManager.default.contentsOfDirectory(at: partDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continue
                }
                out[messageID] = files
                    .filter { $0.pathExtension.lowercased() == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            return out

        case .legacy:
            // Best-effort: enumerate under `part/` and group by parent folder name.
            let partRoot = storageRoot.appendingPathComponent("part", isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: partRoot.path, isDirectory: &isDir), isDir.boolValue else {
                return [:]
            }
            guard let enumerator = FileManager.default.enumerator(at: partRoot,
                                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                                 options: [.skipsHiddenFiles]) else {
                return [:]
            }
            let requested = Set(messageIDs)
            var out: [String: [URL]] = [:]
            for case let url as URL in enumerator {
                if shouldCancel() { break }
                if url.pathExtension.lowercased() != "json" { continue }
                let parent = url.deletingLastPathComponent().lastPathComponent
                guard requested.isEmpty || requested.contains(parent) else { continue }
                out[parent, default: []].append(url)
            }
            for (k, v) in out {
                out[k] = v.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            return out
        }
    }
}

