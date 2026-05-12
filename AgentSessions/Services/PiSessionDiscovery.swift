import Foundation

/// Discovery for Pi canonical session JSONL files under ~/.pi/agent/sessions.
final class PiSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = (customRoot as NSString).expandingTildeInPath
            return normalizedSessionsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            guard isPiSessionFile(url) else { continue }
            files.append(url)
        }

        return files
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if a != b { return a > b }
                return $0.lastPathComponent > $1.lastPathComponent
            }
    }

    private func normalizedSessionsRoot(_ root: URL) -> URL {
        let fm = FileManager.default
        let candidates = [
            root.appendingPathComponent("agent", isDirectory: true).appendingPathComponent("sessions", isDirectory: true),
            root.appendingPathComponent("sessions", isDirectory: true),
            root
        ]

        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return root
    }

    private func isPiSessionFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 64 * 1024)
        guard let prefix = String(data: data, encoding: .utf8),
              let line = prefix.split(separator: "\n", omittingEmptySubsequences: true).first,
              let lineData = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return false
        }

        guard object["type"] as? String == "session" else { return false }
        if let id = object["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }
}
