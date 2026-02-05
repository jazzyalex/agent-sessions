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
    @ObservedObject var viewModel: ImageBrowserViewModel

    @State private var pendingSelectedItemID: String? = nil

    @State private var isPreviewLoading: Bool = false
    @State private var previewImage: NSImage? = nil
    @State private var previewError: String? = nil
    @State private var promptText: String? = nil
    @State private var dimensionsText: String? = nil

    @State private var isSaving: Bool = false
    @State private var saveStatus: String? = nil
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var activeSaveToken: UUID? = nil

    init(viewModel: ImageBrowserViewModel) {
        self.viewModel = viewModel
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
        .onAppear { viewModel.markWindowShown() }
        .onChange(of: viewModel.selectedProject) { _, _ in viewModel.onFiltersChanged() }
        .onChange(of: viewModel.selectedSources) { _, _ in viewModel.onFiltersChanged() }
        .onChange(of: viewModel.items) { _, newValue in
            if let pendingSelectedItemID, newValue.contains(where: { $0.id == pendingSelectedItemID }) {
                viewModel.selectedItemID = pendingSelectedItemID
                self.pendingSelectedItemID = nil
            }

            if let selectedItemID = viewModel.selectedItemID, !newValue.contains(where: { $0.id == selectedItemID }) {
                viewModel.selectedItemID = nil
            }

            if viewModel.selectedItemID == nil, let first = newValue.first {
                viewModel.selectedItemID = first.id
            }
        }
        .task(id: viewModel.selectedItemID) { await loadDetail() }
        .onReceive(NotificationCenter.default.publisher(for: .selectImagesBrowserItem)) { n in
            guard let sid = n.object as? String, sid == viewModel.seedSessionID else { return }
            guard let requested = n.userInfo?["selectedItemID"] as? String else { return }

            pendingSelectedItemID = requested
            if viewModel.items.contains(where: { $0.id == requested }) {
                viewModel.selectedItemID = requested
                pendingSelectedItemID = nil
                return
            }
        }
        .onDisappear {
            viewModel.cancelBackgroundWork()
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

            Text("\(viewModel.items.count) image\(viewModel.items.count == 1 ? "" : "s")")
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
                    viewModel.selectedProject = nil
                } label: {
                    if viewModel.selectedProject == nil {
                        Label("All Projects", systemImage: "checkmark")
                    } else {
                        Text("All Projects")
                    }
                }

                if !viewModel.availableProjects.isEmpty {
                    Divider()
                }

                ForEach(viewModel.availableProjects, id: \.self) { project in
                    Button {
                        viewModel.selectedProject = project
                    } label: {
                        if viewModel.selectedProject == project {
                            Label(project, systemImage: "checkmark")
                        } else {
                            Text(project)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(viewModel.selectedProject ?? "All Projects")
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
                    viewModel.selectedSources = viewModel.allCodingSources
                } label: {
                    agentMenuCheckboxRow(
                        title: "All Coding Agents",
                        isOn: viewModel.isAllCodingAgentsSelected
                    )
                }

                if !viewModel.availableSources.isEmpty {
                    Divider()
                }

                ForEach(viewModel.availableSources, id: \.self) { source in
                    Button {
                        toggleAgent(source)
                    } label: {
                        agentMenuCheckboxRow(title: source.displayName, isOn: viewModel.selectedSources.contains(source))
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

    @ViewBuilder
    private func agentMenuCheckboxRow(title: String, isOn: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
            Text(title)
        }
    }

    private var agentMenuTitle: String {
        let selected = viewModel.selectedSources
        if viewModel.isAllCodingAgentsSelected { return "All Coding Agents" }
        if selected.count == 1, let one = selected.first { return one.displayName }
        if selected.isEmpty { return "No Agents" }
        return "\(selected.count) selected"
    }

    private func toggleAgent(_ source: SessionSource) {
        if viewModel.selectedSources.contains(source) {
            if viewModel.selectedSources.count <= 1 { return }
            viewModel.selectedSources.remove(source)
        } else {
            viewModel.selectedSources.insert(source)
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
        switch viewModel.state {
        case .idle, .loadingSelected:
            if viewModel.items.isEmpty {
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

        case .indexingBackground, .loaded:
            if viewModel.items.isEmpty {
                ContentUnavailableView("No images found", systemImage: "photo")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
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

        let sorted = viewModel.items.sorted { a, b in
            if a.sessionModifiedAt != b.sessionModifiedAt { return a.sessionModifiedAt > b.sessionModifiedAt }
            if a.sessionID != b.sessionID { return a.sessionID > b.sessionID }
            return a.sortOffset > b.sortOffset
        }

        var buckets: [Date: [ImageBrowserViewModel.Item]] = [:]
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
        switch viewModel.state {
        case .loadingSelected:
            return "Indexing selected session…"
        case .indexingBackground:
            return "Indexing images…"
        case .failed:
            return "Index failed."
        case .idle, .loaded:
            return "Ready"
        }
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
                                    viewModel: viewModel,
                                    item: item,
                                    isSelected: item.id == viewModel.selectedItemID,
                                    onSelect: { viewModel.selectedItemID = item.id },
                                    onDoubleClick: { openInPreview(item: item) }
                                )
                                .contextMenu {
                                    imageActionsMenu(for: item)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: viewModel.selectedItemID) { _, newValue in
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

                        Button {
                            openInPreview(item: item)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Open in Preview")

                        Button {
                            copyImagePath(item: item)
                        } label: {
                            Image(systemName: "link")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Copy Image Path (for CLI agent)")

                        Button {
                            copyImage(item: item)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Copy Image")

                        Button {
                            saveToDownloads(item: item)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .disabled(isSaving)
                        .help("Save to Downloads")

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
                                metaValue(ByteCountFormatter.string(fromByteCount: Int64(item.payload.approxBytes), countStyle: .file))
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

    private var selectedItem: ImageBrowserViewModel.Item? {
        guard let selectedItemID = viewModel.selectedItemID else { return nil }
        return viewModel.items.first(where: { $0.id == selectedItemID })
    }

    private struct DateGroup: Identifiable, Hashable {
        let id: String
        let title: String
        let items: [ImageBrowserViewModel.Item]
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 140, maximum: 240), spacing: 12),
            GridItem(.flexible(minimum: 140, maximum: 240), spacing: 12),
            GridItem(.flexible(minimum: 140, maximum: 240), spacing: 12)
        ]
    }

    private func loadDetail() async {
        previewImage = nil
        previewError = nil
        promptText = nil
        dimensionsText = nil
        isPreviewLoading = false

        guard let item = selectedItem else { return }

        let maxDecodedBytes = 25 * 1024 * 1024
        let previewMaxPixelSize = 3600
        let itemID = item.id

        isPreviewLoading = true

        async let prompt: String? = loadPromptText(item: item)
        async let preview: (NSImage?, String?, String?) = Task.detached(priority: .userInitiated) {
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(payload: item.payload,
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
        guard viewModel.selectedItemID == itemID else { return }

        isPreviewLoading = false
        previewImage = previewValue.0
        previewError = previewValue.1
        dimensionsText = previewValue.2
        promptText = promptValue
    }

    private func loadPromptText(item: ImageBrowserViewModel.Item) async -> String? {
        if Task.isCancelled { return nil }
        if let fromLoaded = viewModel.loadedUserPromptText(for: item) { return fromLoaded }
        // Performance-first: do not scan files for prompt context. Prompt text appears only when the
        // selected session was fully parsed and prompt text is already in memory.
        return nil
    }

    private func navigateToSession(item: ImageBrowserViewModel.Item) {
        NotificationCenter.default.post(
            name: .navigateToSessionFromImages,
            object: item.sessionID,
            userInfo: ["eventID": item.eventID, "userPromptIndex": item.userPromptIndex as Any]
        )
    }

    @ViewBuilder
    private func imageActionsMenu(for item: ImageBrowserViewModel.Item) -> some View {
        Button("Open in Preview") { openInPreview(item: item) }

        Divider()

        Button("Copy Image Path (for CLI agent)") { copyImagePath(item: item) }
        Button("Copy Image") { copyImage(item: item) }

        Divider()

        Button("Save to Downloads") { saveToDownloads(item: item) }
        Button("Save…") { saveWithPanel(item: item) }
    }

    private func copyImage(item: ImageBrowserViewModel.Item) {
        let maxDecodedBytes = 25 * 1024 * 1024
        Task(priority: .userInitiated) {
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(payload: item.payload,
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

    private func copyImagePath(item: ImageBrowserViewModel.Item) {
        let maxDecodedBytes = 25 * 1024 * 1024
        Task(priority: .userInitiated) {
            do {
                let fileURL: URL
                switch item.payload {
                case .file(let originalURL, _, _):
                    fileURL = originalURL
                case .base64:
                    let decoded = try CodexSessionImagePayload.decodeImageData(payload: item.payload,
                                                                              maxDecodedBytes: maxDecodedBytes)
                    fileURL = try writeClipboardImageFile(item: item, data: decoded)
                }
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

    private func openInPreview(item: ImageBrowserViewModel.Item) {
        let maxDecodedBytes = 25 * 1024 * 1024
        Task(priority: .userInitiated) {
            do {
                switch item.payload {
                case .file(let originalURL, _, _):
                    await MainActor.run { openInPreviewApp(originalURL) }
                case .base64:
                    let decoded = try CodexSessionImagePayload.decodeImageData(payload: item.payload,
                                                                              maxDecodedBytes: maxDecodedBytes)
                    let fileURL = try writePreviewImageFile(item: item, data: decoded)
                    await MainActor.run {
                        openInPreviewApp(fileURL)
                    }
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

    private func quickLook(item: ImageBrowserViewModel.Item) {
        let maxDecodedBytes = 25 * 1024 * 1024
        Task(priority: .userInitiated) {
            do {
                let fileURL: URL
                switch item.payload {
                case .file(let originalURL, _, _):
                    fileURL = originalURL
                case .base64:
                    let decoded = try CodexSessionImagePayload.decodeImageData(payload: item.payload,
                                                                              maxDecodedBytes: maxDecodedBytes)
                    fileURL = try writePreviewImageFile(item: item, data: decoded)
                }
                await MainActor.run {
                    QuickLookPreviewController.shared.preview(urls: [fileURL])
                }
            } catch {
                // Best-effort preview; no UI error.
            }
        }
    }

    private func writeClipboardImageFile(item: ImageBrowserViewModel.Item, data: Data) throws -> URL {
        let ext = CodexSessionImagePayload.suggestedFileExtension(for: item.payload.mediaType)
        let tempRoot = FileManager.default.temporaryDirectory
        let dir = tempRoot.appendingPathComponent("AgentSessions/ImageClipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = suggestedFileName(for: item, ext: ext)
        let destination = uniqueDestinationURL(in: dir, filename: filename)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    private func writePreviewImageFile(item: ImageBrowserViewModel.Item, data: Data) throws -> URL {
        let ext = CodexSessionImagePayload.suggestedFileExtension(for: item.payload.mediaType)
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

    private func saveWithPanel(item: ImageBrowserViewModel.Item) {
        let ext = CodexSessionImagePayload.suggestedFileExtension(for: item.payload.mediaType)
        let utType = CodexSessionImagePayload.suggestedUTType(for: item.payload.mediaType)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFileName(for: item, ext: ext)

        let destinationKeyWindow = NSApp.keyWindow
        let maxDecodedBytes = 25 * 1024 * 1024
        let token = UUID()

        let onComplete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            beginSave(token: token,
                      destination: destination,
                      payload: item.payload,
                      maxDecodedBytes: maxDecodedBytes,
                      successStatus: nil)
        }

        if let win = destinationKeyWindow {
            panel.beginSheetModal(for: win, completionHandler: onComplete)
        } else {
            onComplete(panel.runModal())
        }
    }

    private func saveToDownloads(item: ImageBrowserViewModel.Item) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            saveStatus = "Downloads folder not found."
            return
        }

        let ext = CodexSessionImagePayload.suggestedFileExtension(for: item.payload.mediaType)
        let filename = suggestedFileName(for: item, ext: ext)
        let destination = uniqueDestinationURL(in: downloads, filename: filename)
        let token = UUID()

        beginSave(token: token,
                  destination: destination,
                  payload: item.payload,
                  maxDecodedBytes: 25 * 1024 * 1024,
                  successStatus: "Saved to Downloads.")
    }

    private func beginSave(token: UUID,
                           destination: URL,
                           payload: SessionImagePayload,
                           maxDecodedBytes: Int,
                           successStatus: String?) {
        saveTask?.cancel()
        activeSaveToken = token

        isSaving = true
        saveStatus = nil

        saveTask = Task(priority: .userInitiated) {
            do {
                let decoded = try CodexSessionImagePayload.decodeImageData(payload: payload,
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

    private func suggestedFileName(for item: ImageBrowserViewModel.Item, ext: String) -> String {
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
    @ObservedObject var viewModel: ImageBrowserViewModel
    let item: ImageBrowserViewModel.Item
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

                if let img = viewModel.thumbnails[item.id] {
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

            Text(item.approxSizeText)
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
        .onAppear { viewModel.requestThumbnail(for: item) }
    }
}
