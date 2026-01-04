import Foundation
import Combine
import SwiftUI

/// Session indexer for OpenCode sessions (read-only, local storage)
final class OpenCodeSessionIndexer: ObservableObject, @unchecked Sendable {
    @Published private(set) var allSessions: [Session] = []
    @Published private(set) var sessions: [Session] = []
    @Published var isIndexing: Bool = false
    @Published var isProcessingTranscripts: Bool = false
    @Published var progressText: String = ""
    @Published var filesProcessed: Int = 0
    @Published var totalFiles: Int = 0
    @Published var indexingError: String? = nil
    @Published var hasEmptyDirectory: Bool = false
    @Published var launchPhase: LaunchPhase = .idle

    // Filters
    @Published var query: String = ""
    @Published var queryDraft: String = ""
    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil
    @Published var selectedModel: String? = nil
    @Published var selectedKinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)
    @Published var projectFilter: String? = nil
    @Published var isLoadingSession: Bool = false
    @Published var loadingSessionID: String? = nil

    // UI focus coordination (shared with other indexers via protocol)
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    // Transcript cache for accurate search
    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    @AppStorage("OpenCodeSessionsRootOverride") var sessionsRootOverride: String = ""
    @AppStorage("HideZeroMessageSessions") var hideZeroMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") var hideLowMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }

    private var discovery: OpenCodeSessionDiscovery
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var refreshToken = UUID()

    init() {
        let initialOverride = UserDefaults.standard.string(forKey: "OpenCodeSessionsRootOverride") ?? ""
        self.discovery = OpenCodeSessionDiscovery(customRoot: initialOverride.isEmpty ? nil : initialOverride)

        // Debounced filtering similar to Claude/Gemini indexers
        let inputs = Publishers.CombineLatest4(
            $query.removeDuplicates(),
            $dateFrom.removeDuplicates(by: OptionalDateEquality.eq),
            $dateTo.removeDuplicates(by: OptionalDateEquality.eq),
            $selectedModel.removeDuplicates()
        )
        Publishers.CombineLatest3(inputs, $selectedKinds.removeDuplicates(), $allSessions)
            .receive(on: FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] input, kinds, all -> [Session] in
                let (q, from, to, model) = input
                let filters = Filters(query: q,
                                      dateFrom: from,
                                      dateTo: to,
                                      model: model,
                                      kinds: kinds,
                                      repoName: self?.projectFilter,
                                      pathContains: nil)
                var results = FilterEngine.filterSessions(all,
                                                          filters: filters,
                                                          transcriptCache: self?.transcriptCache,
                                                          allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
                if self?.hideZeroMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 0 } }
                if self?.hideLowMessageSessionsPref ?? true { results = results.filter { $0.messageCount > 2 } }
                return results
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)
    }

    var canAccessRootDirectory: Bool {
        let root = discovery.sessionsRoot()
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    func refresh() {
        if !AgentEnablement.isEnabled(.opencode) { return }
        let root = discovery.sessionsRoot()
        let storageRoot = (root.lastPathComponent == "session") ? root.deletingLastPathComponent() : root
        let migrationURL = storageRoot.appendingPathComponent("migration", isDirectory: false)
        #if DEBUG
        if let data = try? Data(contentsOf: migrationURL),
           let str = String(data: data, encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = trimmed.isEmpty ? "(empty)" : trimmed
            print("OpenCode storage schema: migration=\(version)")
        } else {
            print("OpenCode storage schema: migration=(missing)")
        }

        print("\n🟣 OPENCode INDEXING START: root=\(root.path)")
        #endif
        LaunchProfiler.log("OpenCode.refresh: start")

        let token = UUID()
        refreshToken = token
        launchPhase = .hydrating
        isIndexing = true
        isProcessingTranscripts = false
        progressText = "Scanning…"
        filesProcessed = 0
        totalFiles = 0
        indexingError = nil
        hasEmptyDirectory = false

        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated
	        Task.detached(priority: prio) { [weak self, token] in
	            guard let self else { return }

		            let config = SessionIndexingEngine.ScanConfig(
		                source: .opencode,
		                discoverFiles: { self.discovery.discoverSessionFiles() },
		                parseLightweight: { OpenCodeSessionParser.parseFile(at: $0) },
		                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
		                throttler: self.progressThrottler,
		                onProgress: { processed, total in
		                    guard self.refreshToken == token else { return }
		                    self.totalFiles = total
		                    self.filesProcessed = processed
		                    self.hasEmptyDirectory = (total == 0)
		                    if total > 0 {
		                        self.progressText = "Indexed \(processed)/\(total)"
		                    }
		                    if self.launchPhase == .hydrating {
		                        self.launchPhase = .scanning
		                    }
		                }
		            )

            let result = await SessionIndexingEngine.hydrateOrScan(config: config)
            await MainActor.run {
                guard self.refreshToken == token else { return }
                LaunchProfiler.log("OpenCode.refresh: sessions merged (total=\(result.sessions.count))")
                self.allSessions = result.sessions
                self.isIndexing = false
                if FeatureFlags.throttleIndexingUIUpdates {
                    self.filesProcessed = self.totalFiles
                    if self.totalFiles > 0 {
                        self.progressText = "Indexed \(self.totalFiles)/\(self.totalFiles)"
                    }
                }
                self.progressText = "Ready"
                self.launchPhase = .ready
            }
        }
    }

    func applySearch() {
        query = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        recomputeNow()
    }

    func recomputeNow() {
        let filters = Filters(query: query,
                              dateFrom: dateFrom,
                              dateTo: dateTo,
                              model: selectedModel,
                              kinds: selectedKinds,
                              repoName: projectFilter,
                              pathContains: nil)
	        var results = FilterEngine.filterSessions(allSessions, filters: filters, transcriptCache: transcriptCache, allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
	        if hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 } }
	        if hideLowMessageSessionsPref { results = results.filter { $0.messageCount > 2 } }
	        Task { @MainActor [weak self] in
	            self?.sessions = results
	        }
	    }

    // Update an existing session in allSessions (used by SearchCoordinator to persist parsed sessions)
    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[idx] = updated
        }
    }

    func reloadSession(id: String) {
        guard let existing = allSessions.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: existing.filePath)
        isLoadingSession = true
	        loadingSessionID = id
	        let ioQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
	        ioQueue.async {
	            let parsed = OpenCodeSessionParser.parseFileFull(at: url) ?? existing
	            Task { @MainActor [weak self] in
	                guard let self else { return }
	                if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
	                    let current = self.allSessions[idx]
	                    // Preserve or increase eventCount estimate to keep messageCount stable.
	                    let merged = Session(
	                        id: parsed.id,
	                        source: parsed.source,
	                        startTime: parsed.startTime ?? current.startTime,
	                        endTime: parsed.endTime ?? current.endTime,
	                        model: parsed.model ?? current.model,
	                        filePath: parsed.filePath,
	                        fileSizeBytes: parsed.fileSizeBytes ?? current.fileSizeBytes,
	                        eventCount: max(current.eventCount, parsed.nonMetaCount),
	                        events: parsed.events,
	                        cwd: current.lightweightCwd ?? parsed.cwd,
	                        repoName: current.repoName,
	                        lightweightTitle: current.lightweightTitle ?? parsed.lightweightTitle,
	                        lightweightCommands: current.lightweightCommands
	                    )
	                    self.allSessions[idx] = merged
	                }
	                self.recomputeNow()
	                self.isLoadingSession = false
	                self.loadingSessionID = nil
	            }
	        }
	    }

}

// MARK: - SessionIndexerProtocol Conformance

extension OpenCodeSessionIndexer: SessionIndexerProtocol {}
