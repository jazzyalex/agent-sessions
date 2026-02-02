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
    let sessionSource: SessionSource
    let sessionProject: String?
    let sessionImageIndex: Int
    let lineIndex: Int
    let eventID: String
    let userPromptIndex: Int?
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

    nonisolated private static func userPromptIndex(for session: Session, lineIndex: Int) -> Int? {
        guard lineIndex >= 0 else { return nil }
        guard !session.events.isEmpty else { return nil }

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

                        let hasAny: Bool = {
                            switch session.source {
                            case .codex:
                                return Base64ImageDataURLScanner.fileContainsBase64ImageDataURL(at: url, shouldCancel: { Task.isCancelled })
                            case .claude:
                                return ClaudeBase64ImageScanner.fileContainsUserBase64Image(at: url, shouldCancel: { Task.isCancelled })
                            default:
                                return false
                            }
                        }()

                        guard hasAny, !Task.isCancelled else {
                            scanned += 1
                            let scannedSnapshot = scanned
                            await MainActor.run {
                                if Task.isCancelled { return }
                                self.scannedSessions = scannedSnapshot
                            }
                            continue
                        }

                        let located: [Base64ImageDataURLScanner.LocatedSpan]
                        do {
                            switch session.source {
                            case .codex:
                                located = try Base64ImageDataURLScanner
                                    .scanFileWithLineIndexes(at: url, maxMatches: maxPerSession, shouldCancel: { Task.isCancelled })
                            case .claude:
                                located = try ClaudeBase64ImageScanner
                                    .scanFileWithLineIndexes(at: url, maxMatches: maxPerSession, shouldCancel: { Task.isCancelled })
                            default:
                                located = []
                            }
                        } catch {
                            scanned += 1
                            let scannedSnapshot = scanned
                            await MainActor.run {
                                if Task.isCancelled { return }
                                self.scannedSessions = scannedSnapshot
                            }
                            continue
                        }

                        let filtered: [Base64ImageDataURLScanner.LocatedSpan] = located.filter { item in
                            let span = item.span
                            guard span.base64PayloadLength >= minPayloadLen,
                                  span.approxBytes >= minBytes,
                                  span.approxBytes <= maxDecodedBytes else {
                                return false
                            }

                            switch session.source {
                            case .codex:
                                return Base64ImageDataURLScanner.isLikelyImageURLContext(at: url, startOffset: span.startOffset)
                            case .claude:
                                return true
                            default:
                                return false
                            }
                        }

                        totalFound += filtered.count

                        if !filtered.isEmpty {
                            let title = session.title
                            let modifiedAt = session.modifiedAt
                            let sessionID = session.id

                            var newItems: [CodexSessionImageItem] = []
                            newItems.reserveCapacity(filtered.count)
                            for (idx, item) in filtered.enumerated() {
                                let lineIndex = item.lineIndex
                                newItems.append(
                                    CodexSessionImageItem(
                                        sessionID: sessionID,
                                        sessionTitle: title,
                                        sessionModifiedAt: modifiedAt,
                                        sessionFileURL: url,
                                        sessionSource: session.source,
                                        sessionProject: session.repoName,
                                        sessionImageIndex: idx + 1,
                                        lineIndex: lineIndex,
                                        eventID: SessionIndexer.eventID(forPath: url.path, index: lineIndex),
                                        userPromptIndex: Self.userPromptIndex(for: session, lineIndex: lineIndex),
                                        span: item.span
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
    let allSessions: [Session]

    @StateObject private var model = CodexSessionImagesGalleryModel()

    @State private var selectedItemID: String? = nil
    @State private var pendingSelectedItemID: String? = nil
    @State private var selectedProject: String? = nil // nil means "All Projects"
    @State private var selectedSources: Set<SessionSource> = []

    @State private var isPreviewLoading: Bool = false
    @State private var previewImage: NSImage? = nil
    @State private var previewError: String? = nil
    @State private var promptText: String? = nil
    @State private var dimensionsText: String? = nil

    @State private var isSaving: Bool = false
    @State private var saveStatus: String? = nil
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var activeSaveToken: UUID? = nil

    init(seedSession: Session, allSessions: [Session]) {
        self.seedSession = seedSession
        self.allSessions = allSessions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
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
        .onAppear { ensureFiltersInitialized(); reload() }
        .onChange(of: selectedProject) { _, _ in reload() }
        .onChange(of: selectedSources) { _, _ in reload() }
        .onChange(of: model.items) { _, newValue in
            if let pendingSelectedItemID, newValue.contains(where: { $0.id == pendingSelectedItemID }) {
                selectedItemID = pendingSelectedItemID
                self.pendingSelectedItemID = nil
            }

            guard let selectedItemID else { return }
            if !newValue.contains(where: { $0.id == selectedItemID }) {
                self.selectedItemID = nil
            }

            if self.selectedItemID == nil, let first = newValue.first {
                self.selectedItemID = first.id
            }
        }
        .task(id: selectedItemID) { await loadDetail() }
        .onReceive(NotificationCenter.default.publisher(for: .selectImagesBrowserItem)) { n in
            guard let sid = n.object as? String, sid == seedSession.id else { return }
            guard let requested = n.userInfo?["selectedItemID"] as? String else { return }
            let forceScope = n.userInfo?["forceScope"] as? String

            pendingSelectedItemID = requested
            if model.items.contains(where: { $0.id == requested }) {
                selectedItemID = requested
                pendingSelectedItemID = nil
                return
            }

            if forceScope == CodexImagesScope.singleSession.rawValue {
                // When jumping from an inline image click, bias filters toward the originating session.
                if let project = seedSession.repoName, !project.isEmpty {
                    selectedProject = project
                }
                selectedSources = [seedSession.source]
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
            projectFilterMenu
            agentFilterMenu

            Spacer()

            Text("\(model.items.count) image\(model.items.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var projectFilterMenu: some View {
        HStack(spacing: 8) {
            Text("Project:")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Menu {
                Button {
                    selectedProject = nil
                } label: {
                    if selectedProject == nil {
                        Label("All Projects", systemImage: "checkmark")
                    } else {
                        Text("All Projects")
                    }
                }

                if !availableProjects.isEmpty {
                    Divider()
                }

                ForEach(availableProjects, id: \.self) { project in
                    Button {
                        selectedProject = project
                    } label: {
                        if selectedProject == project {
                            Label(project, systemImage: "checkmark")
                        } else {
                            Text(project)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedProject ?? "All Projects")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.7)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    private var agentFilterMenu: some View {
        HStack(spacing: 8) {
            Text("Agent:")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Menu {
                Button {
                    selectedSources = Set(availableSources)
                } label: {
                    Label("All Agents", systemImage: selectedSources.count == availableSources.count ? "checkmark.square" : "square")
                }

                if !availableSources.isEmpty {
                    Divider()
                }

                ForEach(availableSources, id: \.self) { source in
                    Button {
                        toggleAgent(source)
                    } label: {
                        Label(source.displayName, systemImage: selectedSources.contains(source) ? "checkmark.square" : "square")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(agentMenuTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.7)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    private var agentMenuTitle: String {
        let all = Set(availableSources)
        if selectedSources == all { return "All Agents" }
        if selectedSources.count == 1, let one = selectedSources.first { return one.displayName }
        if selectedSources.isEmpty { return "No Agents" }
        return "\(selectedSources.count) selected"
    }

    private func toggleAgent(_ source: SessionSource) {
        if selectedSources.contains(source) {
            if selectedSources.count <= 1 { return }
            selectedSources.remove(source)
        } else {
            selectedSources.insert(source)
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
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
                        Text("These filters contain images, but none could be previewed here.")
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

    private var dateGroups: [DateGroup] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart

        let sorted = model.items.sorted { a, b in
            if a.sessionModifiedAt != b.sessionModifiedAt { return a.sessionModifiedAt > b.sessionModifiedAt }
            if a.sessionID != b.sessionID { return a.sessionID > b.sessionID }
            return a.span.startOffset > b.span.startOffset
        }

        var buckets: [Date: [CodexSessionImageItem]] = [:]
        for item in sorted {
            let day = calendar.startOfDay(for: item.sessionModifiedAt)
            buckets[day, default: []].append(item)
        }

        let orderedDays = buckets.keys.sorted(by: >)
        return orderedDays.map { dayStart in
            let title: String
            if dayStart == todayStart {
                title = "Today"
            } else if dayStart == yesterdayStart {
                title = "Yesterday"
            } else {
                title = AppDateFormatting.monthDayAbbrev(dayStart)
            }

            let id = ISO8601DateFormatter().string(from: dayStart)
            return DateGroup(id: id, title: title, items: buckets[dayStart] ?? [])
        }
    }

    private var loadingStatusText: String {
        if model.totalSessionsToScan > 0 {
            let total = model.totalSessionsToScan
            let completed = min(model.scannedSessions, total)
            if completed >= total { return "Finalizing scan…" }
            return "Scanning \(completed)/\(total) sessions for images…"
        }
        return "Scanning sessions for images…"
    }

    private var thumbnailsPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(dateGroups) { group in
                        Text(group.title.uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)

                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(group.items, id: \.id) { item in
                                CodexImageThumbnailCard(
                                    model: model,
                                    item: item,
                                    isSelected: item.id == selectedItemID,
                                    onSelect: { selectedItemID = item.id },
                                    onDoubleClick: { openInPreview(item: item) }
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

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = selectedItem {
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

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button("Navigate to Session") { navigateToSession(item: item) }
                            .buttonStyle(.borderedProminent)

                        Button(isSaving ? "Saving…" : "Save…") { saveWithPanel(item: item) }
                            .disabled(isSaving)

                        Spacer()
                    }

                    if let saveStatus {
                        Text(saveStatus)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("USER PROMPT")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(promptText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (promptText ?? "") : "Prompt unavailable")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(Color.gray.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                            GridRow {
                                metaLabel("SESSION")
                                metaValue(item.sessionTitle)
                            }
                            GridRow {
                                metaLabel("PROJECT")
                                metaValue(item.sessionProject ?? "—")
                            }
                            GridRow {
                                metaLabel("AGENT")
                                metaValue(item.sessionSource.displayName)
                            }
                            GridRow {
                                metaLabel("TIME")
                                metaValue(AppDateFormatting.dateTimeMedium(item.sessionModifiedAt))
                            }
                            GridRow {
                                metaLabel("SIZE")
                                metaValue(ByteCountFormatter.string(fromByteCount: Int64(item.span.approxBytes), countStyle: .file))
                            }
                            GridRow {
                                metaLabel("DIMENSIONS")
                                metaValue(dimensionsText ?? "—")
                            }
                        }
                        .padding(10)
                        .background(Color.gray.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
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

    private struct DateGroup: Identifiable, Hashable {
        let id: String
        let title: String
        let items: [CodexSessionImageItem]
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 140, maximum: 240), spacing: 12),
            GridItem(.flexible(minimum: 140, maximum: 240), spacing: 12),
            GridItem(.flexible(minimum: 140, maximum: 240), spacing: 12)
        ]
    }

    private var availableProjects: [String] {
        let projects = allSessions.compactMap { $0.repoName?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(projects)).sorted()
    }

    private var availableSources: [SessionSource] {
        let sources = Set(allSessions.map(\.source))
        return SessionSource.allCases.filter { sources.contains($0) }
    }

    private func ensureFiltersInitialized() {
        if selectedSources.isEmpty {
            selectedSources = Set(availableSources)
        } else {
            selectedSources = selectedSources.intersection(Set(availableSources))
        }
        if selectedProject != nil, !availableProjects.contains(selectedProject ?? "") {
            selectedProject = nil
        }
    }

    private var sessionsToScan: [Session] {
        let trimmedProject = selectedProject?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectFilter = (trimmedProject?.isEmpty == false) ? trimmedProject : nil

        return allSessions
            .filter { session in
                if let projectFilter {
                    return session.repoName == projectFilter
                }
                return true
            }
            .filter { selectedSources.contains($0.source) }
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
    }

    private var effectiveItemLimit: Int {
        if selectedProject == nil { return 2000 }
        return 1200
    }

    private func reload() {
        ensureFiltersInitialized()
        model.load(sessions: sessionsToScan, itemLimit: effectiveItemLimit)
    }

    private func closeWindow() {
        model.cancelLoad()
        saveTask?.cancel()
        saveTask = nil
        activeSaveToken = nil
        NSApp.keyWindow?.performClose(nil)
    }

    private func loadDetail() async {
        previewImage = nil
        previewError = nil
        promptText = nil
        dimensionsText = nil
        isPreviewLoading = false

        guard let item = selectedItem else { return }

        let url = item.sessionFileURL
        let span = item.span
        let maxDecodedBytes = model.maxDecodedBytes
        let previewMaxPixelSize = 3600
        let itemID = item.id

        isPreviewLoading = true

        async let prompt: String? = loadPromptText(item: item)
        async let preview: (NSImage?, String?, String?) = Task.detached(priority: .userInitiated) {
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(url: url,
                                                                          span: span,
                                                                          maxDecodedBytes: maxDecodedBytes,
                                                                          shouldCancel: { Task.isCancelled })
                guard let img = CodexSessionImagePayload.makeThumbnail(from: decoded, maxPixelSize: previewMaxPixelSize) else {
                    return (nil, "Unsupported image format.", nil)
                }
                let dims = ImageAttachmentPromptContextExtractor.dimensionsText(for: decoded)
                return (img, nil, dims)
            } catch is CancellationError {
                return (nil, nil, nil)
            } catch CodexSessionImagePayload.DecodeError.tooLarge {
                return (nil, "Image too large to preview.", nil)
            } catch CodexSessionImagePayload.DecodeError.invalidBase64 {
                return (nil, "Invalid image data.", nil)
            } catch {
                return (nil, "Failed to load image preview.", nil)
            }
        }.value

        let promptValue = await prompt
        let previewValue = await preview

        guard !Task.isCancelled else { return }
        guard selectedItemID == itemID else { return }

        isPreviewLoading = false
        previewImage = previewValue.0
        previewError = previewValue.1
        dimensionsText = previewValue.2
        promptText = promptValue
    }

    private func loadPromptText(item: CodexSessionImageItem) async -> String? {
        if Task.isCancelled { return nil }
        if let session = allSessions.first(where: { $0.id == item.sessionID }),
           !session.events.isEmpty,
           session.events.indices.contains(item.lineIndex),
           session.events[item.lineIndex].kind == .user,
           let text = session.events[item.lineIndex].text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        return ImageAttachmentPromptContextExtractor.extractPromptText(url: item.sessionFileURL, span: item.span)
    }

    private func itemTooltip(_ item: CodexSessionImageItem) -> String {
        "\(item.sessionTitle)\n\(AppDateFormatting.dateTimeMedium(item.sessionModifiedAt))"
    }

    private func navigateToSession(item: CodexSessionImageItem) {
        NotificationCenter.default.post(
            name: .navigateToSessionFromImages,
            object: item.sessionID,
            userInfo: ["eventID": item.eventID]
        )
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

private struct CodexImageThumbnailCard: View {
    @ObservedObject var model: CodexSessionImagesGalleryModel
    let item: CodexSessionImageItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.gray.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color(nsColor: .systemBlue).opacity(0.85) : Color.gray.opacity(0.18),
                                    lineWidth: isSelected ? 2 : 1)
                    )

                if let img = model.thumbnails[item.id] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(10)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 160)

            Text(ByteCountFormatter.string(fromByteCount: Int64(item.span.approxBytes), countStyle: .file))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onSelect()
            onDoubleClick()
        }
        .onTapGesture {
            onSelect()
        }
        .onAppear { model.requestThumbnail(for: item) }
    }
}
