import Foundation
import Combine
import SwiftUI

/// Session indexer for Droid sessions (read-only, local storage).
final class DroidSessionIndexer: ObservableObject, SessionIndexerProtocol, @unchecked Sendable {
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

    // UI focus coordination
    @Published var activeSearchUI: SessionIndexer.ActiveSearchUI = .none

    // Transcript cache for accurate search
    private let transcriptCache = TranscriptCache()
    internal var searchTranscriptCache: TranscriptCache { transcriptCache }

    @AppStorage(PreferencesKey.Paths.droidSessionsRootOverride) private var sessionsRootOverride: String = ""
    @AppStorage(PreferencesKey.Paths.droidProjectsRootOverride) private var projectsRootOverride: String = ""
    @AppStorage("HideZeroMessageSessions") private var hideZeroMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }
    @AppStorage("HideLowMessageSessions") private var hideLowMessageSessionsPref: Bool = true {
        didSet { recomputeNow() }
    }

    private var discovery: DroidSessionDiscovery
    private var lastOverrides: (sessions: String, projects: String) = ("", "")
    private let progressThrottler = ProgressThrottler()
    private var cancellables = Set<AnyCancellable>()
    private var refreshToken = UUID()

    init() {
        let sessions = UserDefaults.standard.string(forKey: PreferencesKey.Paths.droidSessionsRootOverride) ?? ""
        let projects = UserDefaults.standard.string(forKey: PreferencesKey.Paths.droidProjectsRootOverride) ?? ""
        self.discovery = DroidSessionDiscovery(customSessionsRoot: sessions.isEmpty ? nil : sessions,
                                               customProjectsRoot: projects.isEmpty ? nil : projects)
        self.lastOverrides = (sessions, projects)

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
            .sink { [weak self] results in
                self?.sessions = results
            }
            .store(in: &cancellables)
    }

    var canAccessRootDirectory: Bool {
        let fm = FileManager.default
        let a = discovery.sessionsRoot()
        let b = discovery.projectsRoot()
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: a.path, isDirectory: &isDir), isDir.boolValue { return true }
        var isDir2: ObjCBool = false
        return fm.fileExists(atPath: b.path, isDirectory: &isDir2) && isDir2.boolValue
    }

    func refresh() {
        if !AgentEnablement.isEnabled(.droid) { return }

        // Update discovery if overrides changed
        let sessions = UserDefaults.standard.string(forKey: PreferencesKey.Paths.droidSessionsRootOverride) ?? ""
        let projects = UserDefaults.standard.string(forKey: PreferencesKey.Paths.droidProjectsRootOverride) ?? ""
        if sessions != lastOverrides.sessions || projects != lastOverrides.projects {
            discovery = DroidSessionDiscovery(customSessionsRoot: sessions.isEmpty ? nil : sessions,
                                              customProjectsRoot: projects.isEmpty ? nil : projects)
            lastOverrides = (sessions, projects)
        }

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
		                source: .droid,
		                discoverFiles: { self.discovery.discoverSessionFiles() },
		                parseLightweight: { DroidSessionParser.parseFile(at: $0) },
		                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
		                throttler: self.progressThrottler,
		                shouldContinue: { self.refreshToken == token },
		                onProgress: { processed, total in
		                    guard self.refreshToken == token else { return }
		                    self.totalFiles = total
		                    self.filesProcessed = processed
		                    self.hasEmptyDirectory = (total == 0)
		                    if processed > 0 {
		                        self.progressText = "Indexed \(processed)/\(total)"
		                    }
		                    if self.launchPhase == .hydrating { self.launchPhase = .scanning }
		                }
		            )

            let result = await SessionIndexingEngine.hydrateOrScan(config: config)
            await MainActor.run {
                guard self.refreshToken == token else { return }
                self.allSessions = result.sessions
                self.isIndexing = false
                self.filesProcessed = self.totalFiles
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
	        var results = FilterEngine.filterSessions(allSessions,
	                                                  filters: filters,
	                                                  transcriptCache: transcriptCache,
	                                                  allowTranscriptGeneration: !FeatureFlags.filterUsesCachedTranscriptOnly)
	        if hideZeroMessageSessionsPref { results = results.filter { $0.messageCount > 0 } }
	        if hideLowMessageSessionsPref { results = results.filter { $0.messageCount > 2 } }
	        Task { @MainActor [weak self] in
	            self?.sessions = results
	        }
	    }

    func updateSession(_ updated: Session) {
        if let idx = allSessions.firstIndex(where: { $0.id == updated.id }) {
            allSessions[idx] = updated
        }
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: updated, filters: filters, mode: .normal)
        transcriptCache.set(updated.id, transcript: transcript)
    }

    func reloadSession(id: String) {
        guard let existing = allSessions.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: existing.filePath)
        isLoadingSession = true
	        loadingSessionID = id
	        let ioQueue = FeatureFlags.lowerQoSForHeavyWork ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
	        ioQueue.async {
	            let parsed = DroidSessionParser.parseFileFull(at: url, forcedID: id) ?? existing
	            Task { @MainActor [weak self] in
	                guard let self else { return }
	                if let idx = self.allSessions.firstIndex(where: { $0.id == id }) {
	                    let current = self.allSessions[idx]
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
	                        lightweightCommands: current.lightweightCommands ?? parsed.lightweightCommands
	                    )
	                    self.allSessions[idx] = merged

	                    let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
	                    let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: merged, filters: filters, mode: .normal)
	                    self.transcriptCache.set(merged.id, transcript: transcript)
	                }
	                self.recomputeNow()
	                self.isLoadingSession = false
	                self.loadingSessionID = nil
	            }
	        }
	    }
}
