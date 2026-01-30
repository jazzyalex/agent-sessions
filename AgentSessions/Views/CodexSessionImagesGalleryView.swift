import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum CodexImagesScope: String, CaseIterable, Identifiable {
    case singleSession
    case project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleSession:
            return "Single Session"
        case .project:
            return "All Sessions in Project"
        }
    }
}

struct CodexSessionImageItem: Identifiable, Hashable {
    let sessionID: String
    let sessionTitle: String
    let sessionModifiedAt: Date
    let sessionFileURL: URL
    let sessionImageIndex: Int
    let span: Base64ImageDataURLScanner.Span

    var id: String { "\(sessionID)-\(span.id)" }
}

@MainActor
final class CodexSessionImagesGalleryModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    private let perSessionMatchLimit: Int
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var items: [CodexSessionImageItem] = []
    @Published private(set) var totalDataURLsFound: Int = 0
    @Published private(set) var scannedSessions: Int = 0
    @Published private(set) var totalSessionsToScan: Int = 0
    @Published private(set) var didReachItemLimit: Bool = false
    @Published private(set) var itemLimit: Int = 0

    @Published private(set) var thumbnails: [String: NSImage] = [:]

    let maxDecodedBytes: Int
    private let thumbnailMaxPixelSize: Int
    private let minimumBase64PayloadLength: Int = 64
    private let minimumApproxBytes: Int = 32

    private var scanTask: Task<Void, Never>?
    private var inFlightThumbnails: Set<String> = []
    private let thumbnailQueue = DispatchQueue(label: "AgentSessions.CodexImages.thumb", qos: .userInitiated)

    init(perSessionMatchLimit: Int = 200,
         maxDecodedBytes: Int = 25 * 1024 * 1024,
         thumbnailMaxPixelSize: Int = 480) {
        self.perSessionMatchLimit = perSessionMatchLimit
        self.maxDecodedBytes = maxDecodedBytes
        self.thumbnailMaxPixelSize = thumbnailMaxPixelSize
    }

    func load(sessions: [Session], itemLimit: Int) {
        scanTask?.cancel()
        scanTask = nil

        state = .loading
        items = []
        thumbnails = [:]
        inFlightThumbnails = []

        totalDataURLsFound = 0
        scannedSessions = 0
        totalSessionsToScan = sessions.count
        didReachItemLimit = false
        self.itemLimit = itemLimit

        guard !sessions.isEmpty else {
            state = .loaded
            return
        }

        let sessionsSnapshot = sessions.sorted(by: { $0.modifiedAt > $1.modifiedAt })
        let maxTotal = max(1, itemLimit)
        let maxPerSession = perSessionMatchLimit
        let maxDecodedBytes = maxDecodedBytes
        let minPayloadLen = minimumBase64PayloadLength
        let minBytes = minimumApproxBytes

        scanTask = Task { [sessionsSnapshot] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask(priority: .utility) { [sessionsSnapshot] in
                    var collected: [CodexSessionImageItem] = []
                    collected.reserveCapacity(min(maxTotal, 256))

                    var totalFound = 0
                    var scanned = 0
                    var hitLimit = false

                    for session in sessionsSnapshot {
                        if Task.isCancelled { break }

                        let url = URL(fileURLWithPath: session.filePath)
                        if !FileManager.default.fileExists(atPath: url.path) {
                            scanned += 1
                            let scannedSnapshot = scanned
                            await MainActor.run {
                                if Task.isCancelled { return }
                                self.scannedSessions = scannedSnapshot
                            }
                            continue
                        }

                        let spans: [Base64ImageDataURLScanner.Span]
                        do {
                            spans = try Base64ImageDataURLScanner.scanFile(at: url,
                                                                           maxMatches: maxPerSession,
                                                                           shouldCancel: { Task.isCancelled })
                        } catch {
                            scanned += 1
                            let scannedSnapshot = scanned
                            await MainActor.run {
                                if Task.isCancelled { return }
                                self.scannedSessions = scannedSnapshot
                            }
                            continue
                        }

                        let filtered = spans.filter { span in
                            span.base64PayloadLength >= minPayloadLen &&
                                span.approxBytes >= minBytes &&
                                span.approxBytes <= maxDecodedBytes &&
                                Base64ImageDataURLScanner.isLikelyImageURLContext(at: url, startOffset: span.startOffset)
                        }

                        totalFound += filtered.count

                        if !filtered.isEmpty {
                            let title = session.codexDisplayTitle
                            let modifiedAt = session.modifiedAt
                            let sessionID = session.id

                            var newItems: [CodexSessionImageItem] = []
                            newItems.reserveCapacity(filtered.count)
                            for (idx, span) in filtered.enumerated() {
                                newItems.append(
                                    CodexSessionImageItem(
                                        sessionID: sessionID,
                                        sessionTitle: title,
                                        sessionModifiedAt: modifiedAt,
                                        sessionFileURL: url,
                                        sessionImageIndex: idx + 1,
                                        span: span
                                    )
                                )
                            }

                            if collected.count < maxTotal {
                                let remaining = maxTotal - collected.count
                                if newItems.count > remaining {
                                    hitLimit = true
                                    newItems = Array(newItems.prefix(remaining))
                                }
                                collected.append(contentsOf: newItems)
                            } else {
                                hitLimit = true
                            }

                            let collectedSnapshot = collected
                            await MainActor.run {
                                if Task.isCancelled { return }
                                self.items = collectedSnapshot
                            }

                            if hitLimit { break }
                        }

                        scanned += 1
                        let totalFoundSnapshot = totalFound
                        let scannedSnapshot = scanned
                        let hitLimitSnapshot = hitLimit
                        await MainActor.run {
                            if Task.isCancelled { return }
                            self.totalDataURLsFound = totalFoundSnapshot
                            self.scannedSessions = scannedSnapshot
                            self.didReachItemLimit = hitLimitSnapshot
                        }
                    }

                    let totalFoundSnapshot = totalFound
                    let scannedSnapshot = scanned
                    let hitLimitSnapshot = hitLimit
                    await MainActor.run {
                        if Task.isCancelled { return }
                        self.totalDataURLsFound = totalFoundSnapshot
                        self.scannedSessions = scannedSnapshot
                        self.didReachItemLimit = hitLimitSnapshot
                        self.state = .loaded
                    }
                }
                await group.waitForAll()
            }
        }
    }

    func cancelLoad() {
        scanTask?.cancel()
        scanTask = nil
    }

    func requestThumbnail(for item: CodexSessionImageItem) {
        let key = item.id
        if thumbnails[key] != nil { return }
        if inFlightThumbnails.contains(key) { return }

        inFlightThumbnails.insert(key)
        let url = item.sessionFileURL
        let span = item.span
        let maxDecodedBytes = maxDecodedBytes
        let maxPixels = thumbnailMaxPixelSize

        thumbnailQueue.async {
            defer {
                DispatchQueue.main.async {
                    self.inFlightThumbnails.remove(key)
                }
            }

            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(url: url,
                                                                          span: span,
                                                                          maxDecodedBytes: maxDecodedBytes)
                guard let image = CodexSessionImagePayload.makeThumbnail(from: decoded, maxPixelSize: maxPixels) else {
                    DispatchQueue.main.async {
                        self.items.removeAll(where: { $0.id == key })
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.thumbnails[key] = image
                }
            } catch {
                DispatchQueue.main.async {
                    self.items.removeAll(where: { $0.id == key })
                }
            }
        }
    }
}

