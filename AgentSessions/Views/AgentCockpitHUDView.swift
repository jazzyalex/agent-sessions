import SwiftUI
import AppKit
import Combine

enum HUDLiveState: Equatable {
    case active
    case idle
}

struct HUDAgentBadgeStyle {
    let text: Color
    let background: Color
    let border: Color
}

enum HUDAgentType: Equatable {
    case codex
    case claude
    case shell

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .shell: return "Shell"
        }
    }

    func badgeStyle(for colorScheme: ColorScheme) -> HUDAgentBadgeStyle {
        if colorScheme == .dark {
            switch self {
            case .codex:
                return HUDAgentBadgeStyle(
                    text: Color(hex: "9e9cf8"),
                    background: Color(hex: "5e5ce6").opacity(0.18),
                    border: Color(hex: "5e5ce6").opacity(0.28)
                )
            case .claude:
                return HUDAgentBadgeStyle(
                    text: Color(hex: "ffb340"),
                    background: Color(hex: "ff9500").opacity(0.15),
                    border: Color(hex: "ff9500").opacity(0.25)
                )
            case .shell:
                return HUDAgentBadgeStyle(
                    text: Color(hex: "6e6e73"),
                    background: Color.white.opacity(0.07),
                    border: Color.white.opacity(0.12)
                )
            }
        }
        switch self {
        case .codex:
            return HUDAgentBadgeStyle(
                text: Color(hex: "5856d6"),
                background: Color(hex: "5e5ce6").opacity(0.09),
                border: Color(hex: "5e5ce6").opacity(0.16)
            )
        case .claude:
            return HUDAgentBadgeStyle(
                text: Color(hex: "c47700"),
                background: Color(hex: "ff9500").opacity(0.09),
                border: Color(hex: "ff9500").opacity(0.16)
            )
        case .shell:
            return HUDAgentBadgeStyle(
                text: Color(hex: "8e8e93"),
                background: Color.black.opacity(0.05),
                border: Color.black.opacity(0.10)
            )
        }
    }
}

struct HUDRow: Identifiable, Equatable {
    let id: String
    let source: SessionSource
    let agentType: HUDAgentType
    let projectName: String
    let displayName: String
    let liveState: HUDLiveState
    let preview: String
    let elapsed: String
    let lastSeenAt: Date?
    let itermSessionId: String?
    let revealURL: URL?
    let tty: String?
    let termProgram: String?
    let tabTitle: String?
    let resolvedSessionID: String?
    let runtimeSessionID: String?
    let logPath: String?
    let workingDirectory: String?
    let lastActivityAt: Date?
    let lastActivityTooltip: String?

    init(id: String,
         source: SessionSource,
         agentType: HUDAgentType,
         projectName: String,
         displayName: String,
         liveState: HUDLiveState,
         preview: String,
         elapsed: String,
         lastSeenAt: Date?,
         itermSessionId: String?,
         revealURL: URL?,
         tty: String?,
         termProgram: String?,
         tabTitle: String? = nil,
         resolvedSessionID: String? = nil,
         runtimeSessionID: String? = nil,
         logPath: String? = nil,
         workingDirectory: String? = nil,
         lastActivityAt: Date? = nil,
         lastActivityTooltip: String? = nil) {
        self.id = id
        self.source = source
        self.agentType = agentType
        self.projectName = projectName
        self.displayName = displayName
        self.liveState = liveState
        self.preview = preview
        self.elapsed = elapsed
        self.lastSeenAt = lastSeenAt
        self.itermSessionId = itermSessionId
        self.revealURL = revealURL
        self.tty = tty
        self.termProgram = termProgram
        self.tabTitle = tabTitle
        self.resolvedSessionID = resolvedSessionID
        self.runtimeSessionID = runtimeSessionID
        self.logPath = logPath
        self.workingDirectory = workingDirectory
        self.lastActivityAt = lastActivityAt
        self.lastActivityTooltip = lastActivityTooltip
    }
}

private enum AgentCockpitHUDTheme {
    static let cornerRadius: CGFloat = 12
    static let toolbarButtonCornerRadius: CGFloat = 7
}

enum HUDSessionFilterMode: Equatable {
    case all
    case active
    case idle
}

struct HUDGroup: Identifiable {
    let id: String
    let projectName: String
    let rows: [HUDRow]
    let activeCount: Int
    let idleCount: Int

    var hasActive: Bool { activeCount > 0 }

    var summaryText: String {
        if activeCount > 0 && idleCount > 0 {
            return "\(activeCount) active · \(idleCount) idle"
        }
        if activeCount > 0 {
            return "\(activeCount) active"
        }
        return "\(idleCount) idle"
    }
}

private struct LegacyMappedRow: Identifiable {
    let id: String
    let source: SessionSource
    let title: String
    let liveState: CodexLiveState
    let lastSeenAt: Date?
    let repo: String
    let date: Date?
    let focusURL: URL?
    let itermSessionId: String?
    let tty: String?
    let termProgram: String?
    let tabTitle: String?
    let resolvedSessionID: String?
    let sessionID: String?
    let logPath: String?
    let workingDirectory: String?
    let lastActivityAt: Date?
}

private struct SessionLookupIndexes {
    let byLogPath: [String: Session]
    let bySessionID: [String: Session]
    let byWorkspace: [String: Session]
}

private struct HUDRowsSnapshot {
    let rows: [HUDRow]
    let activeCount: Int
    let idleCount: Int
}

