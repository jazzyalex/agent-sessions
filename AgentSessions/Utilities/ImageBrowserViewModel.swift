import Foundation
import AppKit

@MainActor
final class ImageBrowserViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loadingSelected
        case indexingBackground
        case loaded
        case failed(String)
    }

    struct Item: Identifiable, Hashable, Sendable {
        let sessionID: String
        let sessionTitle: String
        let sessionModifiedAt: Date
        let sessionFileURL: URL
        let sessionSource: SessionSource
        let sessionProject: String?
        let sessionImageIndex: Int
        let lineIndex: Int
        let eventID: String
        let span: Base64ImageDataURLScanner.Span
        let fileSignature: ImageBrowserFileSignature

        var id: String { "\(sessionID)-\(sha256Hex(sessionFileURL.path))-\(span.id)" }

        var approxSizeText: String {
            ByteCountFormatter.string(fromByteCount: Int64(span.approxBytes), countStyle: .file)
        }

        var imageKey: ImageBrowserImageKey {
            ImageBrowserImageKey(
                signature: fileSignature,
                base64PayloadOffset: span.base64PayloadOffset,
                base64PayloadLength: span.base64PayloadLength,
                mediaType: span.mediaType,
                thumbnailMaxPixelSize: ImageBrowserViewModel.thumbnailMaxPixelSize
            )
        }
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var items: [Item] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published var selectedProject: String? = nil
    @Published var selectedSources: Set<SessionSource> = []
    @Published var selectedItemID: String? = nil
    @Published private(set) var seedSessionID: String? = nil

    private let indexCache: ImageBrowserIndexCache
    private let thumbnailCache: ImageBrowserThumbnailCache

    private var allSessions: [Session] = []
    private var sessionByID: [String: Session] = [:]

    // Indexed items per sessionID (for incremental updates without resetting from zero)
    private var itemsBySessionID: [String: [Item]] = [:]
    private var sessionSignatureBySessionID: [String: ImageBrowserFileSignature] = [:]
    private var backgroundTask: Task<Void, Never>?
    private var selectedTask: Task<Void, Never>?
    private var firstThumbnailLogged = false

    private nonisolated static let thumbnailMaxPixelSize: Int = 480

    init(indexCache: ImageBrowserIndexCache = ImageBrowserIndexCache(),
         thumbnailCache: ImageBrowserThumbnailCache = ImageBrowserThumbnailCache(thumbnailMaxPixelSize: ImageBrowserViewModel.thumbnailMaxPixelSize)) {
        self.indexCache = indexCache
        self.thumbnailCache = thumbnailCache
    }

    func updateSessions(allSessions: [Session], seedSession: Session) {
        ImageBrowserPerfMetrics.markOpenTapped()
        self.allSessions = allSessions
        self.sessionByID = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
        self.seedSessionID = seedSession.id
        firstThumbnailLogged = false

        // Selected session first: filter to its project (if any) and its agent.
        if let project = seedSession.repoName, !project.isEmpty {
            selectedProject = project
        } else {
            selectedProject = nil
        }
        selectedSources = [seedSession.source]

        // Keep previously indexed items; rebuild visible list immediately from what we already have.
        recomputeVisibleItems()

        // Then ensure selected session is indexed first, followed by background indexing for other sessions in scope.
        loadSelectedSessionFirst(seedSession)
    }

    func markWindowShown() {
        ImageBrowserPerfMetrics.markWindowShown()
    }

    func onFiltersChanged() {
        recomputeVisibleItems()
        scheduleBackgroundIndexingIfNeeded()
    }

    var availableProjects: [String] {
        let projects = allSessions
            .compactMap { $0.repoName?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(projects)).sorted()
    }

    var availableSources: [SessionSource] {
        let present = Set(allSessions.map(\.source))
        return SessionSource.allCases.filter { present.contains($0) }
    }

    func loadedUserPromptText(for item: Item) -> String? {
        guard let session = sessionByID[item.sessionID] else { return nil }
        guard !session.events.isEmpty else { return nil }
        guard session.events.indices.contains(item.lineIndex) else { return nil }
        guard session.events[item.lineIndex].kind == .user else { return nil }
        let text = session.events[item.lineIndex].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    func requestThumbnail(for item: Item) {
        if thumbnails[item.id] != nil { return }

        let key = item.imageKey
        if let present = thumbnailCache.thumbnailIfPresent(for: key) {
            thumbnails[item.id] = present
            if !firstThumbnailLogged {
                firstThumbnailLogged = true
                ImageBrowserPerfMetrics.markFirstThumbnailShown()
            }
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(
                    url: item.sessionFileURL,
                    span: item.span,
                    maxDecodedBytes: 25 * 1024 * 1024,
                    shouldCancel: { Task.isCancelled }
                )
                guard let self else { return }
                let img = try self.thumbnailCache.loadOrCreateThumbnail(for: key) { decoded }
                if Task.isCancelled { return }
                await MainActor.run {
                    self.thumbnails[item.id] = img
                    if !self.firstThumbnailLogged {
                        self.firstThumbnailLogged = true
                        ImageBrowserPerfMetrics.markFirstThumbnailShown()
                    }
                }
            } catch {
                // Best-effort thumbnail; ignore failures.
            }
        }
    }

    func cancelBackgroundWork() {
        selectedTask?.cancel()
        selectedTask = nil
        backgroundTask?.cancel()
        backgroundTask = nil
    }
}