struct CodexSessionImagesGalleryView: View {
    let seedSession: Session

    @EnvironmentObject private var indexer: SessionIndexer
    @StateObject private var model = CodexSessionImagesGalleryModel()

    @State private var scope: CodexImagesScope = .singleSession
    @State private var selectedItemID: String? = nil
    @State private var pendingSelectedItemID: String? = nil

    @State private var isPreviewLoading: Bool = false
    @State private var previewImage: NSImage? = nil
    @State private var previewError: String? = nil

    @State private var isSaving: Bool = false
    @State private var saveStatus: String? = nil
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var activeSaveToken: UUID? = nil

    init(seedSession: Session) {
        self.seedSession = seedSession
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if shouldShowFooter {
                Divider()
                footer
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        // Finder-like: Space opens Quick Look for the selected image.
        .overlay {
            Button("") { quickLookSelected() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear { reload() }
        .onChange(of: scope) { _, _ in reload() }
        .onChange(of: model.items) { _, newValue in
            if let pendingSelectedItemID, newValue.contains(where: { $0.id == pendingSelectedItemID }) {
                selectedItemID = pendingSelectedItemID
                self.pendingSelectedItemID = nil
            }

            guard let selectedItemID else { return }
            if !newValue.contains(where: { $0.id == selectedItemID }) {
                self.selectedItemID = nil
            }
        }
        .task(id: selectedItemID) { await loadPreview() }
        .onReceive(NotificationCenter.default.publisher(for: .selectImagesBrowserItem)) { n in
            guard let sid = n.object as? String, sid == seedSession.id else { return }
            guard let requested = n.userInfo?["selectedItemID"] as? String else { return }
            let forceScope = n.userInfo?["forceScope"] as? String

            pendingSelectedItemID = requested
            if forceScope == CodexImagesScope.singleSession.rawValue, scope != .singleSession {
                scope = .singleSession
                return
            }
            if model.items.contains(where: { $0.id == requested }) {
                selectedItemID = requested
                pendingSelectedItemID = nil
            }
        }
        .onDisappear {
            model.cancelLoad()
            saveTask?.cancel()
            saveTask = nil
            activeSaveToken = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Images")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))

            HStack(spacing: 8) {
                Text("Show Images:")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Picker("Show Images", selection: $scope) {
                    Text(CodexImagesScope.singleSession.title).tag(CodexImagesScope.singleSession)
                    Text(CodexImagesScope.project.title).tag(CodexImagesScope.project)
                        .disabled(projectSessions.isEmpty)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .help(projectSessions.isEmpty ? "Project sessions are unavailable for this session." : "Choose whether to show images for this session or all sessions in the same project.")
            }

            Spacer()

            Button("Done") { closeWindow() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            if model.items.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(loadingStatusText)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
            } else {
                HSplitView {
                    thumbnailsPane
                    detailPane
                }
            }

        case .failed(let message):
            ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))

        case .loaded:
            if model.items.isEmpty {
                if model.totalDataURLsFound == 0 {
                    ContentUnavailableView("No images found", systemImage: "photo")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.textBackgroundColor))
                } else {
                    VStack(spacing: 12) {
                        ContentUnavailableView("No previewable images", systemImage: "photo")
                        Text("This scope contains images, but none could be previewed here.")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                }
            } else {
                HSplitView {
                    thumbnailsPane
                    detailPane
                }
            }
        }
    }

    private var shouldShowFooter: Bool {
        if model.state == .loading { return true }
        return model.state == .loaded && model.totalSessionsToScan > 1
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.state == .loading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(footerStatusText)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var footerStatusText: String {
        if scope == .project {
            if model.state == .loading {
                if model.totalSessionsToScan > 0 {
                    let total = model.totalSessionsToScan
                    let completed = min(model.scannedSessions, total)
                    if completed >= total { return "Finalizing scan…" }
                    return "Scanning \(completed)/\(total) sessions for images…"
                }
                return "Scanning project sessions for images…"
            }

            if model.totalSessionsToScan > 0 {
                let scanned = min(model.scannedSessions, model.totalSessionsToScan)
                if model.didReachItemLimit {
                    return "Scan stopped at limit (\(scanned)/\(model.totalSessionsToScan) sessions)"
                }
                return "Scan complete (\(scanned)/\(model.totalSessionsToScan) sessions)"
            }
            return model.didReachItemLimit ? "Scan stopped at limit" : "Scan complete"
        }

        if model.state == .loading {
            return "Scanning session for images…"
        }
        return model.didReachItemLimit ? "Scan stopped at limit" : "Scan complete"
    }

    private var loadingStatusText: String {
        if scope == .project {
            if model.totalSessionsToScan > 0 {
                let total = model.totalSessionsToScan
                let completed = min(model.scannedSessions, total)
                if completed >= total { return "Finalizing scan…" }
                return "Scanning \(completed)/\(total) sessions for images…"
            }
            return "Scanning project sessions for images…"
        }
        return "Scanning session for images…"
    }

    private var thumbnailsPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    summaryRow

                    ForEach(timeGroups, id: \.id) { group in
                        TimeframeDivider(title: group.title)

                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(group.items, id: \.id) { item in
                                CodexImageThumbnailCell(
                                    model: model,
                                    item: item,
                                    isSelected: item.id == selectedItemID,
                                    helpText: itemTooltip(item),
                                    onSelect: { selectedItemID = item.id },
                                    onOpenInPreview: { openInPreview(item: item) },
                                    onSaveToDownloads: { saveToDownloads(item: item) },
                                    onSave: { saveWithPanel(item: item) },
                                    onCopy: { copyImage(item: item) },
                                    onCopyPath: { copyImagePath(item: item) },
                                    onNavigate: { navigateToSession(item: item) }
                                )
                            }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: selectedItemID) { _, newValue in
                guard let newValue else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(minWidth: 340, idealWidth: 460, maxWidth: 560)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            Text("\(model.items.count) image\(model.items.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            if model.didReachItemLimit, model.itemLimit > 0 {
                Text("(showing first \(model.itemLimit))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let item = selectedItem {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.span.mediaType)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.span.approxBytes), countStyle: .file))
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if scope == .project {
                            Text(item.sessionTitle)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer()

                    Button(isSaving ? "Saving…" : "Save…") { saveWithPanel(item: item) }
                        .disabled(isSaving)
                }

                if let saveStatus {
                    Text(saveStatus)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.gray.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
                        )

                    if isPreviewLoading {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Loading preview…")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else if let img = previewImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(14)
                    } else if let err = previewError {
                        ContentUnavailableView(err, systemImage: "photo")
                            .padding(12)
                    } else {
                        ContentUnavailableView("Select an image", systemImage: "photo")
                            .padding(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select an image", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(minWidth: 380)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var selectedItem: CodexSessionImageItem? {
        guard let selectedItemID else { return nil }
        return model.items.first(where: { $0.id == selectedItemID })
    }

    private var projectSessions: [Session] {
        guard let project = seedSession.repoName, !project.isEmpty else { return [] }
        let all = indexer.allSessions
        let filtered = all.filter { $0.repoName == project }
        return filtered.sorted(by: { $0.modifiedAt > $1.modifiedAt })
    }

    private var sessionsToScan: [Session] {
        switch scope {
        case .singleSession:
            return [seedSession]
        case .project:
            if projectSessions.isEmpty {
                return [seedSession]
            }

            var combined = projectSessions
            if !combined.contains(where: { $0.id == seedSession.id || $0.filePath == seedSession.filePath }) {
                combined.append(seedSession)
            }
            return combined.sorted(by: { $0.modifiedAt > $1.modifiedAt })
        }
    }

    private var effectiveItemLimit: Int {
        switch scope {
        case .singleSession:
            return 200
        case .project:
            return 800
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]
    }

    private struct TimeGroup: Identifiable, Hashable {
        let id: String
        let title: String
        let items: [CodexSessionImageItem]
    }

    private var timeGroups: [TimeGroup] {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now

        let sorted = model.items.sorted { a, b in
            if a.sessionModifiedAt != b.sessionModifiedAt { return a.sessionModifiedAt > b.sessionModifiedAt }
            if a.sessionID != b.sessionID { return a.sessionID > b.sessionID }
            return a.span.startOffset > b.span.startOffset
        }

        var groups: [TimeGroup] = []
        groups.reserveCapacity(12)

        var currentKey: String? = nil
        var currentTitle: String = ""
        var currentItems: [CodexSessionImageItem] = []

        func flush() {
            guard let key = currentKey, !currentItems.isEmpty else { return }
            groups.append(TimeGroup(id: key, title: currentTitle, items: currentItems))
            currentItems = []
        }

        for item in sorted {
            let date = item.sessionModifiedAt
            let isRecent = date >= cutoff

            let key: String
            let title: String
            if isRecent {
                let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
                let y = comps.year ?? 0
                let m = comps.month ?? 0
                let d = comps.day ?? 0
                key = "day-\(y)-\(m)-\(d)"
                title = AppDateFormatting.monthDayAbbrev(date)
            } else {
                let comps = Calendar.current.dateComponents([.year, .month], from: date)
                let y = comps.year ?? 0
                let m = comps.month ?? 0
                key = "month-\(y)-\(m)"
                title = date.formatted(.dateTime.month(.wide).year())
            }

            if key != currentKey {
                flush()
                currentKey = key
                currentTitle = title
            }
            currentItems.append(item)
        }

        flush()
        return groups
    }

    private func reload() {
        if scope == .project, projectSessions.isEmpty {
            scope = .singleSession
        }
        model.load(sessions: sessionsToScan, itemLimit: effectiveItemLimit)
    }

    private func closeWindow() {
        model.cancelLoad()
        saveTask?.cancel()
        saveTask = nil
        activeSaveToken = nil
        NSApp.keyWindow?.performClose(nil)
    }

    private func loadPreview() async {
        previewImage = nil
        previewError = nil
        isPreviewLoading = false

        guard let item = selectedItem else { return }

        let url = item.sessionFileURL
        let span = item.span
        let maxDecodedBytes = model.maxDecodedBytes
        let previewMaxPixelSize = 3600
        let itemID = item.id

        isPreviewLoading = true
        let outcome: (NSImage?, String?) = await withTaskGroup(of: (NSImage?, String?).self) { group in
            group.addTask(priority: .userInitiated) {
                do {
                    let decoded = try CodexSessionImagePayload.decodeImageData(url: url,
                                                                              span: span,
                                                                              maxDecodedBytes: maxDecodedBytes,
                                                                              shouldCancel: { Task.isCancelled })
                    guard let img = CodexSessionImagePayload.makeThumbnail(from: decoded, maxPixelSize: previewMaxPixelSize) else {
                        return (nil, "Unsupported image format.")
                    }
                    return (img, nil)
                } catch is CancellationError {
                    return (nil, nil)
                } catch CodexSessionImagePayload.DecodeError.tooLarge {
                    return (nil, "Image too large to preview.")
                } catch CodexSessionImagePayload.DecodeError.invalidBase64 {
                    return (nil, "Invalid image data.")
                } catch {
                    return (nil, "Failed to load image preview.")
                }
            }

            let value = await group.next() ?? (nil, "Failed to load image preview.")
            group.cancelAll()
            return value
        }

        guard !Task.isCancelled else { return }
        guard selectedItemID == itemID else { return }

        isPreviewLoading = false
        previewImage = outcome.0
        previewError = outcome.1
    }

    private func itemTooltip(_ item: CodexSessionImageItem) -> String {
        "\(item.sessionTitle)\n\(AppDateFormatting.dateTimeMedium(item.sessionModifiedAt))"
    }

    private func navigateToSession(item: CodexSessionImageItem) {
        let sessionID = item.sessionID
        let url = item.sessionFileURL
        let offset = item.span.startOffset
        Task(priority: .userInitiated) {
            let eventID: String?
            let userPromptIndex: Int?
            if let lineIndex = lineIndexForOffset(url: url, offset: offset) {
                eventID = SessionIndexer.eventID(forPath: url.path, index: lineIndex)
                userPromptIndex = userPromptIndexForLineIndex(sessionID: sessionID, lineIndex: lineIndex)
            } else {
                eventID = nil
                userPromptIndex = nil
            }
            await MainActor.run {
                var userInfo: [AnyHashable: Any]? = nil
                var payload: [AnyHashable: Any] = [:]
                if let eventID { payload["eventID"] = eventID }
                if let userPromptIndex { payload["userPromptIndex"] = userPromptIndex }
                if !payload.isEmpty {
                    userInfo = payload
                }
                NotificationCenter.default.post(name: .navigateToSessionFromImages, object: sessionID, userInfo: userInfo)
            }
        }
    }

    private func userPromptIndexForLineIndex(sessionID: String, lineIndex: Int) -> Int? {
        guard lineIndex >= 0 else { return nil }
        guard let session = indexer.allSessions.first(where: { $0.id == sessionID }) else { return nil }
        var userIndex: Int? = nil
        var seenUsers = 0
        for (idx, event) in session.events.enumerated() {
            if event.kind == .user {
                if idx <= lineIndex {
                    userIndex = seenUsers
                } else if userIndex == nil {
                    userIndex = seenUsers
                }
                seenUsers += 1
            }
            if idx > lineIndex, userIndex != nil { break }
        }
        return userIndex
    }

    private func copyImage(item: CodexSessionImageItem) {
        let url = item.sessionFileURL
        let span = item.span
        let maxDecodedBytes = model.maxDecodedBytes
        Task(priority: .userInitiated) {
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(url: url,
                                                                          span: span,
                                                                          maxDecodedBytes: maxDecodedBytes)
                guard let image = NSImage(data: decoded) else { return }
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                    if let tiff = image.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        pasteboard.setData(png, forType: .png)
                    }
                }
            } catch {
                // Best-effort copy; no UI error.
            }
        }
    }

    private func copyImagePath(item: CodexSessionImageItem) {
        let url = item.sessionFileURL
        let span = item.span
        let maxDecodedBytes = model.maxDecodedBytes
        Task(priority: .userInitiated) {
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(url: url,
                                                                          span: span,
                                                                          maxDecodedBytes: maxDecodedBytes)
                let fileURL = try writeClipboardImageFile(item: item, data: decoded)
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([fileURL as NSURL])
                    pasteboard.setString(fileURL.path, forType: .string)
                }
            } catch {
                // Best-effort copy; no UI error.
            }
        }
    }

    private func openInPreview(item: CodexSessionImageItem) {
        let url = item.sessionFileURL
        let span = item.span
        let maxDecodedBytes = model.maxDecodedBytes
        Task(priority: .userInitiated) {
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(url: url,
                                                                          span: span,
                                                                          maxDecodedBytes: maxDecodedBytes)
                let fileURL = try writePreviewImageFile(item: item, data: decoded)
                await MainActor.run {
                    openInPreviewApp(fileURL)
                }
            } catch {
                // Best-effort open; no UI error.
            }
        }
    }