struct AgentCockpitHUDView: View {
    @ObservedObject var codexIndexer: SessionIndexer
    @ObservedObject var claudeIndexer: ClaudeSessionIndexer
    @EnvironmentObject var activeCodex: CodexActiveSessionsModel
    @Environment(\.openWindow) private var openWindow

    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var activeEnabled: Bool = true
    @AppStorage(PreferencesKey.Cockpit.hudGroupByProject) private var groupByProject: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudCompact) private var isCompact: Bool = false
    @AppStorage(PreferencesKey.Cockpit.hudPinned) private var isPinned: Bool = false

    @State private var sessionFilterMode: HUDSessionFilterMode = .all
    @State private var filterText: String = ""
    @State private var collapsedProjects: Set<String> = []
    @State private var activeConsumerID = UUID()
    @State private var searchFocusToken: Int = 0
    @FocusState private var isSearchFocused: Bool

    private static let codexRolloutTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    private static let activityTooltipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: hudContent.preferredColorScheme(.light)
            case .dark: hudContent.preferredColorScheme(.dark)
            case .system: hudContent
            }
        }
        .onAppear {
            activeCodex.setCockpitConsumerVisible(true, consumerID: activeConsumerID)
            UserDefaults.standard.set(true, forKey: PreferencesKey.Cockpit.hudOpen)
        }
        .onDisappear {
            activeCodex.setCockpitConsumerVisible(false, consumerID: activeConsumerID)
            UserDefaults.standard.set(false, forKey: PreferencesKey.Cockpit.hudOpen)
        }
    }

    private var hudContent: some View {
        let snapshot = makeRowsSnapshot()
        let rowsForDisplay = activeEnabled ? snapshot.rows : []
        let visibleRows = filteredRows(from: rowsForDisplay)
        let shownSessionCount = visibleRows.count
        let grouped = groupedRows(from: visibleRows)
        let renderedRows = renderedRows(visibleRows: visibleRows, groupedRows: grouped)
        let compactLayoutUnits = compactLayoutUnitCount(visibleRows: visibleRows, groupedRows: grouped)
        let compactBodyHeight = compactListHeight(forLayoutUnits: compactLayoutUnits)
        let rowIndexMap = renderedRows.enumerated().reduce(into: [String: Int]()) { partial, pair in
            let (index, row) = pair
            if partial[row.id] == nil {
                partial[row.id] = index + 1
            }
        }
        let compactCalloutHeight: CGFloat = !activeEnabled ? compactDisabledCalloutHeight : 0
        let compactContentHeight = isCompact
            ? compactContentHeight(forBodyHeight: compactBodyHeight, calloutHeight: compactCalloutHeight)
            : nil

        return VStack(spacing: 0) {
            header(activeCount: snapshot.activeCount, idleCount: snapshot.idleCount)
                .background(Color.primary.opacity(0.04))
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)

            if !activeEnabled {
                disabledCallout
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            bodyList(
                visibleRows: visibleRows,
                groupedRows: grouped,
                rowIndexMap: rowIndexMap,
                compactBodyHeight: compactBodyHeight
            )
            .background(Color.clear)
            .disabled(!activeEnabled)

            hiddenShortcuts(renderedRows: renderedRows)
        }
        .background(.ultraThinMaterial)
        .background(
            AgentCockpitHUDWindowConfigurator(
                isPinned: isPinned,
                shownSessionCount: shownSessionCount,
                isCompact: isCompact,
                compactContentHeight: compactContentHeight
            )
            .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: AgentCockpitHUDTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AgentCockpitHUDTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.18), value: isCompact)
        .applyIf(isCompact) { view in
            view.ignoresSafeArea(.container, edges: .top)
        }
    }

    @ViewBuilder
    private func header(activeCount: Int, idleCount: Int) -> some View {
        VStack(spacing: isCompact ? 0 : 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Button {
                        guard activeEnabled else { return }
                        sessionFilterMode = .all
                    } label: {
                        Text("All \(activeCount + idleCount)")
                    }
                    .buttonStyle(HUDFilterPillStyle(isOn: sessionFilterMode == .all, kind: .all))
                    .help("Show all live sessions.")

                    Button {
                        guard activeEnabled else { return }
                        sessionFilterMode = .active
                    } label: {
                        Text("Active \(activeCount)")
                    }
                    .buttonStyle(HUDFilterPillStyle(isOn: sessionFilterMode == .active, kind: .active))
                    .help("Show active working sessions only.")

                    Button {
                        guard activeEnabled else { return }
                        sessionFilterMode = .idle
                    } label: {
                        Text("Idle \(idleCount)")
                    }
                    .buttonStyle(HUDFilterPillStyle(isOn: sessionFilterMode == .idle, kind: .idle))
                    .help("Show idle sessions only.")
                }
                .disabled(!activeEnabled)
                .opacity(activeEnabled ? 1 : 0.6)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Button {
                        isPinned.toggle()
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(HUDIconButtonStyle(isOn: isPinned, tint: isPinned ? .orange : nil))
                    .help(isPinned ? "Unpin — stop keeping on top" : "Pin — keep above all windows")

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isCompact.toggle()
                        }
                    } label: {
                        Image(systemName: isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(HUDIconButtonStyle(isOn: isCompact, tint: nil))
                    .help(isCompact ? "Show filter and navigation" : "Compact mode")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, isCompact ? 10 : 0)

            if !isCompact {
                HStack(spacing: 8) {
                    HUDSearchField(
                        text: $filterText,
                        placeholder: "Filter sessions...",
                        focusToken: searchFocusToken
                    )
                    .disabled(!activeEnabled)
                    .focused($isSearchFocused)
                    .onExitCommand {
                        guard activeEnabled else { return }
                        if !filterText.isEmpty {
                            filterText = ""
                        }
                        isSearchFocused = false
                    }

                    Button {
                        guard activeEnabled else { return }
                        groupByProject.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.grid.2x2")
                            Text("By Project")
                        }
                    }
                    .buttonStyle(HUDIconButtonStyle(isOn: groupByProject, tint: .accentColor))
                    .help("Group sessions by project.")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func bodyList(visibleRows: [HUDRow],
                          groupedRows: [HUDGroup],
                          rowIndexMap: [String: Int],
                          compactBodyHeight: CGFloat) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if groupByProject {
                    ForEach(groupedRows) { group in
                        AgentCockpitHUDGroupHeader(
                            projectName: group.projectName,
                            activeCount: group.activeCount,
                            idleCount: group.idleCount,
                            isCollapsed: collapsedProjects.contains(group.id)
                        ) {
                            toggleCollapsed(projectID: group.id)
                        }

                        if !collapsedProjects.contains(group.id) {
                            ForEach(group.rows) { row in
                                AgentCockpitHUDRowView(
                                    row: row,
                                    rowNumber: rowIndexMap[row.id] ?? 0,
                                    isSelected: false,
                                    filterText: filterText,
                                    isGrouped: true,
                                    isCompact: isCompact
                                ) {
                                    focus(row)
                                }
                                .contextMenu {
                                    rowContextMenu(row)
                                }
                            }
                        }
                    }
                } else {
                    ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                        AgentCockpitHUDRowView(
                            row: row,
                            rowNumber: index + 1,
                            isSelected: false,
                            filterText: filterText,
                            isGrouped: false,
                            isCompact: isCompact
                        ) {
                            focus(row)
                        }
                        .contextMenu {
                            rowContextMenu(row)
                        }
                    }
                }
            }
            .padding(.vertical, isCompact ? 0 : 2)
            .background(
                CockpitScrollViewScrollerConfigurator(alwaysVisible: !isCompact)
                    .allowsHitTesting(false)
            )
        }
        .scrollIndicators(isCompact ? .hidden : .visible)
        .frame(
            minHeight: isCompact ? compactBodyHeight : 170
        )
    }

    private func compactWindowVisibleSessionCount(from shownSessionCount: Int) -> Int {
        min(max(shownSessionCount, 1), 8)
    }

    private func compactLayoutUnitCount(visibleRows: [HUDRow], groupedRows: [HUDGroup]) -> Int {
        if groupByProject {
            var remainingSessions = compactWindowVisibleSessionCount(
                from: renderedRows(visibleRows: visibleRows, groupedRows: groupedRows).count
            )
            var units = 0
            var emittedAnySession = false

            for group in groupedRows {
                units += 1 // group header
                guard !collapsedProjects.contains(group.id) else { continue }
                guard remainingSessions > 0 else { break }

                let take = min(group.rows.count, remainingSessions)
                units += take
                remainingSessions -= take
                if take > 0 { emittedAnySession = true }

                if remainingSessions == 0 { break }
            }

            return max(units, emittedAnySession ? 1 : 2)
        }

        let visibleSessionCount = compactWindowVisibleSessionCount(from: visibleRows.count)
        return max(visibleSessionCount, 1)
    }

    private func compactListHeight(forLayoutUnits layoutUnits: Int) -> CGFloat {
        let unitHeight: CGFloat = 31
        let verticalInsets: CGFloat = isCompact ? 0 : 4
        // Grouped compact mode needs extra bottom breathing room so the last row
        // does not appear clipped against the rounded window edge.
        let groupedBottomInset: CGFloat = groupByProject ? 10 : 0
        return (CGFloat(layoutUnits) * unitHeight) + verticalInsets + groupedBottomInset
    }

    private func compactContentHeight(forBodyHeight bodyHeight: CGFloat, calloutHeight: CGFloat) -> CGFloat {
        let compactHeaderHeight: CGFloat = 44
        let headerDividerHeight: CGFloat = 0.5
        return compactHeaderHeight + headerDividerHeight + calloutHeight + bodyHeight
    }

    private var compactDisabledCalloutHeight: CGFloat { 56 }

    @ViewBuilder
    private func hiddenShortcuts(renderedRows: [HUDRow]) -> some View {
        VStack(spacing: 0) {
            Button("") {
                guard activeEnabled else { return }
                focusSearchField(selectAll: true)
            }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)

            Button("") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isCompact.toggle()
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .opacity(0)

            ForEach(1...9, id: \.self) { n in
                Button("") {
                    guard activeEnabled else { return }
                    guard renderedRows.indices.contains(n - 1) else { return }
                    let row = renderedRows[n - 1]
                    focus(row)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            }

            Button("") {
                guard activeEnabled else { return }
                guard renderedRows.indices.contains(9) else { return }
                focus(renderedRows[9])
            }
            .keyboardShortcut("0", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    private func renderedRows(visibleRows: [HUDRow], groupedRows: [HUDGroup]) -> [HUDRow] {
        guard groupByProject else { return visibleRows }
        return groupedRows.flatMap { group in
            collapsedProjects.contains(group.id) ? [] : group.rows
        }
    }

    private func toggleCollapsed(projectID: String) {
        if collapsedProjects.contains(projectID) {
            collapsedProjects.remove(projectID)
        } else {
            collapsedProjects.insert(projectID)
        }
    }

    private func filteredRows(from rows: [HUDRow]) -> [HUDRow] {
        Self.filteredRows(rows, mode: sessionFilterMode, query: filterText)
    }

    private func groupedRows(from rows: [HUDRow]) -> [HUDGroup] {
        Self.groupedRows(rows)
    }

    private func focusSearchField(selectAll: Bool) {
        isSearchFocused = true
        if selectAll {
            searchFocusToken &+= 1
        }
    }

    private func focus(_ row: HUDRow) {
        guard activeEnabled else { return }
        if CodexActiveSessionsModel.tryFocusITerm2(itermSessionId: row.itermSessionId, tty: row.tty) {
            return
        }
        if let url = row.revealURL {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ row: HUDRow) -> some View {
        Button("Go to Session") {
            goToSession(row)
        }
        .disabled(!activeEnabled || row.resolvedSessionID == nil)
        .help("Select this session in the main Agent Sessions window and open its transcript.")

        Button("Focus in iTerm2") {
            focus(row)
        }
        .disabled(!activeEnabled || !canFocus(row))
        .help("Focus the existing iTerm2 tab/window for this session.")

        Divider()

        Button("Reveal Log") {
            revealLog(row)
        }
        .disabled(!activeEnabled || row.logPath == nil)
        .help("Reveal the session log in Finder.")

        Button("Open Working Directory") {
            openWorkingDirectory(row)
        }
        .disabled(!activeEnabled || row.workingDirectory == nil)
        .help("Open the working directory in Finder.")

        Divider()

        Button("Copy Session ID") {
            copyToPasteboard(row.runtimeSessionID ?? row.resolvedSessionID)
        }
        .disabled((row.runtimeSessionID ?? row.resolvedSessionID) == nil)

        Button("Copy Tab Title") {
            copyToPasteboard(normalizedTabTitle(row))
        }
        .disabled(normalizedTabTitle(row) == nil)

        Button("Copy Working Directory Path") {
            copyToPasteboard(row.workingDirectory)
        }
        .disabled(row.workingDirectory == nil)
    }

    private func canFocus(_ row: HUDRow) -> Bool {
        CodexActiveSessionsModel.canAttemptITerm2Focus(
            itermSessionId: row.itermSessionId,
            tty: row.tty,
            termProgram: row.termProgram
        ) || row.revealURL != nil
    }

    private func goToSession(_ row: HUDRow) {
        guard activeEnabled else { return }
        guard let resolvedSessionID = row.resolvedSessionID else {
            NSSound.beep()
            return
        }
        let pendingRequest = PendingCockpitNavigationRequest(
            unifiedSessionID: resolvedSessionID,
            sourceRawValue: row.source.rawValue,
            runtimeSessionID: row.runtimeSessionID,
            logPath: row.logPath,
            workingDirectory: row.workingDirectory,
            createdAt: Date()
        )
        CockpitNavigationBridge.store(pendingRequest)

        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "Agent Sessions")

        var payload: [AnyHashable: Any] = ["source": row.source.rawValue]
        if let runtimeSessionID = row.runtimeSessionID, !runtimeSessionID.isEmpty {
            payload["runtimeSessionID"] = runtimeSessionID
        }
        if let logPath = row.logPath, !logPath.isEmpty {
            payload["logPath"] = logPath
        }
        if let workingDirectory = row.workingDirectory, !workingDirectory.isEmpty {
            payload["workingDirectory"] = workingDirectory
        }
        postGoToSessionNotification(
            unifiedSessionID: resolvedSessionID,
            payload: payload,
            attempt: 0
        )
    }

    private func postGoToSessionNotification(unifiedSessionID: String,
                                             payload: [AnyHashable: Any],
                                             attempt: Int) {
        NotificationCenter.default.post(
            name: .navigateToSessionFromCockpit,
            object: unifiedSessionID,
            userInfo: payload
        )

        guard attempt < 8 else { return }
        guard CockpitNavigationBridge.hasPending(unifiedSessionID: unifiedSessionID) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            postGoToSessionNotification(
                unifiedSessionID: unifiedSessionID,
                payload: payload,
                attempt: attempt + 1
            )
        }
    }

    private func revealLog(_ row: HUDRow) {
        guard let path = row.logPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func openWorkingDirectory(_ row: HUDRow) {
        guard let path = row.workingDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
    }

    private func normalizedTabTitle(_ row: HUDRow) -> String? {
        guard let tabTitle = row.tabTitle else { return nil }
        let trimmed = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var disabledCallout: some View {
        PreferenceCallout {
            Text("Live sessions + Cockpit (Beta) is disabled in Settings → Agent Cockpit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func makeRowsSnapshot() -> HUDRowsSnapshot {
        let lookupIndexes = buildSessionLookupIndexes()
        let supportedSources: Set<SessionSource> = [.codex, .claude]
        let allSessions = codexIndexer.allSessions + claudeIndexer.allSessions
        let fallbackBySessionKey = UnifiedSessionsView.buildFallbackPresenceMap(
            sessions: allSessions,
            presences: activeCodex.presences
        ) { candidate in
            activeCodex.presence(for: candidate) != nil
        }

        var fallbackSessionByPresenceKey: [String: Session] = [:]
        fallbackSessionByPresenceKey.reserveCapacity(fallbackBySessionKey.count)

        for session in allSessions {
            let sessionKey = UnifiedSessionsView.fallbackPresenceKey(source: session.source, sessionID: session.id)
            guard let presence = fallbackBySessionKey[sessionKey] else { continue }
            let presenceKey = CodexActiveSessionsModel.presenceKey(for: presence)
            guard presenceKey != "unknown" else { continue }
            fallbackSessionByPresenceKey[presenceKey] = preferredSession(
                existing: fallbackSessionByPresenceKey[presenceKey],
                incoming: session
            )
        }

        let mappedRows: [LegacyMappedRow] = activeCodex.presences.compactMap { presence in
            guard supportedSources.contains(presence.source) else { return nil }
            let logNorm = presence.sessionLogPath.map(CodexActiveSessionsModel.normalizePath)
            let presenceKey = CodexActiveSessionsModel.presenceKey(for: presence)

            let session = logNorm.flatMap { normalized in
                lookupIndexes.byLogPath[CodexActiveSessionsModel.logLookupKey(source: presence.source, normalizedPath: normalized)]
            } ?? resolveBySessionID(presence.sessionId, source: presence.source, lookupIndexes: lookupIndexes)
                ?? fallbackSessionByPresenceKey[presenceKey]

            if shouldHideUnresolvedPresencePlaceholder(presence, resolvedSession: session, lookupIndexes: lookupIndexes) {
                return nil
            }

            let title = session?.title
                ?? presence.sessionId.map { "Session \($0.prefix(8))" }
                ?? "Active \(presence.source.displayName) session"

            let repo = session?.repoName ?? session?.repoDisplay ?? "—"
            let date = session?.modifiedAt ?? parseSessionTimestamp(from: presence)
            let lastActivityAt = activeCodex.lastActivityAt(for: presence) ?? date
            let liveState = activeCodex.liveState(for: presence)

            let stableID: String =
                "\(presence.source.rawValue)|" + (logNorm
                ?? presence.sessionId
                ?? presence.sourceFilePath
                ?? presence.pid.map { "pid:\($0)" }
                ?? presence.tty
                ?? "\(presence.sessionLogPath ?? "unknown")|\(presence.pid ?? -1)")

            return LegacyMappedRow(
                id: stableID,
                source: presence.source,
                title: title,
                liveState: liveState,
                lastSeenAt: presence.lastSeenAt,
                repo: repo,
                date: date,
                focusURL: presence.revealURL,
                itermSessionId: presence.terminal?.itermSessionId,
                tty: presence.tty,
                termProgram: presence.terminal?.termProgram,
                tabTitle: presence.terminal?.tabTitle,
                resolvedSessionID: session?.id,
                sessionID: authoritativeSessionID(for: presence, resolvedSession: session),
                logPath: presence.sessionLogPath,
                workingDirectory: session?.cwd ?? presence.workspaceRoot,
                lastActivityAt: lastActivityAt
            )
        }

        let deduped = dedupeRowsByResolvedSession(mappedRows)

        let sorted = deduped.sorted { a, b in
            let aState = Self.mapLiveStateForHUD(a.liveState)
            let bState = Self.mapLiveStateForHUD(b.liveState)
            if aState != bState {
                return aState == .active
            }
            let da = a.lastActivityAt ?? .distantPast
            let db = b.lastActivityAt ?? .distantPast
            if da != db { return da > db }
            if a.repo != b.repo { return a.repo.localizedCaseInsensitiveCompare(b.repo) == .orderedAscending }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        let hudRows = sorted.map { row in
            let hudState = Self.mapLiveStateForHUD(row.liveState)
            let elapsed = isCompact ? "" : elapsedLabel(from: row.lastActivityAt)
            let activityTooltip = row.lastActivityAt.map { Self.activityTooltipFormatter.string(from: $0) }
            return HUDRow(
                id: row.id,
                source: row.source,
                agentType: mapAgentType(row.source),
                projectName: row.repo,
                displayName: row.title,
                liveState: hudState,
                preview: row.title,
                elapsed: elapsed,
                lastSeenAt: row.lastSeenAt,
                itermSessionId: row.itermSessionId,
                revealURL: row.focusURL,
                tty: row.tty,
                termProgram: row.termProgram,
                tabTitle: row.tabTitle,
                resolvedSessionID: row.resolvedSessionID,
                runtimeSessionID: row.sessionID,
                logPath: row.logPath,
                workingDirectory: row.workingDirectory,
                lastActivityAt: row.lastActivityAt,
                lastActivityTooltip: activityTooltip
            )
        }

        let counts = Self.counts(for: hudRows)
        return HUDRowsSnapshot(rows: hudRows, activeCount: counts.active, idleCount: counts.idle)
    }

    private func elapsedLabel(from date: Date?) -> String {
        guard let date else { return "—" }
        let delta = max(Int(Date().timeIntervalSince(date)), 0)
        if delta < 60 { return "\(delta)s" }
        if delta < 3600 { return "\(delta / 60)m" }
        if delta < 86400 { return "\(delta / 3600)h" }
        return "\(delta / 86400)d"
    }

    static func mapLiveStateForHUD(_ liveState: CodexLiveState) -> HUDLiveState {
        liveState == .activeWorking ? .active : .idle
    }

    static func counts(for rows: [HUDRow]) -> (active: Int, idle: Int) {
        let active = rows.reduce(into: 0) { partial, row in
            if row.liveState == .active { partial += 1 }
        }
        return (active: active, idle: rows.count - active)
    }

    static func filteredRows(_ rows: [HUDRow], mode: HUDSessionFilterMode, query: String) -> [HUDRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            let statePass: Bool = {
                switch mode {
                case .all:
                    return true
                case .active:
                    return row.liveState == .active
                case .idle:
                    return row.liveState == .idle
                }
            }()
            guard statePass else { return false }
            guard !trimmed.isEmpty else { return true }
            let lowered = trimmed.lowercased()
            return row.projectName.lowercased().contains(lowered)
                || row.displayName.lowercased().contains(lowered)
                || row.preview.lowercased().contains(lowered)
        }
    }

    static func groupedRows(_ rows: [HUDRow]) -> [HUDGroup] {
        var buckets: [String: [HUDRow]] = [:]
        buckets.reserveCapacity(rows.count)

        for row in rows {
            buckets[row.projectName, default: []].append(row)
        }

        var out: [HUDGroup] = buckets.map { projectName, projectRows in
            let counts = counts(for: projectRows)
            return HUDGroup(
                id: projectName,
                projectName: projectName,
                rows: projectRows,
                activeCount: counts.active,
                idleCount: counts.idle
            )
        }

        out.sort { a, b in
            if a.hasActive != b.hasActive {
                return a.hasActive && !b.hasActive
            }
            return a.projectName.localizedCaseInsensitiveCompare(b.projectName) == .orderedAscending
        }

        return out
    }

    private func mapAgentType(_ source: SessionSource) -> HUDAgentType {
        switch source {
        case .codex:
            return .codex
        case .claude:
            return .claude
        default:
            return .shell
        }
    }

    private func authoritativeSessionID(for presence: CodexActivePresence, resolvedSession: Session?) -> String? {
        if let sessionID = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            return sessionID
        }
        guard let resolvedSession else { return nil }
        return CodexActiveSessionsModel.liveSessionIDCandidates(for: resolvedSession).first
    }

    private func resolveBySessionID(_ id: String?, source: SessionSource, lookupIndexes: SessionLookupIndexes) -> Session? {
        guard let id, !id.isEmpty else { return nil }
        let key = CodexActiveSessionsModel.sessionLookupKey(source: source, sessionId: id)
        return lookupIndexes.bySessionID[key]
    }

    private func shouldHideUnresolvedPresencePlaceholder(_ presence: CodexActivePresence,
                                                         resolvedSession: Session?,
                                                         lookupIndexes: SessionLookupIndexes) -> Bool {
        let hasWorkspaceMatch: Bool = {
            guard let workspaceRoot = presence.workspaceRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !workspaceRoot.isEmpty else {
                return false
            }
            let workspaceKey = workspaceLookupKey(
                source: presence.source,
                normalizedPath: CodexActiveSessionsModel.normalizePath(workspaceRoot)
            )
            return lookupIndexes.byWorkspace[workspaceKey] != nil
        }()
        return Self.shouldHideUnresolvedPresencePlaceholder(
            presence,
            resolvedSession: resolvedSession,
            hasWorkspaceMatch: hasWorkspaceMatch
        )
    }

    static func shouldHideUnresolvedPresencePlaceholder(_ presence: CodexActivePresence,
                                                        resolvedSession: Session?,
                                                        hasWorkspaceMatch: Bool) -> Bool {
        guard resolvedSession == nil else { return false }
        let kind = presence.kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if kind == "subagent" { return true }

        if presence.source == .codex { return true }

        let hasSessionID = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLogPath = presence.sessionLogPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasSessionID || hasLogPath { return false }

        let hasRevealURL = presence.revealURL != nil
        let hasITermGuid = CodexActiveSessionsModel.itermSessionGuid(from: presence.terminal?.itermSessionId)?.isEmpty == false
        let termProgram = presence.terminal?.termProgram?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let reportsITermProgram = termProgram.contains("iterm")
        let canFocusFallbackStrict = hasRevealURL || hasITermGuid || reportsITermProgram

        if canFocusFallbackStrict { return false }
        if hasWorkspaceMatch { return false }
        return true
    }

    private func dedupeRowsByResolvedSession(_ rows: [LegacyMappedRow]) -> [LegacyMappedRow] {
        var byKey: [String: LegacyMappedRow] = [:]
        byKey.reserveCapacity(rows.count)

        for row in rows {
            let key: String = {
                if let id = row.sessionID, !id.isEmpty {
                    return "\(row.source.rawValue)|sid:\(id)"
                }
                if let path = row.logPath {
                    return CodexActiveSessionsModel.logLookupKey(
                        source: row.source,
                        normalizedPath: CodexActiveSessionsModel.normalizePath(path)
                    )
                }
                if let tty = normalizeTTY(row.tty) {
                    return "\(row.source.rawValue)|tty:\(tty)"
                }
                if let workspace = normalizedWorkingDirectory(row.workingDirectory), !workspace.isEmpty {
                    return workspaceLookupKey(source: row.source, normalizedPath: workspace)
                }
                if let itermSessionId = row.itermSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !itermSessionId.isEmpty {
                    return "\(row.source.rawValue)|iterm:\(itermSessionId)"
                }
                return row.id
            }()
            let existing = byKey[key]
            byKey[key] = preferredRow(existing: existing, incoming: row)
        }

        return Array(byKey.values)
    }

    private func preferredRow(existing: LegacyMappedRow?, incoming: LegacyMappedRow) -> LegacyMappedRow {
        guard let existing else { return incoming }
        let winner: LegacyMappedRow
        let loser: LegacyMappedRow
        let existingHasDate = existing.date != nil
        let incomingHasDate = incoming.date != nil
        if existingHasDate != incomingHasDate {
            winner = incomingHasDate ? incoming : existing
            loser = incomingHasDate ? existing : incoming
            return mergeMetadata(into: winner, from: loser)
        }
        let existingSeen = existing.lastSeenAt ?? .distantPast
        let incomingSeen = incoming.lastSeenAt ?? .distantPast
        if incomingSeen != existingSeen {
            winner = incomingSeen > existingSeen ? incoming : existing
            loser = incomingSeen > existingSeen ? existing : incoming
            return mergeMetadata(into: winner, from: loser)
        }
        let existingHasJoin = (existing.sessionID?.isEmpty == false) || existing.logPath != nil
        let incomingHasJoin = (incoming.sessionID?.isEmpty == false) || incoming.logPath != nil
        if existingHasJoin != incomingHasJoin {
            winner = incomingHasJoin ? incoming : existing
            loser = incomingHasJoin ? existing : incoming
            return mergeMetadata(into: winner, from: loser)
        }
        if existing.liveState != incoming.liveState {
            let existingCanProbe = rowCanTailProbe(existing)
            let incomingCanProbe = rowCanTailProbe(incoming)
            if existingCanProbe != incomingCanProbe {
                winner = incomingCanProbe ? incoming : existing
                loser = incomingCanProbe ? existing : incoming
                return mergeMetadata(into: winner, from: loser)
            }
            if existing.liveState == .activeWorking, incoming.liveState == .openIdle {
                return mergeMetadata(into: incoming, from: existing)
            }
            return mergeMetadata(into: existing, from: incoming)
        }
        if incoming.title.count > existing.title.count {
            return mergeMetadata(into: incoming, from: existing)
        }
        return mergeMetadata(into: existing, from: incoming)
    }

    private func mergeMetadata(into winner: LegacyMappedRow, from loser: LegacyMappedRow) -> LegacyMappedRow {
        LegacyMappedRow(
            id: winner.id,
            source: winner.source,
            title: winner.title,
            liveState: winner.liveState,
            lastSeenAt: winner.lastSeenAt ?? loser.lastSeenAt,
            repo: winner.repo,
            date: winner.date ?? loser.date,
            focusURL: winner.focusURL ?? loser.focusURL,
            itermSessionId: winner.itermSessionId ?? loser.itermSessionId,
            tty: winner.tty ?? loser.tty,
            termProgram: winner.termProgram ?? loser.termProgram,
            tabTitle: winner.tabTitle ?? loser.tabTitle,
            resolvedSessionID: winner.resolvedSessionID ?? loser.resolvedSessionID,
            sessionID: winner.sessionID ?? loser.sessionID,
            logPath: winner.logPath ?? loser.logPath,
            workingDirectory: winner.workingDirectory ?? loser.workingDirectory,
            lastActivityAt: winner.lastActivityAt ?? loser.lastActivityAt
        )
    }

    private func rowCanTailProbe(_ row: LegacyMappedRow) -> Bool {
        CodexActiveSessionsModel.canAttemptITerm2TailProbe(
            itermSessionId: row.itermSessionId,
            tty: row.tty,
            termProgram: row.termProgram
        )
    }

    private func parseSessionTimestamp(from presence: CodexActivePresence) -> Date? {
        guard let path = presence.sessionLogPath else { return nil }
        if presence.source != .codex {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attrs[.modificationDate] as? Date {
                return date
            }
            return nil
        }

        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard filename.hasPrefix("rollout-") else { return nil }
        guard let tRange = filename.range(of: #"rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-"#,
                                          options: .regularExpression) else {
            return nil
        }

        let match = String(filename[tRange])
        let ts = match
            .replacingOccurrences(of: "rollout-", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return Self.codexRolloutTimestampFormatter.date(from: ts)
    }

    private func buildSessionLookupIndexes() -> SessionLookupIndexes {
        let supportedSources: Set<SessionSource> = [.codex, .claude]
        let allSessions = codexIndexer.allSessions + claudeIndexer.allSessions

        var byLogPath: [String: Session] = [:]
        var bySessionID: [String: Session] = [:]
        var byWorkspace: [String: Session] = [:]
        byLogPath.reserveCapacity(allSessions.count)
        bySessionID.reserveCapacity(allSessions.count * 2)
        byWorkspace.reserveCapacity(allSessions.count)

        for session in allSessions where supportedSources.contains(session.source) {
            let logKey = CodexActiveSessionsModel.logLookupKey(
                source: session.source,
                normalizedPath: CodexActiveSessionsModel.normalizePath(session.filePath)
            )
            byLogPath[logKey] = preferredSession(existing: byLogPath[logKey], incoming: session)

            for runtimeID in CodexActiveSessionsModel.liveSessionIDCandidates(for: session) {
                let sid = runtimeID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sid.isEmpty else { continue }
                let sessionKey = CodexActiveSessionsModel.sessionLookupKey(source: session.source, sessionId: sid)
                bySessionID[sessionKey] = preferredSession(existing: bySessionID[sessionKey], incoming: session)
            }

            if let cwd = normalizedWorkingDirectory(session.cwd), !cwd.isEmpty {
                let workspaceKey = workspaceLookupKey(source: session.source, normalizedPath: cwd)
                byWorkspace[workspaceKey] = preferredSession(existing: byWorkspace[workspaceKey], incoming: session)
            }
        }

        return SessionLookupIndexes(byLogPath: byLogPath, bySessionID: bySessionID, byWorkspace: byWorkspace)
    }

    private func preferredSession(existing: Session?, incoming: Session) -> Session {
        guard let existing else { return incoming }
        if incoming.modifiedAt != existing.modifiedAt {
            return incoming.modifiedAt > existing.modifiedAt ? incoming : existing
        }
        let incomingStart = incoming.startTime ?? .distantPast
        let existingStart = existing.startTime ?? .distantPast
        if incomingStart != existingStart {
            return incomingStart > existingStart ? incoming : existing
        }
        if incoming.filePath != existing.filePath {
            return incoming.filePath < existing.filePath ? incoming : existing
        }
        return incoming.id < existing.id ? incoming : existing
    }

    private func normalizedWorkingDirectory(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = CodexActiveSessionsModel.normalizePath(raw)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizeTTY(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/dev/") {
            return trimmed
        }
        return "/dev/\(trimmed)"
    }

    private func workspaceLookupKey(source: SessionSource, normalizedPath: String) -> String {
        "\(source.rawValue)|cwd:\(normalizedPath)"
    }
}

private struct CockpitScrollViewScrollerConfigurator: NSViewRepresentable {
    let alwaysVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            context.coordinator.attachIfNeeded(to: nsView)
            context.coordinator.apply(alwaysVisible: alwaysVisible)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restoreBaseline()
    }

    final class Coordinator {
        private weak var scrollView: NSScrollView?
        private var baselineAutohides: Bool?
        private var baselineScrollerStyle: NSScroller.Style?

        func attachIfNeeded(to view: NSView?) {
            guard let candidate = enclosingScrollView(from: view) else { return }
            guard scrollView !== candidate else { return }
            scrollView = candidate
            baselineAutohides = candidate.autohidesScrollers
            baselineScrollerStyle = candidate.scrollerStyle
        }

        func apply(alwaysVisible: Bool) {
            guard let scrollView else { return }
            scrollView.hasVerticalScroller = true
            if alwaysVisible {
                scrollView.autohidesScrollers = false
                scrollView.scrollerStyle = .legacy
            } else {
                if let baselineAutohides {
                    scrollView.autohidesScrollers = baselineAutohides
                }
                if let baselineScrollerStyle {
                    scrollView.scrollerStyle = baselineScrollerStyle
                }
            }
        }

        func restoreBaseline() {
            apply(alwaysVisible: false)
            scrollView = nil
            baselineAutohides = nil
            baselineScrollerStyle = nil
        }

        private func enclosingScrollView(from view: NSView?) -> NSScrollView? {
            var current = view
            while let node = current {
                if let scrollView = node as? NSScrollView {
                    return scrollView
                }
                if let enclosing = node.enclosingScrollView {
                    return enclosing
                }
                current = node.superview
            }
            return nil
        }

        deinit {
            restoreBaseline()
        }
    }
}

private struct HUDIconButtonStyle: ButtonStyle {
    let isOn: Bool
    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(background.opacity(configuration.isPressed ? 0.85 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: AgentCockpitHUDTheme.toolbarButtonCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AgentCockpitHUDTheme.toolbarButtonCornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
    }

    private var foreground: Color {
        if let tint, isOn {
            return tint
        }
        return isOn ? .accentColor : .secondary
    }

    private var background: Color {
        if let tint, isOn {
            return tint.opacity(0.12)
        }
        return isOn ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04)
    }

    private var border: Color {
        if let tint, isOn {
            return tint.opacity(0.30)
        }
        return isOn ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.08)
    }
}

private enum HUDFilterPillKind {
    case all
    case active
    case idle
}

private struct HUDFilterPillStyle: ButtonStyle {
    let isOn: Bool
    let kind: HUDFilterPillKind
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(background.opacity(configuration.isPressed ? 0.85 : 1.0))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(border, lineWidth: 0.5)
            )
            .opacity(isOn ? 1.0 : 0.72)
    }

    private var foreground: Color {
        guard isOn else { return .secondary }
        switch kind {
        case .all:
            return .primary
        case .active:
            return Color(hex: "30d158")
        case .idle:
            return idleColor
        }
    }

    private var background: Color {
        guard isOn else { return Color.primary.opacity(0.04) }
        switch kind {
        case .all:
            return Color.primary.opacity(0.10)
        case .active:
            return Color(hex: "30d158").opacity(0.16)
        case .idle:
            return idleColor.opacity(0.16)
        }
    }

    private var border: Color {
        guard isOn else { return Color.primary.opacity(0.10) }
        switch kind {
        case .all:
            return Color.primary.opacity(0.18)
        case .active:
            return Color(hex: "30d158").opacity(0.35)
        case .idle:
            return idleColor.opacity(0.35)
        }
    }

    private var idleColor: Color {
        colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
    }
}

private struct HUDSearchField: View {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            HUDSearchTextField(
                text: $text,
                placeholder: placeholder,
                focusToken: focusToken
            )
            .frame(minHeight: 18)

            if !text.isEmpty {
                Text("esc")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Text("⌘K")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
}

private struct HUDSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.placeholderString = placeholder
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        tf.delegate = context.coordinator
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.stringValue != text {
            tf.stringValue = text
        }
        if tf.placeholderString != placeholder {
            tf.placeholderString = placeholder
        }
        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = tf.window else { return }
                window.makeFirstResponder(tf)
                tf.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HUDSearchTextField
        var lastFocusToken: Int = 0

        init(parent: HUDSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            if parent.text != tf.stringValue {
                parent.text = tf.stringValue
            }
        }
    }
}

#Preview("Agent Cockpit HUD") {
    AgentCockpitHUDView(
        codexIndexer: SessionIndexer(),
        claudeIndexer: ClaudeSessionIndexer()
    )
    .environmentObject(CodexActiveSessionsModel())
    .frame(width: 760, height: 420)
}
