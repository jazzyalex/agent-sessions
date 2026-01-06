import SwiftUI
import AppKit

private enum SessionsListStyle {
    static let selectionAccent = Color(hex: "007acc")
    static let timestampColor = Color(hex: "8E8E93")
}

struct SessionsListView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @EnvironmentObject var columnVisibility: ColumnVisibilityStore
    @Binding var selection: String?
    let onLaunchTerminal: (Session) -> Void
    let onOpenWorkingDirectory: (Session) -> Void
    // Table selection uses Set; keep a single-selection bridge
    @State private var tableSelection: Set<String> = []
    // Table sort order uses comparators
    @State private var sortOrder: [KeyPathComparator<Session>] = []

    @State private var cachedRows: [Session] = []

    private var rows: [Session] { cachedRows }

    var body: some View {
        Table(rows, selection: $tableSelection, sortOrder: $sortOrder) {
            // Session (first column)
            TableColumn("Session", value: \Session.title) { s in
                Text(s.codexDisplayTitle)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(
                min: columnVisibility.showTitleColumn ? 160 : 0,
                ideal: columnVisibility.showTitleColumn ? 320 : 0,
                max: columnVisibility.showTitleColumn ? 2000 : 0
            )

            // Date (renamed from Modified)
            TableColumn("Date", value: \Session.modifiedAt) { s in
                let display = indexer.modifiedDisplay
                let primary = (display == .relative) ? s.modifiedRelative : absoluteTime(s.modifiedAt)
                let helpText = (display == .relative) ? absoluteTime(s.modifiedAt) : s.modifiedRelative
                Text(primary)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(SessionsListStyle.timestampColor)
                    .help(helpText)
            }
            .width(
                min: columnVisibility.showModifiedColumn ? 120 : 0,
                ideal: columnVisibility.showModifiedColumn ? 120 : 0,
                max: columnVisibility.showModifiedColumn ? 140 : 0
            )

            // Project
            TableColumn("Project", value: \Session.repoDisplay) { s in
                Text(s.repoDisplay)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(projectTooltip(for: s))
                    .onTapGesture(count: 2) {
                        if let name = s.repoName {
                            indexer.projectFilter = name
                            indexer.recomputeNow()
                        }
                    }
            }
            .width(
                min: columnVisibility.showProjectColumn ? 120 : 0,
                ideal: columnVisibility.showProjectColumn ? 160 : 0,
                max: columnVisibility.showProjectColumn ? 240 : 0
            )

            // Msgs
            TableColumn("Msgs", value: \Session.messageCount) { s in
                Text(String(s.messageCount))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(
                min: columnVisibility.showMsgsColumn ? 64 : 0,
                ideal: columnVisibility.showMsgsColumn ? 64 : 0,
                max: columnVisibility.showMsgsColumn ? 80 : 0
            )

            // Size
            TableColumn("Size", value: \Session.fileSizeSortKey) { s in
                let display: String = {
                    if let b = s.fileSizeBytes { return formattedSize(b) }
                    return "—"
                }()
                Text(display)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(
                min: columnVisibility.showSizeColumn ? 72 : 0,
                ideal: columnVisibility.showSizeColumn ? 80 : 0,
                max: columnVisibility.showSizeColumn ? 100 : 0
            )

        }
        .id(columnVisibility.changeToken)
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .tint(SessionsListStyle.selectionAccent)
        .environment(\.defaultMinListRowHeight, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenuContent(for: ids)
        }
        .navigationTitle("Codex CLI Sessions")
        .overlay {
            // Error states as overlay to preserve layout structure for split views
            if let error = indexer.indexingError {
                ContentUnavailableView {
                    Label("Indexing Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        indexer.refresh()
                    }
                    Button("Choose Different Directory") {
                        indexer.sessionsRootOverride = ""
                        indexer.refresh()
                    }
                }
            } else if indexer.hasEmptyDirectory && !indexer.isIndexing {
                ContentUnavailableView {
                    Label("No Sessions Found", systemImage: "folder")
                } description: {
                    Text("No Codex session files found in \(indexer.sessionsRoot().path)")
                    Text("Session files are named 'rollout-*.jsonl'")
                } actions: {
                    Button("Refresh") {
                        indexer.refresh()
                    }
                    Button("Choose Different Directory") {
                        indexer.sessionsRootOverride = ""
                        indexer.refresh()
                    }
                }
            } else if rows.isEmpty && !indexer.isIndexing {
                ContentUnavailableView {
                    Label("No Sessions Match Filters", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Try adjusting your search or filter settings")
                } actions: {
                    Button("Clear Filters") {
                        indexer.query = ""
                        indexer.projectFilter = nil
                        indexer.dateFrom = nil
                        indexer.dateTo = nil
                    }
                }
            }
        }
        // No Codex matching mode for now; always show Codex-style titles, full list
        .onChange(of: sortOrder) { _, newValue in
            if let first = newValue.first {
                // Map to view model descriptor
                let key: SessionIndexer.SessionSortDescriptor.Key
                if first.keyPath == \Session.modifiedAt { key = .modified }
                else if first.keyPath == \Session.messageCount { key = .msgs }
                else if first.keyPath == \Session.repoDisplay { key = .repo }
                else if first.keyPath == \Session.fileSizeSortKey { key = .size }
                else if first.keyPath == \Session.title { key = .title }
                else { key = .title }
                indexer.sortDescriptor = .init(key: key, ascending: first.order == .forward)
            }
            updateCachedRows()
        }
        .onChange(of: tableSelection) { _, newSel in
            // Prevent clearing selection by clicking empty whitespace in the table
            if newSel.isEmpty, let current = selection {
                if tableSelection != [current] {
                    tableSelection = [current]
                }
                return
            }
            if newSel.count > 1, let first = newSel.first {
                let trimmed: Set<String> = [first]
                if newSel != trimmed {
                    tableSelection = trimmed
                    return
                }
            }
            selection = newSel.first
        }
        .onChange(of: indexer.sessions) { _, _ in
            updateCachedRows()
        }
        .onChange(of: columnVisibility.changeToken) { _, _ in
            updateCachedRows()
            if let current = selection {
                tableSelection = [current]
            }
        }
        .onChange(of: selection) { _, newValue in
            let desired: Set<String>
            if let id = newValue {
                desired = [id]
            } else {
                desired = []
            }

            if tableSelection != desired {
                tableSelection = desired
            }
        }
        .onAppear {
            // Seed initial selection
            if let sel = selection { tableSelection = [sel] }
            if sortOrder.isEmpty {
                sortOrder = [ KeyPathComparator(\Session.modifiedAt, order: .reverse) ]
            }
            updateCachedRows()
        }
    }

    private func updateCachedRows() {
        cachedRows = indexer.sessions.sorted(using: sortOrder)
        // Select the most recent session as soon as we have rows
        if selection == nil, let first = cachedRows.first {
            selection = first.id
            tableSelection = [first.id]
        }
    }

    private func session(for id: String) -> Session? {
        rows.first(where: { $0.id == id }) ?? indexer.sessions.first(where: { $0.id == id })
    }

    // MARK: - Git Inspector Integration
    private var isGitInspectorEnabled: Bool {
        let flagEnabled = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.enableGitInspector)
        let envEnabled = ProcessInfo.processInfo.environment["AGENTSESSIONS_FEATURES"]?.contains("gitInspector") == true
        return flagEnabled || envEnabled
    }

    private func showGitInspector(_ session: Session) {
        GitInspectorWindowController.shared.show(for: session) { sessionToResume in
            onLaunchTerminal(sessionToResume)
        }
    }

    @ViewBuilder
    private func contextMenuContent(for selectedIDs: Set<String>) -> some View {
        if selectedIDs.count == 1,
           let id = selectedIDs.first,
           let session = session(for: id) {
            Button("Resume in Codex CLI") {
                tableSelection = [id]
                selection = id
                onLaunchTerminal(session)
            }
            .help("Open this session in the Codex terminal if it supports resume. Some sessions lack enough data to relaunch.")
            Divider()
            Button("Open Working Directory") {
                tableSelection = [id]
                selection = id
                onOpenWorkingDirectory(session)
            }
            .help("Reveal the session's working directory in Finder")
            Button("Open Session in Folder") {
                tableSelection = [id]
                selection = id
                revealSession(session)
            }
            .help("Show the raw session log file in Finder")

            // Git Context Inspector (Codex only, feature-flagged)
            if isGitInspectorEnabled && session.source == .codex {
                Divider()
                Button("Show Git Context") {
                    tableSelection = [id]
                    selection = id
                    showGitInspector(session)
                }
                .help("Show historical and current git context with safety analysis")
            }

            if let name = session.repoName, !name.isEmpty {
                Divider()
                Button("Filter by Project: \(name)") {
                    indexer.projectFilter = name
                    indexer.recomputeNow()
                }
                .help("Apply a project filter using the session's repository name")
            } else {
                Divider()
                Button("Filter by Project") {}
                    .disabled(true)
                    .help("Project information is unavailable for this session")
            }
        } else {
            Button("Resume in Codex CLI") {}
                .disabled(true)
                .help("Select exactly one session to attempt a Codex resume")
            Button("Open Working Directory") {}
                .disabled(true)
                .help("Select a single session with a known working directory")
            Button("Open Session in Folder") {}
                .disabled(true)
                .help("Select one session to reveal its JSONL log in Finder")
            Button("Filter by Project") {}
                .disabled(true)
                .help("Select a session that has project metadata to filter by")
        }
    }
}

// (Column builder helpers removed to maintain compatibility with older macOS toolchains.)

// Helper for tooltip formatting
private func absoluteTime(_ date: Date?) -> String {
    guard let date else { return "" }
    return AppDateFormatting.dateTimeShort(date)
}

private func projectTooltip(for s: Session) -> String {
    var parts: [String] = []
    if let path = s.cwd { parts.append(path) }
    var badges: [String] = []
    if s.isWorktree { badges.append("worktree") }
    if s.isSubmodule { badges.append("submodule") }
    if !badges.isEmpty { parts.append("[" + badges.joined(separator: ", ") + "]") }
    return parts.joined(separator: " ")
}

private func messageDisplay(for s: Session) -> String {
    let count = s.messageCount
    if s.events.isEmpty {
        if let bytes = s.fileSizeBytes {
            return formattedSize(bytes)
        }
        return count >= 1000 ? formattedSizeEstimate(count) : "~\(count)"
    } else {
        // Fully parsed: show exact count
        return String(format: "%3d", count)
    }
}

private func revealSession(_ session: Session) {
    let path = session.filePath
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
    let target = isDir.boolValue ? url : url
    NSWorkspace.shared.activateFileViewerSelecting([target])
}

private func formattedSize(_ bytes: Int) -> String {
    let mb = Double(bytes) / 1_048_576.0
    if mb >= 10 {
        return "\(Int(round(mb)))MB"
    } else if mb >= 1 {
        return String(format: "%.1fMB", mb)
    }
    let kb = max(1, Int(round(Double(bytes) / 1024.0)))
    return "\(kb)KB"
}

private func formattedSizeEstimate(_ count: Int) -> String {
    // Fallback when file size is unavailable; keep legacy behavior for huge estimates
    if count >= 1000 {
        return "1000+"
    }
    return "~\(count)"
}
