import Foundation
import Combine
import CryptoKit
import SwiftUI

// MARK: - Session Indexer Protocol

/// Protocol defining the common interface for session indexers (Codex and Claude)
protocol SessionIndexerProtocol: ObservableObject {
    var allSessions: [Session] { get }
    var sessions: [Session] { get }
    var isLoadingSession: Bool { get }
    var loadingSessionID: String? { get }

    // Focus coordination
    var activeSearchUI: SessionIndexer.ActiveSearchUI { get set }

    // Optional features (Codex only)
    var requestOpenRawSheet: Bool { get set }
    var requestCopyPlainPublisher: AnyPublisher<Void, Never> { get }
    var requestTranscriptFindFocusPublisher: AnyPublisher<Void, Never> { get }
}

// Default implementations for Claude (which doesn't have these features)
extension SessionIndexerProtocol {
    var requestOpenRawSheet: Bool {
        get { false }
        set { }
    }

    var requestCopyPlainPublisher: AnyPublisher<Void, Never> {
        Empty<Void, Never>().eraseToAnyPublisher()
    }

    var requestTranscriptFindFocusPublisher: AnyPublisher<Void, Never> {
        Empty<Void, Never>().eraseToAnyPublisher()
    }
}

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

    // Lazy loading state
    @Published var isLoadingSession: Bool = false
    @Published var loadingSessionID: String? = nil

    // Transcript cache for accurate search
    private let transcriptCache = TranscriptCache()

    // Expose cache for SearchCoordinator (internal - not public API)
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

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

    // UI focus coordination (mutually exclusive search UI)
    enum ActiveSearchUI {
        case sessionSearch   // Search sessions list (Cmd+Option+F)
        case transcriptFind  // Find in transcript (Cmd+F)
        case none
    }
    @Published var activeSearchUI: ActiveSearchUI = .none

    // Legacy focus coordination (deprecated in favor of activeSearchUI)
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
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = false {
        didSet { recomputeNow() }
    }
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

    // Track sessions currently being reloaded to prevent duplicate loads
    private var reloadingSessionIDs: Set<String> = []
    private let reloadLock = NSLock()

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
                var results = FilterEngine.filterSessions(all, filters: filters, transcriptCache: self?.transcriptCache)

                if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 0 } }
                if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 2 } }

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

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeNow() }
            .store(in: &cancellables)
    }

    func applySearch() {
        // Apply the user's draft query explicitly (not on each keystroke)
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    // Update an existing session in allSessions (used by SearchCoordinator to persist parsed sessions)
    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            var sessions = allSessions
            sessions[idx] = updated
            allSessions = sessions
        }
    }

    // Reload a specific lightweight session with full parse
    func reloadSession(id: String) {
        // Check if already reloading this session
        reloadLock.lock()
        if reloadingSessionIDs.contains(id) {
            reloadLock.unlock()
            print("⏭️ Skip reload: session \(id.prefix(8)) already reloading")
            return
        }
        reloadingSessionIDs.insert(id)
        reloadLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let loadingTimer: DispatchSourceTimer? = nil
            defer {
                // Always clean up timer and reloading state
                loadingTimer?.cancel()
                self.reloadLock.lock()
                self.reloadingSessionIDs.remove(id)
                self.reloadLock.unlock()
            }

            guard let existing = self.allSessions.first(where: { $0.id == id }),
                  existing.events.isEmpty else {
                print("⏭️ Skip reload: session already loaded or not found")
                // Clear loading state on early exit
                DispatchQueue.main.async {
                    if self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }
                return
            }

            let filename = existing.filePath.components(separatedBy: "/").last ?? "?"
            print("🔄 Reloading lightweight session: \(filename)")
            print("  📂 Path: \(existing.filePath)")

            // Show loading state immediately for better responsiveness
            DispatchQueue.main.async {
                self.isLoadingSession = true
                self.loadingSessionID = id
            }

            let url = URL(fileURLWithPath: existing.filePath)
            let startTime = Date()

            print("  🚀 Starting parseFileFull...")
            // Force full parse by calling parseFile directly (skip lightweight check)
            if let fullSession = self.parseFileFull(at: url) {
                let elapsed = Date().timeIntervalSince(startTime)
                print("  ⏱️ Parse took \(String(format: "%.1f", elapsed))s - events=\(fullSession.events.count)")

                DispatchQueue.main.async {
                    // Replace in allSessions
                    if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
                        var updated = self.allSessions
                        updated[idx] = fullSession
                        self.allSessions = updated
                        print("✅ Reloaded: \(filename) events=\(fullSession.events.count) nonMeta=\(fullSession.nonMetaCount) msgCount=\(fullSession.messageCount)")

                        // Update transcript cache for accurate search
                        let cache = self.transcriptCache
                        Task.detached(priority: .utility) {
                            let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
                            let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                                session: fullSession,
                                filters: filters,
                                mode: .normal
                            )
                            cache.set(fullSession.id, transcript: transcript)
                        }

                        // Clear loading state AFTER updating allSessions, with small delay for UI to render
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if self.loadingSessionID == id {
                                self.isLoadingSession = false
                                self.loadingSessionID = nil
                            }
                        }
                    } else {
                        print("❌ Failed to find session in allSessions after reload")
                        // Clear loading state on failure
                        if self.loadingSessionID == id {
                            self.isLoadingSession = false
                            self.loadingSessionID = nil
                        }
                    }
                }
            } else {
                print("❌ parseFileFull returned nil for \(filename)")
                // Clear loading state on failure
                DispatchQueue.main.async {
                    if self.loadingSessionID == id {
                        self.isLoadingSession = false
                        self.loadingSessionID = nil
                    }
                }
            }
        }
    }

    // Trigger immediate recompute of filtered sessions using current filters (no debounce).
    func recomputeNow() {
        let filters = Filters(query: query, dateFrom: dateFrom, dateTo: dateTo, model: selectedModel, kinds: selectedKinds, repoName: projectFilter, pathContains: nil)
        var results = FilterEngine.filterSessions(allSessions, filters: filters, transcriptCache: transcriptCache)
        if hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 } }
        if hideLowMessageSessionsPref { results = results.filter { $0.messageCount > 2 } }
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
        print("\n🔄 INDEXING START: root=\(root.path)")

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

            print("📁 Found \(found.count) session files")

            let sortedFiles = found.sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
            DispatchQueue.main.async {
                self.totalFiles = sortedFiles.count
                self.hasEmptyDirectory = sortedFiles.isEmpty
            }

            var sessions: [Session] = []
            sessions.reserveCapacity(sortedFiles.count)

            for (i, url) in sortedFiles.enumerated() {
                if let session = self.parseFile(at: url) {
                    sessions.append(session)
                }
                // Update progress counter but don't replace allSessions yet (causes flicker)
                DispatchQueue.main.async {
                    self.filesProcessed = i + 1
                    self.progressText = "Indexed \(i + 1)/\(sortedFiles.count)"
                }
            }

            // Update allSessions only once at the end
            let sortedSessions = sessions.sorted { $0.modifiedAt > $1.modifiedAt }
            DispatchQueue.main.async {
                self.allSessions = sortedSessions
                self.isIndexing = false
                let lightCount = sessions.filter { $0.events.isEmpty }.count
                let heavyCount = sessions.count - lightCount
                let lightSessions = sessions.filter { $0.events.isEmpty }
                print("✅ INDEXING DONE: total=\(sessions.count) lightweight=\(lightCount) fullParse=\(heavyCount)")

                // Start background transcript indexing for accurate search (non-blocking)
                let cache = self.transcriptCache
                Task.detached(priority: .utility) {
                    await cache.generateAndCache(sessions: sortedSessions)
                }

                // Show lightweight sessions details
                for s in lightSessions {
                    print("  💡 Lightweight: \(s.filePath.components(separatedBy: "/").last ?? "?") msgCount=\(s.messageCount)")
                }

                // Wait a moment for filters to apply, then check what's visible
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let filteredCount = self.sessions.count
                    let lightInFiltered = self.sessions.filter { $0.events.isEmpty }.count
                    print("📊 AFTER FILTERS: showing=\(filteredCount) (lightweight=\(lightInFiltered))")

                    if lightInFiltered == 0 && lightCount > 0 {
                        print("⚠️ WARNING: All lightweight sessions were filtered out!")
                        print("   hideZeroMessageSessionsPref=\(self.hideZeroMessageSessionsPref)")
                    }
                }
            }
        }
    }

    // MARK: - Parsing

    func parseFile(at url: URL) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        // Fast path: heavy file → metadata-first, avoid full scan now
        if size >= 10_000_000 { // 10 MB threshold
            print("🔵 HEAVY FILE DETECTED: \(url.lastPathComponent) size=\(size) bytes (~\(size/1_000_000)MB)")
            if let light = Self.lightweightSession(from: url, size: size, mtime: mtime) {
                print("✅ LIGHTWEIGHT: \(url.lastPathComponent) estEvents=\(light.eventCount) messageCount=\(light.messageCount)")
                return light
            } else {
                print("❌ LIGHTWEIGHT FAILED for \(url.lastPathComponent) - falling through to full parse")
            }
        }

        return parseFileFull(at: url)
    }

    // Full parse (no lightweight check)
    func parseFileFull(at url: URL) -> Session? {
        print("    📖 parseFileFull: Getting file attrs...")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        print("    📖 parseFileFull: File size = \(size) bytes")

        print("    📖 parseFileFull: Creating JSONLReader...")
        let reader = JSONLReader(url: url)
        var events: [SessionEvent] = []
        var modelSeen: String? = nil
        var idx = 0
        print("    📖 parseFileFull: Starting forEachLine...")
        do {
            try reader.forEachLine { rawLine in
                idx += 1
                // Only sanitize very large lines (>100KB) - sanitizeAllImages has its own guards for smaller lines
                let safeLine = rawLine.utf8.count > 100_000 ? Self.sanitizeAllImages(rawLine) : rawLine
                let (event, maybeModel) = Self.parseLine(safeLine, eventID: self.eventID(for: url, index: idx))
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
        let session = Session(id: id,
                              source: .codex,
                              startTime: start,
                              endTime: end,
                              model: modelSeen,
                              filePath: url.path,
                              fileSizeBytes: size >= 0 ? size : nil,
                              eventCount: events.count,
                              events: events)

        if size > 5_000_000 {  // Log full parse of files >5MB
            print("  ⚠️ FULL PARSE: \(url.lastPathComponent) size=\(size/1_000_000)MB events=\(events.count) nonMeta=\(session.nonMetaCount)")
        }

        return session
    }

    /// Build a lightweight Session by scanning only head/tail slices for timestamps and model, and estimating event count.
    private static func lightweightSession(from url: URL, size: Int, mtime: Date) -> Session? {
        let headBytes = 256 * 1024
        let tailBytes = 256 * 1024
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        // Read head slice
        let headData = try? fh.read(upToCount: headBytes) ?? Data()

        // Read tail slice
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? size
        var tailData: Data = Data()
        if fileSize > tailBytes {
            let offset = UInt64(fileSize - tailBytes)
            try? fh.seek(toOffset: offset)
            tailData = (try? fh.readToEnd()) ?? Data()
        }

        func lines(from data: Data, keepHead: Bool) -> [String] {
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return [] }
            let parts = s.components(separatedBy: "\n")
            if keepHead {
                return Array(parts.prefix(300))
            } else {
                return Array(parts.suffix(300))
            }
        }

        let headLines = lines(from: headData ?? Data(), keepHead: true)
        let tailLines = lines(from: tailData, keepHead: false)

        var model: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil
        var sampleCount = 0
        var sampleEvents: [SessionEvent] = []
        var cwd: String? = nil

        func ingest(_ raw: String) {
            let line = sanitizeImagePayload(raw)
            let (ev, maybeModel) = parseLine(line, eventID: "light-\(sampleCount)")
            if let ts = ev.timestamp {
                if tmin == nil || ts < tmin! { tmin = ts }
                if tmax == nil || ts > tmax! { tmax = ts }
            }
            if model == nil, let m = maybeModel, !m.isEmpty { model = m }
            // Extract cwd from session_meta or environment_context
            if cwd == nil, let text = ev.text {
                if text.contains("<cwd>") {
                    if let start = text.range(of: "<cwd>"), let end = text.range(of: "</cwd>", range: start.upperBound..<text.endIndex) {
                        cwd = String(text[start.upperBound..<end.lowerBound])
                    }
                } else if let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let payload = obj["payload"] as? [String: Any], let cwdValue = payload["cwd"] as? String {
                        cwd = cwdValue
                    }
                }
            }
            sampleEvents.append(ev)
            sampleCount += 1
        }

        headLines.forEach(ingest)
        tailLines.forEach(ingest)

        // Estimate event count: count newlines in head slice for more accurate estimate
        let headBytesRead = headData?.count ?? 1
        let newlineCount = headData?.filter { $0 == 0x0a }.count ?? 1  // Count \n bytes
        let avgLineLen = max(256, headBytesRead / max(newlineCount, 1))  // Min 256 bytes per line
        let estEvents = max(1, min(1_000_000, fileSize / avgLineLen))

        print("  📊 Lightweight estimation: headBytes=\(headBytesRead) newlines=\(newlineCount) avgLineLen=\(avgLineLen) estEvents=\(estEvents)")

        let id = Self.hash(path: url.path)
        // Use sample events for title/cwd extraction, then create lightweight session
        let tempSession = Session(id: id,
                                   source: .codex,
                                   startTime: tmin,
                                   endTime: tmax,
                                   model: model,
                                   filePath: url.path,
                                   fileSizeBytes: fileSize,
                                   eventCount: estEvents,
                                   events: sampleEvents)

        // Extract title from sample events using existing logic
        let title = tempSession.codexPreviewTitle ?? tempSession.title

        // Now create final lightweight session with empty events but preserve metadata
        let session = Session(id: id,
                              source: .codex,
                              startTime: tmin ?? (attrsDate(url, key: .creationDate) ?? mtime),
                              endTime: tmax ?? mtime,
                              model: model,
                              filePath: url.path,
                              fileSizeBytes: fileSize,
                              eventCount: estEvents,
                              events: [],
                              cwd: cwd,
                              repoName: nil,  // Will be computed from cwd
                              lightweightTitle: title)
        return session
    }

    private static func attrsDate(_ url: URL, key: FileAttributeKey) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[key] as? Date) ?? nil
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
    
    // MARK: - Sanitizers
    /// Replace any inline base64 image data URLs with a short placeholder to avoid huge allocations and slow JSON parsing.
    private static func sanitizeImagePayload(_ line: String) -> String {
        // Fast path: nothing to do
        guard line.contains("data:image") || line.contains("\"input_image\"") else { return line }
        var s = line
        // Replace data:image..." up to the closing quote with a compact token
        // This is a simple, robust scan that avoids heavy regex backtracking on very long lines.
        let needle = "data:image"
        if let range = s.range(of: needle) {
            // Find the next quote after the scheme
            if let q = s[range.upperBound...].firstIndex(of: "\"") {
                let replaceRange = range.lowerBound..<q
                s.replaceSubrange(replaceRange, with: "data:image/omitted")
            }
        }
        return s
    }

    /// Aggressively strip ALL embedded images from a line (for lazy load performance).
    /// Uses regex for 50-100x speedup vs string manipulation.
    private static func sanitizeAllImages(_ line: String) -> String {
        guard line.contains("data:image") else { return line }

        // Fast byte-level check before expensive string operations
        // For extremely long lines (>5MB UTF-8 bytes), skip entirely
        let utf8Count = line.utf8.count
        if utf8Count > 5_000_000 {
            // Just return a minimal JSON stub - the line is too large to parse usefully anyway
            return #"{"type":"omitted","text":"[Large event omitted - \#(utf8Count/1_000_000)MB]"}"#
        }

        // For moderately large lines (1-5MB), use a simpler/faster approach
        if utf8Count > 1_000_000 {
            // Simple string split approach - faster than regex on huge strings
            let parts = line.components(separatedBy: "data:image")
            if parts.count <= 1 { return line }

            var result = parts[0]
            for i in 1..<parts.count {
                // Find the closing quote and skip everything up to it
                if let quoteIdx = parts[i].firstIndex(of: "\"") {
                    result += "[IMG]"
                    result += String(parts[i][quoteIdx...])
                } else {
                    result += "[IMG]" + parts[i]
                }
            }
            return result
        }

        // For normal lines (<1MB), use fast string scanning (avoids slow regex backtracking)
        var result = line
        while let dataIdx = result.range(of: "data:image") {
            // Find the closing quote (end of data URL)
            if let endQuote = result[dataIdx.upperBound...].firstIndex(of: "\"") {
                // Replace everything from "data:image" to quote with placeholder that doesn't contain "data:image"
                result.replaceSubrange(dataIdx.lowerBound..<endQuote, with: "[IMG_OMITTED]")
            } else {
                // No closing quote found, replace to end and break
                result.replaceSubrange(dataIdx.lowerBound..., with: "[IMG_OMITTED]")
                break
            }
        }

        return result
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

// MARK: - SessionIndexerProtocol Conformance
extension SessionIndexer: SessionIndexerProtocol {
    var requestCopyPlainPublisher: AnyPublisher<Void, Never> {
        $requestCopyPlain.map { _ in () }.eraseToAnyPublisher()
    }

    var requestTranscriptFindFocusPublisher: AnyPublisher<Void, Never> {
        $requestTranscriptFindFocus.map { _ in () }.eraseToAnyPublisher()
    }
}