private extension ImageBrowserViewModel {
    func loadSelectedSessionFirst(_ seedSession: Session) {
        selectedTask?.cancel()
        selectedTask = Task { [weak self] in
            guard let self else { return }
            if let existing = itemsBySessionID[seedSession.id],
               let currentSig = fileSignature(forPath: seedSession.filePath),
               sessionSignatureBySessionID[seedSession.id] == currentSig {
                recomputeVisibleItems()
                state = .loaded
                if selectedItemID == nil, let first = items.first {
                    selectedItemID = first.id
                }
                scheduleBackgroundIndexingIfNeeded()
                return
            }

            state = .loadingSelected

            let index = await indexCache.getOrBuildIndex(for: seedSession, maxMatches: 400, shouldCancel: { Task.isCancelled })
            if Task.isCancelled { return }

            let newItems = buildItems(for: seedSession, index: index)
            itemsBySessionID[seedSession.id] = newItems
            sessionSignatureBySessionID[seedSession.id] = index.signature
            recomputeVisibleItems()

            ImageBrowserPerfMetrics.markSelectedIndexReady(imageCount: newItems.count)

            // Auto-select first item when opening.
            if selectedItemID == nil, let first = items.first {
                selectedItemID = first.id
            }

            scheduleBackgroundIndexingIfNeeded()
        }
    }

