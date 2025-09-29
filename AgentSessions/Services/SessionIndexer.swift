import Foundation
import Combine
import CryptoKit
import SwiftUI

// DEBUG logging helper (no-ops in Release)
#if DEBUG
@inline(__always) private func DBG(_ message: @autoclosure () -> String) {
    print(message())
}
#else
@inline(__always) private func DBG(_ message: @autoclosure () -> String) {}
#endif
// swiftlint:disable type_body_length
final class SessionIndexer: ObservableObject {
    // Source of truth
    @Published private(set) var allSessions: [Session] = []
    // Exposed to UI after filters
    @Published private(set) var sessions: [Session] = []

    @Published var isIndexing: Bool = false
    @Published var progressText: String = ""
    @Published var filesProcessed: Int = 0
    @Published var totalFiles: Int = 0

    // Error states
    @Published var indexingError: String? = nil
    @Published var hasEmptyDirectory: Bool = false

    // Filters
    // Applied query (used for filtering) and draft (typed value)
    @Published var query: String = ""
    @Published var queryDraft: String = ""
    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    @Published var selectedModel: String? = nil
    @Published var selectedKinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)

    // UI focus coordination
    @Published var requestFocusSearch: Bool = false
    @Published var requestTranscriptFindFocus: Bool = false
    @Published var requestCopyPlain: Bool = false
    @Published var requestCopyANSI: Bool = false
    @Published var requestOpenRawSheet: Bool = false
    // Project filter set by clicking the Project cell or via repo: operator
    @Published var projectFilter: String? = nil

    // Sorting (mirrors UI's column sort state)
    struct SessionSortDescriptor: Equatable {
        enum Key: Equatable { case modified, msgs, repo, title }
        var key: Key
        var ascending: Bool
    }
    @Published var sortDescriptor: SessionSortDescriptor = .init(key: .modified, ascending: false)
    // Preferences
    @AppStorage("SessionsRootOverride") var sessionsRootOverride: String = ""
    @AppStorage("TranscriptTheme") private var themeRaw: String = TranscriptTheme.codexDark.rawValue
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true
    @AppStorage("SelectedKindsRaw") private var selectedKindsRaw: String = ""
    @AppStorage("AppAppearance") private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("ModifiedDisplay") private var modifiedDisplayRaw: String = ModifiedDisplay.relative.rawValue
    @AppStorage("TranscriptRenderMode") private var renderModeRaw: String = TranscriptRenderMode.normal.rawValue
    // Column visibility/order prefs
    @AppStorage("ShowModifiedColumn") var showModifiedColumn: Bool = true
    @AppStorage("ShowMsgsColumn") var showMsgsColumn: Bool = true
    @AppStorage("ShowProjectColumn") var showProjectColumn: Bool = true
    @AppStorage("ShowTitleColumn") var showTitleColumn: Bool = true
    // Persist active project filter
    @AppStorage("ProjectFilter") private var projectFilterStored: String = ""

    var prefTheme: TranscriptTheme { TranscriptTheme(rawValue: themeRaw) ?? .codexDark }
    func setTheme(_ t: TranscriptTheme) { themeRaw = t.rawValue }
    var appAppearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .system }
    func setAppearance(_ a: AppAppearance) { appearanceRaw = a.rawValue }

    enum ModifiedDisplay: String, CaseIterable, Identifiable {
        case relative
        case absolute
        var id: String { rawValue }
        var title: String { self == .relative ? "Relative" : "Timestamp" }
    }
    var modifiedDisplay: ModifiedDisplay { ModifiedDisplay(rawValue: modifiedDisplayRaw) ?? .relative }
    func setModifiedDisplay(_ m: ModifiedDisplay) { modifiedDisplayRaw = m.rawValue }
    var transcriptRenderMode: TranscriptRenderMode { TranscriptRenderMode(rawValue: renderModeRaw) ?? .normal }
    func setTranscriptRenderMode(_ m: TranscriptRenderMode) { renderModeRaw = m.rawValue }

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Load persisted project filter
        if !projectFilterStored.isEmpty { projectFilter = projectFilterStored }
        // Debounced computed sessions
        let inputs = Publishers.CombineLatest4(
            $query
                .removeDuplicates(),
            $dateFrom.removeDuplicates(by: Self.dateEq),
            $dateTo.removeDuplicates(by: Self.dateEq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest3(
            inputs,
            $selectedKinds.removeDuplicates(),
            $allSessions
        )
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] input, kinds, all -> [Session] in
                let (q, from, to, model) = input
                let filters = Filters(query: q, dateFrom: from, dateTo: to, model: model, kinds: kinds, repoName: self?.projectFilter, pathContains: nil)
                var results = FilterEngine.filterSessions(all, filters: filters)

                if self?.hideZeroMessageSessionsPref ?? true {
                    results = results.filter { $0.nonMetaCount > 0 }
                }

                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)

        // Load persisted selected kinds on startup
        if !selectedKindsRaw.isEmpty {
            let kinds = selectedKindsRaw.split(separator: ",").compactMap { SessionEventKind(rawValue: String($0)) }
            if !kinds.isEmpty { selectedKinds = Set(kinds) }
        }

        // Persist selected kinds whenever they change (empty string means all kinds)
        $selectedKinds
            .map { kinds -> String in
                if kinds.count == SessionEventKind.allCases.count { return "" }
                return kinds.map { $0.rawValue }.sorted().joined(separator: ",")
            }
            .removeDuplicates()
            .sink { [weak self] raw in self?.selectedKindsRaw = raw }
            .store(in: &cancellables)

        // Persist project filter to AppStorage whenever it changes
        $projectFilter
            .map { $0 ?? "" }
            .removeDuplicates()
            .sink { [weak self] raw in self?.projectFilterStored = raw }
            .store(in: &cancellables)
    }

    func applySearch() {
        // Apply the user's draft query explicitly (not on each keystroke)
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    // Trigger immediate recompute of filtered sessions using current filters (no debounce).
    func recomputeNow() {
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(allSessions, filters: filters)
        if hideZeroMessageSessionsPref { results = results.filter { $0.nonMetaCount > 0 } }
        // FilterEngine now preserves order, so filtered results maintain allSessions sort order
        DispatchQueue.main.async { self.sessions = results }
    }

    var modelsSeen: [String] {
        Array(Set(allSessions.compactMap { $0.model })).sorted()
    }

    var canAccessRootDirectory: Bool {
        let root = sessionsRoot()
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    func sessionsRoot() -> URL {
        if !sessionsRootOverride.isEmpty { return URL(fileURLWithPath: sessionsRootOverride) }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    func refresh() {
        let root = sessionsRoot()
        #if DEBUG
        let t0 = Date()
        DBG("[IDX] start root=\(root.path)")
        #endif
        isIndexing = true
        progressText = "Scanning…"
        filesProcessed = 0
        totalFiles = 0
        indexingError = nil
        hasEmptyDirectory = false

        let fm = FileManager.default
        DispatchQueue.global(qos: .userInitiated).async {
            // Check if directory exists and is accessible
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                DispatchQueue.main.async {
                    self.isIndexing = false
                    self.indexingError = "Sessions directory not found: \(root.path)"
                    self.progressText = "Error"
                }
                return
            }

            var found: [URL] = []
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in en {
                    if url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension.lowercased() == "jsonl" {
                        found.append(url)
                    }
                }
            }
            #if DEBUG
            let t1 = Date()
            DBG(String(format: "[IDX] enumerated files count=%d in %.1f ms", found.count, (t1.timeIntervalSince(t0) * 1000)))
            #endif

            let sortedFiles = found.sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
            #if DEBUG
            let t2 = Date()
            DBG(String(format: "[IDX] sorted in %.1f ms", (t2.timeIntervalSince(t1) * 1000)))
            #endif
            DispatchQueue.main.async {
                self.totalFiles = sortedFiles.count
                self.hasEmptyDirectory = sortedFiles.isEmpty
            }

            var sessions: [Session] = []
            sessions.reserveCapacity(sortedFiles.count)

            var parsedCount = 0
            let total = sortedFiles.count
            for (i, url) in sortedFiles.enumerated() {
                if let session = self.parseFile(at: url) {
                    sessions.append(session)
                }
                DispatchQueue.main.async {
                    self.filesProcessed = i + 1
                    self.progressText = "Indexed \(i + 1)/\(sortedFiles.count)"
                    self.allSessions = sessions.sorted { $0.modifiedAt > $1.modifiedAt }

                }
                #if DEBUG
                parsedCount += 1
                if parsedCount % 50 == 0 || parsedCount == total {
                    let dt = Date().timeIntervalSince(t0) * 1000
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
                    DBG(String(format: "[IDX] parsed %d/%d elapsed=%.0f ms last=%@ size=%d", parsedCount, total, dt, url.lastPathComponent, size))
                }
                #endif
            }

            DispatchQueue.main.async {
                self.isIndexing = false
                #if DEBUG
                DBG(String(format: "[IDX] done total=%d elapsed=%.0f ms", sessions.count, Date().timeIntervalSince(t0) * 1000))
                #endif
            }
        }
    }

    // MARK: - Parsing

    func parseFile(at url: URL) -> Session? {
        #if DEBUG
        let start = Date()
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        DBG("[FILE] start path=\(url.path) size=\(size) mtime=\(ISO8601DateFormatter().string(from: mtime)))")
        var linesRead = 0
        var dataImageLines = 0
        #endif
        let reader = JSONLReader(url: url)
        var events: [SessionEvent] = []
        var modelSeen: String? = nil
        var idx = 0
        do {
            try reader.forEachLine { line in
                idx += 1
                #if DEBUG
                linesRead += 1
                if line.contains("data:image") || line.contains("\"input_image\"") { dataImageLines += 1 }
                #endif
                let (event, maybeModel) = Self.parseLine(line, eventID: self.eventID(for: url, index: idx))
                if let m = maybeModel, modelSeen == nil { modelSeen = m }
                events.append(event)
            }
        } catch {
            // If file can't be read, emit a single error meta event
            let event = SessionEvent(id: eventID(for: url, index: 0), timestamp: Date(), kind: .error, role: "system", text: "Failed to read: \(error.localizedDescription)", toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
            events.append(event)
        }

        let times = events.compactMap { $0.timestamp }
        var start = times.min()
        var end = times.max()
        if start == nil || end == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if start == nil { start = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) }
                if end == nil { end = (attrs[.modificationDate] as? Date) ?? start }
            }
        }
        let id = Self.hash(path: url.path)
        #if DEBUG
        let totalMs = Date().timeIntervalSince(start) * 1000
        if totalMs > 1000 {
            DBG(String(format: "[FILE][SLOW] path=%@ size=%d lines=%d elapsed=%.0f ms", url.lastPathComponent, size, linesRead, totalMs))
        } else {
            DBG(String(format: "[FILE] parsed path=%@ events=%d lines=%d elapsed=%.0f ms", url.lastPathComponent, events.count, linesRead, totalMs))
        }
        if dataImageLines > 0 { DBG("[FILE][EMBEDDED] data_image_lines=\(dataImageLines) path=\(url.lastPathComponent)") }
        #endif
        let session = Session(id: id, startTime: start, endTime: end, model: modelSeen, filePath: url.path, eventCount: events.count, events: events)
        return session
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func parseLine(_ line: String, eventID: String) -> (SessionEvent, String?) {
        var timestamp: Date? = nil
        var role: String? = nil
        var type: String? = nil
        var text: String? = nil
        var toolName: String? = nil
        var toolInput: String? = nil
        var toolOutput: String? = nil
        var model: String? = nil
        var messageID: String? = nil
        var parentID: String? = nil
        var isDelta: Bool = false

        if let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // timestamp could be number or string, and under various keys
            let tsKeys = [
                "timestamp", "time", "ts", "created", "created_at", "datetime", "date",
                "event_time", "eventTime", "iso_timestamp", "when", "at"
            ]
            for key in tsKeys {
                if let v = obj[key] { timestamp = timestamp ?? Self.decodeDate(from: v) }
            }

            // Check for nested payload structure (Codex format)
            var workingObj = obj
            if let payload = obj["payload"] as? [String: Any] {
                // Merge payload fields into working object
                workingObj = payload
                // Also check payload for timestamp if not found at top level
                if timestamp == nil {
                    for key in tsKeys {
                        if let v = payload[key] { timestamp = timestamp ?? Self.decodeDate(from: v) }
                    }
                }
            }

            // role / type (now checking in payload if present)
            if let r = workingObj["role"] as? String { role = r }
            if let t = workingObj["type"] as? String { type = t }
            if type == nil, let e = workingObj["event"] as? String { type = e }

            // model (check both top-level and payload)
            if let m = obj["model"] as? String { model = m }
            if model == nil, let m = workingObj["model"] as? String { model = m }

            // delta / chunk identifiers
            if let mid = workingObj["message_id"] as? String { messageID = mid }
            if let pid = workingObj["parent_id"] as? String { parentID = pid }
            if let idFromObj = workingObj["id"] as? String, messageID == nil { messageID = idFromObj }
            if let d = workingObj["delta"] as? Bool { isDelta = isDelta || d }
            if workingObj["delta"] is [String: Any] { isDelta = true }
            if workingObj["chunk"] != nil { isDelta = true }
            if workingObj["delta_index"] != nil { isDelta = true }

            // text content variants
            if let content = workingObj["content"] as? String { text = content }
            if text == nil, let txt = workingObj["text"] as? String { text = txt }
            if text == nil, let msg = workingObj["message"] as? String { text = msg }
            // Assistant content arrays: concatenate text parts
            if text == nil, let arr = workingObj["content"] as? [Any] {
                var pieces: [String] = []
                for el in arr {
                    if let d = el as? [String: Any] {
                        if let t = d["text"] as? String { pieces.append(t) }
                        else if let val = d["value"] as? String { pieces.append(val) }
                        else if let data = d["data"] as? String { pieces.append(data) }
                    } else if let s = el as? String { pieces.append(s) }
                }
                if !pieces.isEmpty { text = pieces.joined() }
            }

            // Heuristic: environment_context appears as an XML-ish block often logged under 'user'.
            // Treat any event whose text contains this block as meta regardless of role/type.
            if let t = text, t.contains("<environment_context>") { type = "environment_context" }

            // tool fields
            if let t = workingObj["tool"] as? String { toolName = t }
            if toolName == nil, let name = workingObj["name"] as? String { toolName = name }
            if toolName == nil, let fn = (workingObj["function"] as? [String: Any])?["name"] as? String { toolName = fn }

            if let input = workingObj["input"] as? String { toolInput = input }
            if toolInput == nil, let args = workingObj["arguments"] as? String { toolInput = args }
            // Arguments may be non-string; minify to single-line JSON
            if toolInput == nil, let argsObj = workingObj["arguments"] {
                if let s = Self.stringifyJSON(argsObj, pretty: false) { toolInput = s }
            }

            // Outputs: stdout, stderr, result, output (in this stable order)
            var outputs: [String] = []
            if let stdout = workingObj["stdout"] { outputs.append(Self.stringifyJSON(stdout, pretty: true) ?? String(describing: stdout)) }
            if let stderr = workingObj["stderr"] { outputs.append(Self.stringifyJSON(stderr, pretty: true) ?? String(describing: stderr)) }
            if let result = workingObj["result"] { outputs.append(Self.stringifyJSON(result, pretty: true) ?? String(describing: result)) }
            if let output = workingObj["output"] { outputs.append(Self.stringifyJSON(output, pretty: true) ?? String(describing: output)) }
            if !outputs.isEmpty {
                toolOutput = outputs.joined(separator: "\n")
            }
            // Back-compat if values above were strings only
            if toolOutput == nil, let out = workingObj["output"] as? String { toolOutput = out }
            if toolOutput == nil, let res = workingObj["result"] as? String { toolOutput = res }
        }

        let kind = SessionEventKind.from(role: role, type: type)
        let event = SessionEvent(
            id: eventID,
            timestamp: timestamp,
            kind: kind,
            role: role,
            text: text,
            toolName: toolName,
            toolInput: toolInput,
            toolOutput: toolOutput,
            messageID: messageID,
            parentID: parentID,
            isDelta: isDelta,
            rawJSON: line
        )
        return (event, model)
    }

    private func eventID(for url: URL, index: Int) -> String {
        let base = Self.hash(path: url.path)
        return base + String(format: "-%04d", index)
    }

    private static func hash(path: String) -> String {
        let d = SHA256.hash(data: Data(path.utf8))
        return d.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func decodeDate(from any: Any) -> Date? {
        // Numeric (seconds, ms, µs)
        if let d = any as? Double {
            let secs = normalizeEpochSeconds(d)
            return Date(timeIntervalSince1970: secs)
        }
        if let i = any as? Int {
            let secs = normalizeEpochSeconds(Double(i))
            return Date(timeIntervalSince1970: secs)
        }
        if let s = any as? String {
            // Digits-only string → numeric epoch
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: s)) {
                if let val = Double(s) { return Date(timeIntervalSince1970: normalizeEpochSeconds(val)) }
            }
            // ISO8601 with or without fractional seconds
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            let isoNoFrac = ISO8601DateFormatter()
            isoNoFrac.formatOptions = [.withInternetDateTime]
            if let d = isoNoFrac.date(from: s) { return d }
            // Common fallbacks
            let fmts = [
                "yyyy-MM-dd HH:mm:ssZZZZZ",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy/MM/dd HH:mm:ssZZZZZ",
                "yyyy/MM/dd HH:mm:ss"
            ]
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            for f in fmts { df.dateFormat = f; if let d = df.date(from: s) { return d } }
        }
        return nil
    }

    private static func normalizeEpochSeconds(_ value: Double) -> Double {
        // Heuristic: >1e14 → microseconds; >1e11 → milliseconds; else seconds
        if value > 1e14 { return value / 1_000_000 }
        if value > 1e11 { return value / 1_000 }
        return value
    }

    private static func stringifyJSON(_ any: Any, pretty: Bool) -> String? {
        // If it's already a String, return as-is
        if let s = any as? String { return s }
        // Numbers, bools, arrays, dicts → JSON text
        if JSONSerialization.isValidJSONObject(any) {
            if let data = try? JSONSerialization.data(withJSONObject: any, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]) {
                return String(data: data, encoding: .utf8)
            }
        } else {
            // Wrap simple types into JSON-compatible representation
            if let n = any as? NSNumber { return n.stringValue }
            if let b = any as? Bool { return b ? "true" : "false" }
        }
        return nil
    }

    private static func dateEq(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) < 0.5
        default: return false
        }
    }
}
// swiftlint:enable type_body_length

// (Codex picker parity helpers temporarily disabled while focusing on title parity.)
