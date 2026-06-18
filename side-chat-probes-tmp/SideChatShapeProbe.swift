import Foundation

struct Counter<Key: Hashable> {
    private(set) var values: [Key: Int] = [:]

    mutating func add(_ key: Key, by amount: Int = 1) {
        values[key, default: 0] += amount
    }

    func top(_ limit: Int) -> [(Key, Int)] {
        values
            .sorted {
                if $0.value == $1.value {
                    return String(describing: $0.key) < String(describing: $1.key)
                }
                return $0.value > $1.value
            }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }
}

struct FileSummary {
    let path: String
    var topLevelTypes = Counter<String>()
    var eventMsgTypes = Counter<String>()
    var eventMsgKeys = Counter<String>()
    var sourceKinds = Counter<String>()
    var threadKeyCounts = Counter<String>()
    var distinctThreadIDs = Set<String>()
    var sideLikeMarkerCount = 0
    var lineCount = 0

    var hasSideLikeMarker: Bool { sideLikeMarkerCount > 0 }
    var hasMultipleThreadIDs: Bool { distinctThreadIDs.count > 1 }
}

let threadKeys: Set<String> = [
    "threadId",
    "thread_id",
    "sender_thread_id",
    "receiver_thread_id",
    "new_thread_id",
    "parent_thread_id"
]

let sideNeedles = [
    "side",
    "sidechat",
    "side_chat",
    "side-thread",
    "side_thread",
    "/side",
    "/btw",
    "btw"
]

func usage() -> Never {
    fputs("""
    Usage:
      SideChatShapeProbe [--state-db PATH] [--max-files N] [--scan-values] ROOT...

    Scans Codex JSONL roots and prints aggregate schema evidence only.
    It does not print user/assistant message text.

    """, stderr)
    exit(2)
}

func allJSONLFiles(under root: String) -> [String] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue {
        return root.hasSuffix(".jsonl") ? [root] : []
    }

    let rootURL = URL(fileURLWithPath: root)
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var files: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
        files.append(url.path)
    }
    return files.sorted()
}

func parseJSONObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

func compactSourceKind(_ source: Any?) -> String {
    guard let source else { return "<missing>" }
    if let string = source as? String { return string }
    if let dict = source as? [String: Any] {
        if dict["subagent"] != nil { return "subagent-dict" }
        return "dict"
    }
    return String(describing: type(of: source))
}

func collectThreadIDs(from payload: [String: Any], into summary: inout FileSummary) {
    for key in threadKeys {
        guard let value = payload[key] else { continue }
        summary.threadKeyCounts.add(key)
        if let string = value as? String, !string.isEmpty {
            summary.distinctThreadIDs.insert(string)
        }
    }
}

func containsSideLikeMarker(_ object: Any, scanValues: Bool) -> Bool {
    if let string = object as? String {
        guard scanValues else { return false }
        let lowered = string.lowercased()
        return sideNeedles.contains { lowered.contains($0) }
    }
    if let array = object as? [Any] {
        return array.contains { containsSideLikeMarker($0, scanValues: scanValues) }
    }
    if let dict = object as? [String: Any] {
        for (key, value) in dict {
            let loweredKey = key.lowercased()
            if sideNeedles.contains(where: { loweredKey.contains($0) }) {
                return true
            }
            if containsSideLikeMarker(value, scanValues: scanValues) {
                return true
            }
        }
    }
    return false
}

func scanFile(_ path: String, scanValues: Bool) -> FileSummary {
    var summary = FileSummary(path: path)
    guard let handle = FileHandle(forReadingAtPath: path) else { return summary }
    defer { try? handle.close() }

    let data = handle.readDataToEndOfFile()
    guard let content = String(data: data, encoding: .utf8) else { return summary }

    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
        summary.lineCount += 1
        guard let object = parseJSONObject(String(line)) else { continue }
        let topType = object["type"] as? String ?? "<missing>"
        summary.topLevelTypes.add(topType)

        if containsSideLikeMarker(object, scanValues: scanValues) {
            summary.sideLikeMarkerCount += 1
        }

        if topType == "session_meta",
           let payload = object["payload"] as? [String: Any] {
            summary.sourceKinds.add(compactSourceKind(payload["source"]))
            if let id = payload["id"] as? String, !id.isEmpty {
                summary.distinctThreadIDs.insert(id)
            }
            if let source = payload["source"] as? [String: Any],
               let subagent = source["subagent"] as? [String: Any],
               let threadSpawn = subagent["thread_spawn"] as? [String: Any] {
                collectThreadIDs(from: threadSpawn, into: &summary)
            }
        }

        if topType == "event_msg",
           let payload = object["payload"] as? [String: Any] {
            for key in payload.keys {
                summary.eventMsgKeys.add(key)
            }
            summary.eventMsgTypes.add(payload["type"] as? String ?? "<missing>")
            collectThreadIDs(from: payload, into: &summary)
        }
    }

    return summary
}

