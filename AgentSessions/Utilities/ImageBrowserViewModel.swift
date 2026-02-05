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
        let userPromptIndex: Int?
        let payload: SessionImagePayload
        let fileSignature: ImageBrowserFileSignature

        var id: String { "\(sessionID)-\(payload.stableID)" }

        var approxSizeText: String {
            ByteCountFormatter.string(fromByteCount: Int64(payload.approxBytes), countStyle: .file)
        }

        var imageKey: ImageBrowserImageKey {
            let offsets: (UInt64, Int) = {
                switch payload {
                case .base64(_, let span):
                    return (span.base64PayloadOffset, span.base64PayloadLength)
                case .file:
                    return (0, 0)
                }
            }()
            return ImageBrowserImageKey(
                signature: fileSignature,
                base64PayloadOffset: offsets.0,
                base64PayloadLength: offsets.1,
                mediaType: payload.mediaType,
                thumbnailMaxPixelSize: ImageBrowserViewModel.thumbnailMaxPixelSize
            )
        }

        var sortOffset: UInt64 {
            switch payload {
            case .base64(_, let span):
                return span.base64PayloadOffset
            case .file:
                return 0
            }
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

    var allCodingSources: Set<SessionSource> {
        Set(availableSources.filter { $0 != .openclaw })
    }

    var isAllCodingAgentsSelected: Bool {
        let allCoding = allCodingSources
        if allCoding.isEmpty { return selectedSources.isEmpty }
        return selectedSources == allCoding
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

        let thumbnailCache = thumbnailCache
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(
                    payload: item.payload,
                    maxDecodedBytes: 25 * 1024 * 1024,
                    shouldCancel: { Task.isCancelled }
                )
                guard let self else { return }
                let img = try thumbnailCache.loadOrCreateThumbnail(for: key) { decoded }
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
            if itemsBySessionID[seedSession.id] != nil,
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
        if sources.isEmpty { return [] }
        return allSessions.filter { s in
            if let project {
                if s.repoName != project { return false }
            }
            if !sources.contains(s.source) { return false }
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
            return a.sortOffset > b.sortOffset
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
                        userPromptIndex: userPromptIndex(for: session, eventIndex: eventIndex),
                        payload: .base64(sourceURL: fileURL, span: span),
                        fileSignature: fileSignature
                    )
                )
            }

            return out

        case .copilot:
            let attachments = index.copilotAttachments ?? []

            var eventIndexByEventID: [String: Int] = [:]
            eventIndexByEventID.reserveCapacity(min(attachments.count, 64))
            for (idx, ev) in session.events.enumerated() {
                eventIndexByEventID[ev.id] = idx
            }

            var out: [Item] = []
            out.reserveCapacity(min(attachments.count, 64))
            for (i, att) in attachments.enumerated() {
                let eventID = session.id + String(format: "-%04d", att.eventSequenceIndex)
                let eventIndex = eventIndexByEventID[eventID] ?? 0

                let sig = fileSignature(forPath: att.filePath)
                    ?? ImageBrowserFileSignature(filePath: att.filePath, fileSizeBytes: att.fileSizeBytes, modifiedAtUnixSeconds: 0)
                let url = URL(fileURLWithPath: att.filePath)

                out.append(
                    Item(
                        sessionID: session.id,
                        sessionTitle: session.title,
                        sessionModifiedAt: session.modifiedAt,
                        sessionFileURL: url,
                        sessionSource: session.source,
                        sessionProject: session.repoName,
                        sessionImageIndex: i + 1,
                        lineIndex: eventIndex,
                        eventID: eventID,
                        userPromptIndex: userPromptIndex(for: session, eventIndex: eventIndex),
                        payload: .file(fileURL: url, mediaType: att.mediaType, fileSizeBytes: att.fileSizeBytes),
                        fileSignature: sig
                    )
                )
            }
            return out

        case .gemini:
            // For Gemini, we store the message/item index in `lineIndex` and map it back to event IDs.
            let url = URL(fileURLWithPath: session.filePath)
            let signature = index.signature

            var userEventIndices: [Int] = []
            userEventIndices.reserveCapacity(64)
            var eventIndexByBaseID: [String: Int] = [:]
            eventIndexByBaseID.reserveCapacity(min(session.events.count, 512))

            for (idx, ev) in session.events.enumerated() {
                eventIndexByBaseID[ev.id] = idx
                if ev.kind == .user { userEventIndices.append(idx) }
            }

            func nearestUserEventIndex(for eventIndex: Int) -> Int? {
                guard eventIndex >= 0 else { return userEventIndices.first }
                guard !userEventIndices.isEmpty else { return nil }
                let prior = userEventIndices.filter { $0 <= eventIndex }
                if let preferred = prior.last { return preferred }
                let after = userEventIndices.filter { $0 > eventIndex }
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

                let itemIndex = stored.lineIndex
                let baseID = session.id + String(format: "-%04d", itemIndex)
                let baseEventIndex = eventIndexByBaseID[baseID] ?? 0
                let userEventIndex = nearestUserEventIndex(for: baseEventIndex) ?? baseEventIndex
                let eventID = session.events.indices.contains(userEventIndex) ? session.events[userEventIndex].id : baseID

                out.append(
                    Item(
                        sessionID: session.id,
                        sessionTitle: session.title,
                        sessionModifiedAt: session.modifiedAt,
                        sessionFileURL: url,
                        sessionSource: session.source,
                        sessionProject: session.repoName,
                        sessionImageIndex: i + 1,
                        lineIndex: userEventIndex,
                        eventID: eventID,
                        userPromptIndex: userPromptIndex(for: session, eventIndex: userEventIndex),
                        payload: .base64(sourceURL: url, span: span),
                        fileSignature: signature
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

            func fallbackEventID(forStoredLineIndex storedLineIndex: Int) -> String {
                switch session.source {
                case .openclaw:
                    let base = sha256Hex(url.path)
                    return base + String(format: "-%06d", storedLineIndex + 1)
                default:
                    return SessionIndexer.eventID(forPath: url.path, index: storedLineIndex)
                }
            }

            for (i, stored) in index.spans.enumerated() {
                let span = Base64ImageDataURLScanner.Span(
                    startOffset: stored.startOffset,
                    endOffset: stored.endOffset,
                    mediaType: stored.mediaType,
                    base64PayloadOffset: stored.base64PayloadOffset,
                    base64PayloadLength: stored.base64PayloadLength,
                    approxBytes: stored.approxBytes
                )

                let openClawEventID: String? = {
                    guard session.source == .openclaw else { return nil }
                    return fallbackEventID(forStoredLineIndex: stored.lineIndex)
                }()

                let openClawEventIndex: Int? = {
                    guard let openClawEventID else { return nil }
                    if let exactUser = session.events.firstIndex(where: { $0.kind == .user && $0.id == openClawEventID }) { return exactUser }
                    if let exact = session.events.firstIndex(where: { $0.id == openClawEventID }) { return exact }
                    return session.events.firstIndex(where: { $0.id.hasPrefix(openClawEventID) })
                }()

                let resolvedEventIndex = openClawEventIndex ?? stored.lineIndex
                let resolvedUserEventIndex = nearestUserEventIndex(for: resolvedEventIndex) ?? resolvedEventIndex

                out.append(
                    Item(
                        sessionID: session.id,
                        sessionTitle: session.title,
                        sessionModifiedAt: session.modifiedAt,
                        sessionFileURL: url,
                        sessionSource: session.source,
                        sessionProject: session.repoName,
                        sessionImageIndex: i + 1,
                        lineIndex: resolvedUserEventIndex,
                        eventID: openClawEventID
                            ?? (session.events.indices.contains(resolvedUserEventIndex) ? session.events[resolvedUserEventIndex].id : fallbackEventID(forStoredLineIndex: stored.lineIndex)),
                        userPromptIndex: userPromptIndex(for: session, eventIndex: resolvedUserEventIndex),
                        payload: .base64(sourceURL: url, span: span),
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

    func userPromptIndex(for session: Session, eventIndex: Int) -> Int? {
        guard eventIndex >= 0 else { return nil }
        guard !session.events.isEmpty else { return nil }

        var userIndex: Int? = nil
        var seenUsers = 0
        for (idx, event) in session.events.enumerated() {
            if event.kind == .user {
                if idx <= eventIndex {
                    userIndex = seenUsers
                } else if userIndex == nil {
                    userIndex = seenUsers
                }
                seenUsers += 1
            }
            if idx > eventIndex, userIndex != nil { break }
        }
        return userIndex
    }
}