    private func quickLookSelected() {
        guard let item = selectedItem else { return }
        quickLook(item: item)
    }

    private func quickLook(item: CodexSessionImageItem) {
        let url = item.sessionFileURL
        let span = item.span
        let maxDecodedBytes = model.maxDecodedBytes
        Task(priority: .userInitiated) {
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(url: url,
                                                                          span: span,
                                                                          maxDecodedBytes: maxDecodedBytes)
                let fileURL = try writePreviewImageFile(item: item, data: decoded)
                await MainActor.run {
                    QuickLookPreviewController.shared.preview(urls: [fileURL])
                }
            } catch {
                // Best-effort preview; no UI error.
            }
        }
    }

    private func writeClipboardImageFile(item: CodexSessionImageItem, data: Data) throws -> URL {
        let ext = CodexSessionImagePayload.suggestedFileExtension(for: item.span.mediaType)
        let tempRoot = FileManager.default.temporaryDirectory
        let dir = tempRoot.appendingPathComponent("AgentSessions/ImageClipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = suggestedFileName(for: item, ext: ext)
        let destination = uniqueDestinationURL(in: dir, filename: filename)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    private func writePreviewImageFile(item: CodexSessionImageItem, data: Data) throws -> URL {
        let ext = CodexSessionImagePayload.suggestedFileExtension(for: item.span.mediaType)
        let tempRoot = FileManager.default.temporaryDirectory
        let dir = tempRoot.appendingPathComponent("AgentSessions/ImagesGalleryPreview", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = suggestedFileName(for: item, ext: ext)
        let destination = uniqueDestinationURL(in: dir, filename: filename)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    @MainActor
    private func openInPreviewApp(_ url: URL) {
        guard let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: config, completionHandler: nil)
    }

    private func saveWithPanel(item: CodexSessionImageItem) {
        let ext = CodexSessionImagePayload.suggestedFileExtension(for: item.span.mediaType)
        let utType = CodexSessionImagePayload.suggestedUTType(for: item.span.mediaType)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFileName(for: item, ext: ext)

        let destinationKeyWindow = NSApp.keyWindow
        let destinationURL = item.sessionFileURL
        let span = item.span
        let maxDecodedBytes = model.maxDecodedBytes
        let token = UUID()

        let onComplete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            beginSave(token: token,
                      destination: destination,
                      sourceURL: destinationURL,
                      span: span,
                      maxDecodedBytes: maxDecodedBytes,
                      successStatus: nil)
        }

        if let win = destinationKeyWindow {
            panel.beginSheetModal(for: win, completionHandler: onComplete)
        } else {
            onComplete(panel.runModal())
        }
    }

    private func saveToDownloads(item: CodexSessionImageItem) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            saveStatus = "Downloads folder not found."
            return
        }

        let ext = CodexSessionImagePayload.suggestedFileExtension(for: item.span.mediaType)
        let filename = suggestedFileName(for: item, ext: ext)
        let destination = uniqueDestinationURL(in: downloads, filename: filename)
        let token = UUID()

        beginSave(token: token,
                  destination: destination,
                  sourceURL: item.sessionFileURL,
                  span: item.span,
                  maxDecodedBytes: model.maxDecodedBytes,
                  successStatus: "Saved to Downloads.")
    }

    private func beginSave(token: UUID,
                           destination: URL,
                           sourceURL: URL,
                           span: Base64ImageDataURLScanner.Span,
                           maxDecodedBytes: Int,
                           successStatus: String?) {
        saveTask?.cancel()
        activeSaveToken = token

        isSaving = true
        saveStatus = nil

        saveTask = Task(priority: .userInitiated) {
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(url: sourceURL,
                                                                          span: span,
                                                                          maxDecodedBytes: maxDecodedBytes,
                                                                          shouldCancel: { Task.isCancelled })
                if Task.isCancelled { throw CancellationError() }
                try decoded.write(to: destination, options: [.atomic])
                if Task.isCancelled { throw CancellationError() }
                await MainActor.run {
                    guard activeSaveToken == token else { return }
                    isSaving = false
                    saveTask = nil
                    activeSaveToken = nil
                    saveStatus = successStatus
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard activeSaveToken == token else { return }
                    isSaving = false
                    saveTask = nil
                    activeSaveToken = nil
                }
            } catch CodexSessionImagePayload.DecodeError.tooLarge {
                await MainActor.run {
                    guard activeSaveToken == token else { return }
                    isSaving = false
                    saveTask = nil
                    activeSaveToken = nil
                    saveStatus = "Image too large to save."
                }
            } catch {
                await MainActor.run {
                    guard activeSaveToken == token else { return }
                    isSaving = false
                    saveTask = nil
                    activeSaveToken = nil
                    saveStatus = "Failed to save image."
                }
            }
        }
    }

    private func suggestedFileName(for item: CodexSessionImageItem, ext: String) -> String {
        let shortID = String(item.sessionID.prefix(6))
        return "image-\(shortID)-\(item.sessionImageIndex).\(ext)"
    }

    private func uniqueDestinationURL(in dir: URL, filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = dir.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = "\(base)-\(counter).\(ext)"
            candidate = dir.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    private func lineIndexForOffset(url: URL, offset: UInt64) -> Int? {
        do {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }

            var remaining = offset
            let chunkSize = 64 * 1024
            var lineCount = 0

            while remaining > 0 {
                let readCount = min(UInt64(chunkSize), remaining)
                let data = try fh.read(upToCount: Int(readCount)) ?? Data()
                if data.isEmpty { break }
                lineCount += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                remaining -= UInt64(data.count)
            }

            return lineCount
        } catch {
            return nil
        }
    }
}