func printCounter(_ title: String, _ counter: Counter<String>, limit: Int = 20) {
    print("\n\(title)")
    for (key, count) in counter.top(limit) {
        print("  \(count)\t\(key)")
    }
}

func sqliteScalarRows(dbPath: String, sql: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [dbPath, sql]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

var args = Array(CommandLine.arguments.dropFirst())
var stateDB: String?
var maxFiles: Int?
var scanValues = false
var roots: [String] = []

while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--state-db":
        guard let value = args.first else { usage() }
        args.removeFirst()
        stateDB = value
    case "--max-files":
        guard let value = args.first, let parsed = Int(value), parsed > 0 else { usage() }
        args.removeFirst()
        maxFiles = parsed
    case "--scan-values":
        scanValues = true
    case "-h", "--help":
        usage()
    default:
        roots.append(arg)
    }
}

guard !roots.isEmpty else { usage() }

let discoveredFiles = roots.flatMap(allJSONLFiles)
let files = discoveredFiles
    .sorted { lhs, rhs in
        let lhsDate = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
        let rhsDate = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
        if lhsDate == rhsDate { return lhs < rhs }
        return lhsDate > rhsDate
    }
    .prefix(maxFiles ?? discoveredFiles.count)
print("Scanned files: \(files.count)")

var globalTopTypes = Counter<String>()
var globalEventMsgTypes = Counter<String>()
var globalEventMsgKeys = Counter<String>()
var globalSourceKinds = Counter<String>()
var globalThreadKeys = Counter<String>()
var sideLikeFiles: [FileSummary] = []
var multiThreadFiles: [FileSummary] = []

for file in files {
    let summary = scanFile(file, scanValues: scanValues)
    for (key, count) in summary.topLevelTypes.values { globalTopTypes.add(key, by: count) }
    for (key, count) in summary.eventMsgTypes.values { globalEventMsgTypes.add(key, by: count) }
    for (key, count) in summary.eventMsgKeys.values { globalEventMsgKeys.add(key, by: count) }
    for (key, count) in summary.sourceKinds.values { globalSourceKinds.add(key, by: count) }
    for (key, count) in summary.threadKeyCounts.values { globalThreadKeys.add(key, by: count) }
    if summary.hasSideLikeMarker { sideLikeFiles.append(summary) }
    if summary.hasMultipleThreadIDs { multiThreadFiles.append(summary) }
}

printCounter("Top-level event types", globalTopTypes)
printCounter("event_msg payload types", globalEventMsgTypes)
printCounter("event_msg payload keys", globalEventMsgKeys)
printCounter("session_meta payload.source shapes", globalSourceKinds)
printCounter("Thread-routing keys seen", globalThreadKeys)

print("\nFiles with side-like marker \(scanValues ? "strings/keys" : "keys"): \(sideLikeFiles.count)")
for item in sideLikeFiles.prefix(20) {
    print("  markers=\(item.sideLikeMarkerCount)\t\(item.path)")
}

print("\nFiles with multiple distinct thread-ish IDs: \(multiThreadFiles.count)")
for item in multiThreadFiles.prefix(20) {
    print("  ids=\(item.distinctThreadIDs.count)\t\(item.path)")
}

if let stateDB {
    print("\nState DB: \(stateDB)")
    if let tables = sqliteScalarRows(dbPath: stateDB, sql: ".tables") {
        let tableList = tables
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .joined(separator: ", ")
        print("Tables: \(tableList)")
    }
    if let threadSources = sqliteScalarRows(
        dbPath: stateDB,
        sql: "SELECT COALESCE(thread_source,'<null>') || '|' || COUNT(*) FROM threads GROUP BY thread_source ORDER BY COUNT(*) DESC;"
    ) {
        print("threads.thread_source counts:")
        for line in threadSources.split(separator: "\n") {
            print("  \(line)")
        }
    }
    if let sideTables = sqliteScalarRows(
        dbPath: stateDB,
        sql: "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '%side%' OR name LIKE '%conversation%') ORDER BY name;"
    ) {
        let trimmed = sideTables.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "<none>" : trimmed
        print("side/conversation-like tables: \(display)")
    }
}
