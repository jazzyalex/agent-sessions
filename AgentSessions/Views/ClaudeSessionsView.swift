import SwiftUI
import AppKit

struct ClaudeSessionsView: View {
    @ObservedObject var indexer: ClaudeSessionIndexer
    let layoutMode: LayoutMode
    let onToggleLayout: () -> Void

    @State private var selection: String?
    @State private var directoryAlert: DirectoryAlert?

    private struct DirectoryAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            if layoutMode == .vertical {
                HSplitView {
                    ClaudeSessionsListView(indexer: indexer, selection: $selection)
                        .frame(minWidth: 320, idealWidth: 600, maxWidth: 1200)
                    ClaudeTranscriptView(indexer: indexer, sessionID: selection)
                        .frame(minWidth: 450)
                }
            } else {
                VSplitView {
                    ClaudeSessionsListView(indexer: indexer, selection: $selection)
                        .frame(minHeight: 180)
                    ClaudeTranscriptView(indexer: indexer, sessionID: selection)
                        .frame(minHeight: 240)
                }
            }
        }
        .preferredColorScheme(indexer.appAppearance.colorScheme)
        .onChange(of: selection) { _, newID in
            // Lazy load if needed
            if let id = newID, let session = indexer.allSessions.first(where: { $0.id == id }),
               session.events.isEmpty {
                indexer.reloadSession(id: id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ClaudeSearchFiltersView(indexer: indexer)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    if let session = selectedSession {
                        handleOpenWorkingDirectory(session)
                    }
                }) {
                    Label("Open Working Directory", systemImage: "folder")
                }
                .help("Reveal the session's working directory in Finder")
                .disabled(selectedSession == nil)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { indexer.refresh() }) {
                    if indexer.isIndexing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Refresh index")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { onToggleLayout() }) {
                    Image(systemName: layoutMode == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                }
                .help(layoutMode == .vertical ? "Switch to Horizontal Split" : "Switch to Vertical Split")
            }
        }
        .onChange(of: indexer.sessions) { _, sessions in
            guard !sessions.isEmpty else {
                selection = nil
                return
            }

            if let current = selection, sessions.contains(where: { $0.id == current }) {
                return
            }

            selection = sessions.first?.id
        }
        .alert(item: $directoryAlert) { alert in
            Alert(title: Text(alert.title),
                  message: Text(alert.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    private var selectedSession: Session? {
        guard let selection else { return nil }
        return indexer.sessions.first(where: { $0.id == selection }) ?? indexer.allSessions.first(where: { $0.id == selection })
    }

    private func handleOpenWorkingDirectory(_ session: Session) {
        guard let path = session.cwd, !path.isEmpty else {
            directoryAlert = DirectoryAlert(title: "Working Directory Unavailable",
                                           message: "No working directory is associated with this session.")
            return
        }

        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            directoryAlert = DirectoryAlert(title: "Directory Not Found",
                                           message: "The working directory \(path) does not exist.")
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// Wrapper for SessionsListView that bridges ClaudeSessionIndexer
private struct ClaudeSessionsListView: View {
    @ObservedObject var indexer: ClaudeSessionIndexer
    @Binding var selection: String?
    @State private var tableSelection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<Session>] = []
    @State private var cachedRows: [Session] = []

    private var rows: [Session] { cachedRows }

    var body: some View {
        Table(rows, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("Session", value: \Session.title) { s in
                Text(s.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 160, ideal: 320, max: 2000)

            TableColumn("Date", value: \Session.modifiedAt) { s in
                Text(s.modifiedRelative)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 120, max: 140)

            TableColumn("Project", value: \Session.repoDisplay) { s in
                Text(s.repoDisplay)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) {
                        if let name = s.repoName {
                            indexer.projectFilter = name
                            indexer.recomputeNow()
                        }
                    }
            }
            .width(min: 120, ideal: 160, max: 240)

            TableColumn("Msgs", value: \Session.messageCount) { s in
                Text("\(s.messageCount)")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
            }
            .width(min: 64, ideal: 64, max: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .environment(\.defaultMinListRowHeight, 22)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenuContent(for: ids)
        }
        .navigationTitle("Claude Code Sessions")
        .onChange(of: sortOrder) { _, _ in
            updateCachedRows()
        }
        .onChange(of: tableSelection) { oldSel, newSel in
            // Force single selection
            if newSel.count > 1 {
                // Keep only the newly selected item
                let newlySelected = newSel.subtracting(oldSel)
                if let newItem = newlySelected.first {
                    DispatchQueue.main.async {
                        tableSelection = [newItem]
                        selection = newItem
                    }
                } else if let first = newSel.first {
                    DispatchQueue.main.async {
                        tableSelection = [first]
                        selection = first
                    }
                }
                return
            }
            selection = newSel.first
        }
        .onChange(of: indexer.sessions) { _, _ in
            updateCachedRows()
        }
        .onChange(of: selection) { _, newValue in
            let desired: Set<String> = newValue.map { [$0] } ?? []
            if tableSelection != desired {
                tableSelection = desired
            }
        }
        .onAppear {
            if let sel = selection { tableSelection = [sel] }
            if sortOrder.isEmpty {
                sortOrder = [KeyPathComparator(\Session.modifiedAt, order: .reverse)]
            }
            updateCachedRows()
        }
    }

    private func updateCachedRows() {
        cachedRows = indexer.sessions.sorted(using: sortOrder)
    }

    private func session(for id: String) -> Session? {
        rows.first(where: { $0.id == id }) ?? indexer.sessions.first(where: { $0.id == id })
    }

    @ViewBuilder
    private func contextMenuContent(for selectedIDs: Set<String>) -> some View {
        if selectedIDs.count == 1,
           let id = selectedIDs.first,
           let session = session(for: id) {
            Button("Open Working Directory") {
                openWorkingDirectory(session)
            }
            .disabled(session.cwd == nil || session.cwd?.isEmpty == true)

            if let name = session.repoName, !name.isEmpty {
                Divider()
                Button("Filter by Project: \(name)") {
                    indexer.projectFilter = name
                    indexer.recomputeNow()
                }
            } else {
                Divider()
                Button("Filter by Project") {}.disabled(true)
            }
        } else {
            Button("Open Working Directory") {}.disabled(true)
            Button("Filter by Project") {}.disabled(true)
        }
    }

    private func openWorkingDirectory(_ session: Session) {
        guard let path = session.cwd, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// Wrapper for transcript view using SessionTranscriptBuilder for consistent formatting
private struct ClaudeTranscriptView: View {
    @ObservedObject var indexer: ClaudeSessionIndexer
    let sessionID: String?

    // Plain transcript buffer
    @State private var transcript: String = ""

    // Find
    @State private var findText: String = ""
    @State private var findMatches: [Range<String.Index>] = []
    @State private var currentMatchIndex: Int = 0
    @FocusState private var findFocused: Bool
    @State private var highlightRanges: [NSRange] = []
    @State private var commandRanges: [NSRange] = []
    @State private var userRanges: [NSRange] = []
    @State private var assistantRanges: [NSRange] = []
    @State private var outputRanges: [NSRange] = []
    @State private var errorRanges: [NSRange] = []

    // Toggles (view-scoped)
    @State private var showTimestamps: Bool = false
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("TranscriptRenderMode") private var renderModeRaw: String = TranscriptRenderMode.normal.rawValue

    // Auto-colorize in Terminal mode
    private var shouldColorize: Bool {
        return renderModeRaw == TranscriptRenderMode.terminal.rawValue
    }

    // Selection for auto-scroll to find matches
    @State private var selectedNSRange: NSRange? = nil

    var body: some View {
        if let id = sessionID, let session = indexer.allSessions.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                toolbar(session: session)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                Divider()
                ZStack {
                    PlainTextScrollView(
                        text: transcript,
                        selection: selectedNSRange,
                        fontSize: CGFloat(transcriptFontSize),
                        highlights: highlightRanges,
                        currentIndex: currentMatchIndex,
                        commandRanges: shouldColorize ? commandRanges : [],
                        userRanges: shouldColorize ? userRanges : [],
                        assistantRanges: shouldColorize ? assistantRanges : [],
                        outputRanges: shouldColorize ? outputRanges : [],
                        errorRanges: shouldColorize ? errorRanges : []
                    )

                    if indexer.isLoadingSession && indexer.loadingSessionID == id {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Loading session...")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
                        .cornerRadius(12)
                        .shadow(radius: 8)
                    }
                }
            }
            .onAppear { rebuild(session: session) }
            .onChange(of: id) { _, _ in rebuild(session: session) }
            .onChange(of: renderModeRaw) { _, _ in rebuild(session: session) }
            .onChange(of: session.events.count) { _, _ in rebuild(session: session) }
        } else {
            Text("Select a session to view transcript")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func toolbar(session: Session) -> some View {
        HStack(spacing: 6) {
            // Find controls group
            HStack(spacing: 4) {
                Button(action: { performFind(resetIndex: true) }) {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Find")

                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 180)
                    .focused($findFocused)
                    .onSubmit { performFind(resetIndex: true) }

                Button(action: { performFind(resetIndex: false, direction: -1) }) {
                    Image(systemName: "chevron.up")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Previous match")
                .disabled(findMatches.isEmpty)

                Button(action: { performFind(resetIndex: false, direction: 1) }) {
                    Image(systemName: "chevron.down")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Next match")
                .disabled(findMatches.isEmpty)

                if !findText.isEmpty {
                    Text("\(findMatches.isEmpty ? 0 : currentMatchIndex + 1)/\(findMatches.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minWidth: 35)
                }

                Divider().frame(height: 20)

                HStack(spacing: 2) {
                    Button(action: { adjustFont(-1) }) {
                        Image(systemName: "textformat.size.smaller")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help("Smaller (Cmd-)")

                    Button(action: { adjustFont(1) }) {
                        Image(systemName: "textformat.size.larger")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help("Bigger (Cmd+=)")
                }

                Button("Copy") { copyAll() }
                    .buttonStyle(.borderless)
                    .help("Copy entire transcript")
            }

            Divider().frame(height: 20)

            Spacer(minLength: 8)

            // View controls group
            HStack(spacing: 6) {
                Picker("View Style", selection: $renderModeRaw) {
                    Text("Transcript").tag(TranscriptRenderMode.normal.rawValue)
                    Text("Terminal").tag(TranscriptRenderMode.terminal.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 44)
    }

    private func rebuild(session: Session) {
        let filters: TranscriptFilters = .current(showTimestamps: showTimestamps, showMeta: false)
        let mode = TranscriptRenderMode(rawValue: renderModeRaw) ?? .normal

        if mode == .terminal && shouldColorize {
            let built = SessionTranscriptBuilder.buildTerminalPlainWithRanges(session: session, filters: filters)
            transcript = built.0
            commandRanges = built.1
            userRanges = built.2
            assistantRanges = []
            outputRanges = []
            errorRanges = []
            findAdditionalRanges()
        } else {
            transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: filters, mode: mode)
            commandRanges = []
            userRanges = []
            assistantRanges = []
            outputRanges = []
            errorRanges = []
        }

        // Reset find state
        performFind(resetIndex: true)
        selectedNSRange = nil
        updateSelectionToCurrentMatch()
    }

    private func performFind(resetIndex: Bool, direction: Int = 1) {
        let q = findText
        guard !q.isEmpty else {
            findMatches = []
            currentMatchIndex = 0
            highlightRanges = []
            return
        }

        let lowerText = transcript.lowercased()
        let lowerQ = q.lowercased()
        var matches: [Range<String.Index>] = []
        var searchStart = lowerText.startIndex
        while let r = lowerText.range(of: lowerQ, range: searchStart..<lowerText.endIndex) {
            let origStart = transcript.index(transcript.startIndex, offsetBy: lowerText.distance(from: lowerText.startIndex, to: r.lowerBound))
            let origEnd = transcript.index(origStart, offsetBy: lowerQ.count)
            matches.append(origStart..<origEnd)
            searchStart = r.upperBound
        }

        findMatches = matches
        var nsRanges: [NSRange] = []
        for r in matches {
            if let nsr = NSRange(r, in: transcript) as NSRange? { nsRanges.append(nsr) }
        }
        highlightRanges = nsRanges
        if resetIndex { currentMatchIndex = matches.isEmpty ? 0 : 0 }
        else if !matches.isEmpty {
            currentMatchIndex = (currentMatchIndex + direction + matches.count) % matches.count
        }
        updateSelectionToCurrentMatch()
    }

    private func updateSelectionToCurrentMatch() {
        guard !findMatches.isEmpty else { selectedNSRange = nil; return }
        let range = findMatches[min(currentMatchIndex, findMatches.count - 1)]
        if let nsRange = NSRange(range, in: transcript) as NSRange? { selectedNSRange = nsRange }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private func adjustFont(_ delta: Double) {
        transcriptFontSize = max(9, min(30, transcriptFontSize + delta))
    }

    private func findAdditionalRanges() {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        var cursor = 0

        for line in lines {
            let s = String(line)
            var lineStr = s
            var timestampOffset = 0
            if lineStr.count >= 9, lineStr[lineStr.index(lineStr.startIndex, offsetBy: 2)] == ":" {
                if let space = lineStr.firstIndex(of: " ") {
                    timestampOffset = lineStr.distance(from: lineStr.startIndex, to: lineStr.index(after: space))
                    lineStr = String(lineStr[lineStr.index(after: space)...])
                }
            }

            if lineStr.hasPrefix("⟪out⟫ ") {
                let start = cursor + timestampOffset
                let len = (s as NSString).length - timestampOffset
                if len > 0 { outputRanges.append(NSRange(location: start, length: len)) }
            }
            else if lineStr.hasPrefix("! error ") {
                let start = cursor + timestampOffset
                let len = (s as NSString).length - timestampOffset
                if len > 0 { errorRanges.append(NSRange(location: start, length: len)) }
            }
            else if !lineStr.isEmpty && !lineStr.hasPrefix("⟪") && !lineStr.hasPrefix("›") && !lineStr.hasPrefix("!") && !lineStr.hasPrefix("> ") && !lineStr.hasPrefix("bash ") && !lineStr.hasPrefix("cd ") {
                let start = cursor + timestampOffset
                let len = (s as NSString).length - timestampOffset
                if len > 0 { assistantRanges.append(NSRange(location: start, length: len)) }
            }

            cursor += (s as NSString).length + 1
        }
    }
}

// MARK: - NSViewRepresentable plain text, selectable, scrollable
private struct PlainTextScrollView: NSViewRepresentable {
    let text: String
    let selection: NSRange?
    let fontSize: CGFloat
    let highlights: [NSRange]
    var currentIndex: Int = 0
    let commandRanges: [NSRange]
    let userRanges: [NSRange]
    let assistantRanges: [NSRange]
    let outputRanges: [NSRange]
    let errorRanges: [NSRange]

    class Coordinator { var lastWidth: CGFloat = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let tv = nsView.documentView as? NSTextView {
            if tv.string != text { tv.string = text }
            if let font = tv.font, abs(font.pointSize - fontSize) > 0.5 {
                tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }
            if let sel = selection {
                tv.setSelectedRange(sel)
                tv.scrollRangeToVisible(sel)
            }
            applyHighlights(tv)
        }
    }

    private func applyHighlights(_ tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)

        // Command colorization (foreground)
        if !commandRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseGreen = NSColor.systemGreen
            let green: NSColor = {
                if isDark || increaseContrast { return baseGreen }
                return baseGreen.withAlphaComponent(0.88)
            }()
            for r in commandRanges {
                if NSMaxRange(r) <= full.length {
                    lm.addTemporaryAttribute(.foregroundColor, value: green, forCharacterRange: r)
                }
            }
        }

        // User input colorization (blue)
        if !userRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseBlue = NSColor.systemBlue
            let blue: NSColor = {
                if isDark || increaseContrast { return baseBlue }
                return baseBlue.withAlphaComponent(0.9)
            }()
            for r in userRanges {
                if NSMaxRange(r) <= full.length {
                    lm.addTemporaryAttribute(.foregroundColor, value: blue, forCharacterRange: r)
                }
            }
        }

        // Assistant response colorization (subtle gray)
        if !assistantRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseGray = NSColor.secondaryLabelColor
            let gray: NSColor = {
                if isDark || increaseContrast { return baseGray }
                return baseGray.withAlphaComponent(0.8)
            }()
            for r in assistantRanges {
                if NSMaxRange(r) <= full.length {
                    lm.addTemporaryAttribute(.foregroundColor, value: gray, forCharacterRange: r)
                }
            }
        }

        // Tool output colorization (dimmed green)
        if !outputRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseGreen = NSColor.systemGreen
            let dimmedGreen: NSColor = {
                if isDark || increaseContrast { return baseGreen.withAlphaComponent(0.6) }
                return baseGreen.withAlphaComponent(0.5)
            }()
            for r in outputRanges {
                if NSMaxRange(r) <= full.length {
                    lm.addTemporaryAttribute(.foregroundColor, value: dimmedGreen, forCharacterRange: r)
                }
            }
        }

        // Error colorization (red)
        if !errorRanges.isEmpty {
            let isDark = (tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let baseRed = NSColor.systemRed
            let red: NSColor = {
                if isDark || increaseContrast { return baseRed }
                return baseRed.withAlphaComponent(0.9)
            }()
            for r in errorRanges {
                if NSMaxRange(r) <= full.length {
                    lm.addTemporaryAttribute(.foregroundColor, value: red, forCharacterRange: r)
                }
            }
        }

        // Find match background highlights
        guard !highlights.isEmpty else { return }
        let matchBG = NSColor.systemYellow.withAlphaComponent(0.35)
        let currentBG = NSColor.systemOrange.withAlphaComponent(0.55)
        for (i, r) in highlights.enumerated() {
            if NSMaxRange(r) <= full.length {
                let color = (i == currentIndex) ? currentBG : matchBG
                lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: r)
            }
        }
    }
}

// MARK: - Search Filters for Claude Sessions
private struct ClaudeSearchFiltersView: View {
    @ObservedObject var indexer: ClaudeSessionIndexer
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search", text: $indexer.queryDraft)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 160)
                    .focused($isSearchFocused)
                    .onSubmit { indexer.applySearch() }

                Button(action: { indexer.applySearch() }) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Search transcripts")

                if !indexer.queryDraft.isEmpty {
                    Button(action: {
                        indexer.queryDraft = ""
                        indexer.query = ""
                        indexer.recomputeNow()
                    }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))

            // Show active project filter with clear button
            if let projectFilter = indexer.projectFilter, !projectFilter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(projectFilter)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Button(action: {
                        indexer.projectFilter = nil
                        indexer.recomputeNow()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear project filter")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3)))
            }

            Spacer(minLength: 0)
        }
    }
}