private struct TimeframeDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.gray.opacity(0.18))
                .frame(height: 1)
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.gray.opacity(0.18))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}

private struct CodexImageThumbnailCell: View {
    @ObservedObject var model: CodexSessionImagesGalleryModel
    let item: CodexSessionImageItem
    let isSelected: Bool
    let helpText: String
    let onSelect: () -> Void
    let onOpenInPreview: () -> Void
    let onSaveToDownloads: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onCopyPath: () -> Void
    let onNavigate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.gray.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.70) : Color.gray.opacity(0.18),
                                    lineWidth: isSelected ? 2 : 1)
                    )

                if let img = model.thumbnails[item.id] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(10)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
            .frame(height: 140)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.span.mediaType)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(ByteCountFormatter.string(fromByteCount: Int64(item.span.approxBytes), countStyle: .file))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .help(helpText)
        .onTapGesture(count: 2) {
            onSelect()
            onOpenInPreview()
        }
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Open in Preview") { onSelect(); onOpenInPreview() }
            Divider()
            Button("Copy Image Path (for CLI agent)") { onSelect(); onCopyPath() }
            Button("Copy Image") { onSelect(); onCopy() }
            Divider()
            Button("Save to Downloads") { onSelect(); onSaveToDownloads() }
            Button("Save…") { onSelect(); onSave() }
            Divider()
            Button("Navigate to Session") { onSelect(); onNavigate() }
        }
        .onAppear { model.requestThumbnail(for: item) }
    }
}