    func scheduleBackgroundIndexingIfNeeded() {
        backgroundTask?.cancel()

        let scopeSessions = sessionsMatchingCurrentFilters()
        let missing = scopeSessions.filter { itemsBySessionID[$0.id] == nil }
        guard !missing.isEmpty else {
            state = .loaded
            return
        }

        state = .indexingBackground
        backgroundTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var scanned = 0
            for session in missing {
                if Task.isCancelled { break }
                let index = await self.indexCache.getOrBuildIndex(for: session, maxMatches: 400, shouldCancel: { Task.isCancelled })
                if Task.isCancelled { break }
                let built = await MainActor.run { self.buildItems(for: session, index: index) }
                await MainActor.run {
                    self.itemsBySessionID[session.id] = built
                    self.sessionSignatureBySessionID[session.id] = index.signature
                    self.recomputeVisibleItems()
                }
                scanned += 1
                ImageBrowserPerfMetrics.logBackgroundProgress(scannedSessions: scanned, totalSessions: missing.count)
            }
            await MainActor.run {
                if !Task.isCancelled {
                    self.state = .loaded
                }
            }
        }
    }

    func sessionsMatchingCurrentFilters() -> [Session] {
        let projectFilter = selectedProject?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = (projectFilter?.isEmpty == false) ? projectFilter : nil

        let sources = selectedSources
        return allSessions.filter { s in
            if let project {
                if s.repoName != project { return false }
            }
            if !sources.isEmpty && !sources.contains(s.source) { return false }
            return true
        }.sorted(by: { $0.modifiedAt > $1.modifiedAt })
    }

    func recomputeVisibleItems() {
        let sessions = sessionsMatchingCurrentFilters()
        let sessionIDs = Set(sessions.map(\.id))

        var merged: [Item] = []
        merged.reserveCapacity(256)
        for sid in sessionIDs {
            if let list = itemsBySessionID[sid] {
                merged.append(contentsOf: list)
            }
        }

        merged.sort { a, b in
            if a.sessionModifiedAt != b.sessionModifiedAt { return a.sessionModifiedAt > b.sessionModifiedAt }
            if a.sessionID != b.sessionID { return a.sessionID > b.sessionID }
            return a.span.base64PayloadOffset > b.span.base64PayloadOffset
        }

        items = merged

        // Prune thumbnail dictionary to visible items only.
        let visibleIDs = Set(merged.map(\.id))
        thumbnails = thumbnails.filter { visibleIDs.contains($0.key) }

        if let selectedItemID, !visibleIDs.contains(selectedItemID) {
            self.selectedItemID = merged.first?.id
        }
    }

    func buildItems(for session: Session, index: ImageBrowserStoredIndex) -> [Item] {
        switch session.source {
        case .opencode:
            let images = index.openCodeImages ?? []

            var messageToUserEventIndex: [String: Int] = [:]
            var messageToFirstEventIndex: [String: Int] = [:]
            messageToUserEventIndex.reserveCapacity(64)
            messageToFirstEventIndex.reserveCapacity(64)

            for (idx, ev) in session.events.enumerated() {
                guard let mid = ev.messageID, mid.hasPrefix("msg_") else { continue }
                if messageToFirstEventIndex[mid] == nil { messageToFirstEventIndex[mid] = idx }
                if ev.kind == .user, messageToUserEventIndex[mid] == nil { messageToUserEventIndex[mid] = idx }
            }

            var out: [Item] = []
            out.reserveCapacity(min(images.count, 64))

            for (i, stored) in images.enumerated() {
                let span = Base64ImageDataURLScanner.Span(
                    startOffset: stored.startOffset,
                    endOffset: stored.endOffset,
                    mediaType: stored.mediaType,
                    base64PayloadOffset: stored.base64PayloadOffset,
                    base64PayloadLength: stored.base64PayloadLength,
                    approxBytes: stored.approxBytes
                )

                let fileURL = URL(fileURLWithPath: stored.partFilePath)
                let fileSignature = fileSignature(forPath: stored.partFilePath)
                    ?? ImageBrowserFileSignature(filePath: stored.partFilePath, fileSizeBytes: 0, modifiedAtUnixSeconds: 0)

                let eventIndex = messageToUserEventIndex[stored.messageID] ?? messageToFirstEventIndex[stored.messageID] ?? 0
                let eventID: String = session.events.indices.contains(eventIndex) ? session.events[eventIndex].id : ""

                out.append(
                    Item(
                        sessionID: session.id,
                        sessionTitle: session.title,
                        sessionModifiedAt: session.modifiedAt,
                        sessionFileURL: fileURL,
                        sessionSource: session.source,
                        sessionProject: session.repoName,
                        sessionImageIndex: i + 1,
                        lineIndex: eventIndex,
                        eventID: eventID,
                        span: span,
                        fileSignature: fileSignature
                    )
                )
            }

            return out

        default:
            let url = URL(fileURLWithPath: session.filePath)
            let signature = index.signature
            let userEventIndices: [Int] = session.events.enumerated().compactMap { (idx, ev) in
                ev.kind == .user ? idx : nil
            }

            func nearestUserEventIndex(for lineIndex: Int) -> Int? {
                guard lineIndex >= 0 else { return userEventIndices.first }
                guard !userEventIndices.isEmpty else { return nil }
                let prior = userEventIndices.filter { $0 <= lineIndex }
                if let preferred = prior.last { return preferred }
                let after = userEventIndices.filter { $0 > lineIndex }
                return after.first
            }

            var out: [Item] = []
            out.reserveCapacity(min(index.spans.count, 64))

            for (i, stored) in index.spans.enumerated() {
                let span = Base64ImageDataURLScanner.Span(
                    startOffset: stored.startOffset,
                    endOffset: stored.endOffset,
                    mediaType: stored.mediaType,
                    base64PayloadOffset: stored.base64PayloadOffset,
                    base64PayloadLength: stored.base64PayloadLength,
                    approxBytes: stored.approxBytes
                )
                out.append(
                    Item(
                        sessionID: session.id,
                        sessionTitle: session.title,
                        sessionModifiedAt: session.modifiedAt,
                        sessionFileURL: url,
                        sessionSource: session.source,
                        sessionProject: session.repoName,
                        sessionImageIndex: i + 1,
                        lineIndex: nearestUserEventIndex(for: stored.lineIndex) ?? stored.lineIndex,
                        eventID: {
                            let idx = nearestUserEventIndex(for: stored.lineIndex) ?? stored.lineIndex
                            if session.events.indices.contains(idx) { return session.events[idx].id }
                            return SessionIndexer.eventID(forPath: url.path, index: stored.lineIndex)
                        }(),
                        span: span,
                        fileSignature: signature
                    )
                )
            }

            return out
        }
    }

    func fileSignature(forPath path: String) -> ImageBrowserFileSignature? {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modDate = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            return ImageBrowserFileSignature(
                filePath: path,
                fileSizeBytes: size,
                modifiedAtUnixSeconds: Int64(modDate.timeIntervalSince1970)
            )
        } catch {
            return nil
        }
    }
}
