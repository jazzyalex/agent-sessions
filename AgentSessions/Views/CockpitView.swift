import SwiftUI
import AppKit

private enum CockpitStyle {
    static let selectionAccent = Color(hex: "007acc")
    static let rowHeight: CGFloat = 28
    static let defaultVisibleRows: CGFloat = 8
    static let defaultTableMinHeight: CGFloat = (rowHeight * defaultVisibleRows) + 2
    static let defaultWindowMinHeight: CGFloat = defaultTableMinHeight + 84
}

struct CockpitView: View {
    @ObservedObject var codexIndexer: SessionIndexer
    @ObservedObject var claudeIndexer: ClaudeSessionIndexer
    @ObservedObject var opencodeIndexer: OpenCodeSessionIndexer
    @EnvironmentObject var activeCodex: CodexActiveSessionsModel
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var activeEnabled: Bool = true
    @AppStorage private var liveFilterModeRaw: String
    @State private var selection: Set<String> = []
    @State private var activeConsumerID = UUID()
    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    private static let codexRolloutTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    private enum LiveFilterMode: String, CaseIterable, Identifiable {
        case active
        case live

        var id: String { rawValue }

        var title: String {
            switch self {
            case .active: return "Active"
            case .live: return "Live"
            }
        }
    }

    private var effectiveColorScheme: ColorScheme {
        let current = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        return current.effectiveColorScheme(systemScheme: systemColorScheme)
    }

    private struct Row: Identifiable {
        let id: String
        let source: SessionSource
        let title: String
        let liveState: CodexLiveState
        let lastSeenAt: Date?
        let repo: String
        let date: Date?
        let dateLabel: String
        let terminal: String
        let termProgram: String?
        let focusURL: URL?
        let itermSessionId: String?
        let tty: String?
        let focusHelp: String
        let sessionID: String?
        let logPath: String?
        let workingDirectory: String?
    }

    private struct SessionLookupIndexes {
        let byLogPath: [String: Session]
        let bySessionID: [String: Session]
        let byWorkspace: [String: Session]
    }

    private struct LiveRowsSnapshot {
        let filteredRows: [Row]
        let activeCount: Int
        let idleCount: Int
    }

    init(
        codexIndexer: SessionIndexer,
        claudeIndexer: ClaudeSessionIndexer,
        opencodeIndexer: OpenCodeSessionIndexer,
        liveFilterStorageKey: String = PreferencesKey.Cockpit.codexLiveFilterMode
    ) {
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.opencodeIndexer = opencodeIndexer
        _liveFilterModeRaw = AppStorage(
            wrappedValue: LiveFilterMode.live.rawValue,
            liveFilterStorageKey
        )
    }

    private var liveFilterMode: LiveFilterMode {
        switch liveFilterModeRaw {
        case LiveFilterMode.active.rawValue:
            return .active
        case LiveFilterMode.live.rawValue, "idle", "open", "both":
            return .live
        default:
            return .live
        }
    }

    private func makeLiveRowsSnapshot() -> LiveRowsSnapshot {
        let lookupIndexes = buildSessionLookupIndexes()
        let supportedSources: Set<SessionSource> = [.codex, .claude, .opencode]
        let allSessions = codexIndexer.allSessions + claudeIndexer.allSessions + opencodeIndexer.allSessions
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

        let mapped: [Row] = activeCodex.presences.compactMap { p in
            guard supportedSources.contains(p.source) else { return nil }
            let logNorm = p.sessionLogPath.map(CodexActiveSessionsModel.normalizePath)
            let presenceKey = CodexActiveSessionsModel.presenceKey(for: p)
            let session = logNorm.flatMap { normalized in
                lookupIndexes.byLogPath[CodexActiveSessionsModel.logLookupKey(source: p.source, normalizedPath: normalized)]
            } ?? resolveBySessionID(p.sessionId, source: p.source, lookupIndexes: lookupIndexes)
                ?? fallbackSessionByPresenceKey[presenceKey]
            if shouldHideUnresolvedPresencePlaceholder(p, resolvedSession: session, lookupIndexes: lookupIndexes) {
                return nil
            }

            let title = session?.title
                ?? p.sessionId.map { "Session \($0.prefix(8))" }
                ?? "Active \(p.source.displayName) session"

            let repo = session?.repoName ?? session?.repoDisplay ?? "—"

            // Use a stable session timestamp (session start/mtime), not a heartbeat.
            let date = session?.modifiedAt ?? parseSessionTimestamp(from: p)
            let dateLabel = date.map { Self.rowDateFormatter.string(from: $0) } ?? "—"

            let termProgram = p.terminal?.termProgram ?? ""
            let terminal: String = {
                if p.revealURL != nil { return "iTerm2" }
                if termProgram.lowercased().contains("iterm") { return "iTerm2" }
                if termProgram.lowercased().contains("terminal") { return "Terminal" }
                return termProgram.isEmpty ? "—" : termProgram
            }()
            let liveState = activeCodex.liveState(for: p)

            let focusHelp: String = {
                if CodexActiveSessionsModel.canAttemptITerm2Focus(
                    itermSessionId: p.terminal?.itermSessionId,
                    tty: p.tty,
                    termProgram: p.terminal?.termProgram
                ) || p.revealURL != nil {
                    return "Focus the existing iTerm2 tab/window for this session."
                }
                return "Focus is unavailable for this terminal session."
            }()

            let stableID: String =
                "\(p.source.rawValue)|" + (logNorm
                ?? p.sessionId
                ?? p.sourceFilePath
                ?? p.pid.map { "pid:\($0)" }
                ?? p.tty
                ?? "\(p.sessionLogPath ?? "unknown")|\(p.pid ?? -1)")

            return Row(
                id: stableID,
                source: p.source,
                title: title,
                liveState: liveState,
                lastSeenAt: p.lastSeenAt,
                repo: repo,
                date: date,
                dateLabel: dateLabel,
                terminal: terminal,
                termProgram: p.terminal?.termProgram,
                focusURL: p.revealURL,
                itermSessionId: p.terminal?.itermSessionId,
                tty: p.tty,
                focusHelp: focusHelp,
                sessionID: authoritativeSessionID(for: p, resolvedSession: session),
                logPath: p.sessionLogPath,
                workingDirectory: session?.cwd ?? p.workspaceRoot
            )
        }

        let deduped = dedupeRowsByResolvedSession(mapped)

        // Sort by session timestamp (newest first) so rows don't jump on heartbeat updates.
        let rows = deduped.sorted { a, b in
            let da = a.date ?? .distantPast
            let db = b.date ?? .distantPast
            if da != db { return da > db }
            if a.repo != b.repo { return a.repo < b.repo }
            return a.title < b.title
        }
        let filteredRows: [Row]
        switch liveFilterMode {
        case .active:
            filteredRows = rows.filter { $0.liveState == .activeWorking }
        case .live:
            filteredRows = rows
        }
        return LiveRowsSnapshot(
            filteredRows: filteredRows,
            activeCount: rows.reduce(into: 0) { partial, row in
                if row.liveState == .activeWorking { partial += 1 }
            },
            idleCount: rows.reduce(into: 0) { partial, row in
                if row.liveState == .openIdle { partial += 1 }
            }
        )
    }

    var body: some View {
        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: content.preferredColorScheme(.light)
            case .dark: content.preferredColorScheme(.dark)
            case .system: content
            }
        }
        .onAppear {
            let normalizedMode = liveFilterMode.rawValue
            if liveFilterModeRaw != normalizedMode {
                liveFilterModeRaw = normalizedMode
            }
            activeCodex.setCockpitConsumerVisible(true, consumerID: activeConsumerID)
        }
        .onDisappear {
            activeCodex.setCockpitConsumerVisible(false, consumerID: activeConsumerID)
        }
    }

    private var content: some View {
        let snapshot = makeLiveRowsSnapshot()
        return VStack(spacing: 10) {
            header

            if !activeEnabled {
                PreferenceCallout {
                    Text("Live sessions + Cockpit (Beta) is disabled in Settings → Agent Cockpit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }

            Table(snapshot.filteredRows, selection: $selection) {
                TableColumn("CLI Agent") { row in
                    Text(sourceLabel(for: row.source))
                        .foregroundStyle(rowAgentForeground(for: row))
                }
                .width(min: 86, ideal: 96, max: 112)
                TableColumn("Name") { row in
                    HStack(spacing: 8) {
                        CodexLiveStatusDot(state: row.liveState, color: rowStatusDotColor(for: row), size: 7)
                            .help(row.liveState == .activeWorking ? "Active (working)" : "Waiting")
                        Text(row.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                TableColumn("Project") { row in
                    Text(row.repo)
                        .foregroundStyle(rowSecondaryForeground(for: row))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                TableColumn("Date") { row in
                    Text(row.dateLabel)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(rowSecondaryForeground(for: row))
                        .help(row.dateLabel)
                }
                .width(min: 140, ideal: 150, max: 170)
                TableColumn("Terminal") { row in
                    Text(row.terminal)
                        .foregroundStyle(rowSecondaryForeground(for: row))
                }
                TableColumn("Focus") { row in
                    Button("Focus") { focus(row) }
                        .buttonStyle(.bordered)
                        .disabled(!canFocus(row))
                        .help(row.focusHelp)
                }
                .width(min: 78, ideal: 90, max: 100)
            }
            .id("cockpit-table-\(liveFilterModeRaw)-\(activeCodex.activeMembershipVersion)")
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .tint(CockpitStyle.selectionAccent)
            .environment(\.defaultMinListRowHeight, CockpitStyle.rowHeight)
            .frame(minHeight: CockpitStyle.defaultTableMinHeight, maxHeight: .infinity)
            .disabled(!activeEnabled)
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let id = ids.first, let row = snapshot.filteredRows.first(where: { $0.id == id }) {
                    Button("Focus in iTerm2") { focus(row) }
                        .disabled(!activeEnabled || !canFocus(row))
                        .help(row.focusHelp)
                    Divider()
                    Button("Reveal Log") { revealLog(row) }
                        .disabled(!activeEnabled || row.logPath == nil)
                        .help("Reveal the session log in Finder.")
                    Button("Open Working Directory") { openWorkingDirectory(row) }
                        .disabled(!activeEnabled || row.workingDirectory == nil)
                        .help("Open the working directory in Finder.")
                } else {
                    Button("Focus") {}.disabled(true)
                    Button("Reveal Log") {}.disabled(true)
                }
            }

            footer(snapshot: snapshot)
        }
        .frame(minWidth: 770, minHeight: CockpitStyle.defaultWindowMinHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $liveFilterModeRaw) {
                ForEach(LiveFilterMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 170)
            .controlSize(.small)
            .disabled(!activeEnabled)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func footer(snapshot: LiveRowsSnapshot) -> some View {
        HStack {
            Text(footerText(snapshot: snapshot))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh") { refreshAllSources() }
                .disabled(!activeEnabled)
                .help("Refresh active sessions and session indexes now.")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func footerText(snapshot: LiveRowsSnapshot) -> String {
        "\(snapshot.filteredRows.count) shown • \(snapshot.activeCount) active • \(snapshot.idleCount) waiting"
    }

    private func rowIsSelected(_ row: Row) -> Bool {
        selection.contains(row.id)
    }

    private func rowSecondaryForeground(for row: Row) -> Color {
        rowIsSelected(row) ? .primary : .secondary
    }

    private func rowAgentForeground(for row: Row) -> Color {
        rowIsSelected(row) ? .primary : Color.agentColor(for: row.source, monochrome: false)
    }

    private func rowStatusDotColor(for row: Row) -> Color {
        switch row.liveState {
        case .activeWorking:
            return Color(hex: "30d158")
        case .openIdle:
            return effectiveColorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
        }
    }

    private func refreshAllSources() {
        guard activeEnabled else { return }
        activeCodex.refreshNow()
        codexIndexer.refresh(mode: .incremental, trigger: .manual)
        claudeIndexer.refresh(mode: .incremental, trigger: .manual)
        opencodeIndexer.refresh()
    }

    private func focus(_ row: Row) {
        if CodexActiveSessionsModel.tryFocusITerm2(itermSessionId: row.itermSessionId, tty: row.tty) {
            return
        }
        if let url = row.focusURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func revealLog(_ row: Row) {
        guard let path = row.logPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func openWorkingDirectory(_ row: Row) {
        guard let path = row.workingDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
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

    private func resolveByWorkingDirectory(_ path: String?, source: SessionSource, lookupIndexes: SessionLookupIndexes) -> Session? {
        guard let path else { return nil }
        let normalized = CodexActiveSessionsModel.normalizePath(path)
        guard !normalized.isEmpty else { return nil }
        let key = workspaceLookupKey(source: source, normalizedPath: normalized)
        return lookupIndexes.byWorkspace[key]
    }

    private func canFocus(_ row: Row) -> Bool {
        CodexActiveSessionsModel.canAttemptITerm2Focus(
            itermSessionId: row.itermSessionId,
            tty: row.tty,
            termProgram: row.termProgram
        ) || row.focusURL != nil
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
        // Keep unresolved rows only when they still offer user actionability:
        // direct join keys, focusable terminals, or known workspace joins.
        // Registry file path (`sourceFilePath`) by itself is not actionable and can
        // surface ghost sub-agent rows with no own terminal/session.
        guard resolvedSession == nil else { return false }
        let kind = presence.kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if kind == "subagent" { return true }

        // Codex placeholders without a resolved indexed session are often stale
        // discovery artifacts in Cockpit. Keep Codex rows only when joined.
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

        // For non-Codex providers, unresolved placeholders are noisy in Cockpit
        // unless they are iTerm-backed/focusable or can be workspace-joined.
        if canFocusFallbackStrict { return false }
        if hasWorkspaceMatch { return false }
        return true
    }

    private func dedupeRowsByResolvedSession(_ rows: [Row]) -> [Row] {
        var byKey: [String: Row] = [:]
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

    private func preferredRow(existing: Row?, incoming: Row) -> Row {
        guard let existing else { return incoming }
        let existingHasDate = existing.date != nil
        let incomingHasDate = incoming.date != nil
        if existingHasDate != incomingHasDate {
            return incomingHasDate ? incoming : existing
        }
        let existingSeen = existing.lastSeenAt ?? .distantPast
        let incomingSeen = incoming.lastSeenAt ?? .distantPast
        if incomingSeen != existingSeen {
            return incomingSeen > existingSeen ? incoming : existing
        }
        let existingHasJoin = (existing.sessionID?.isEmpty == false) || existing.logPath != nil
        let incomingHasJoin = (incoming.sessionID?.isEmpty == false) || incoming.logPath != nil
        if existingHasJoin != incomingHasJoin {
            return incomingHasJoin ? incoming : existing
        }
        if existing.liveState != incoming.liveState {
            let existingCanProbe = rowCanTailProbe(existing)
            let incomingCanProbe = rowCanTailProbe(incoming)
            if existingCanProbe != incomingCanProbe {
                return incomingCanProbe ? incoming : existing
            }
            // Avoid sticky false-active ties when two duplicate candidates disagree.
            if existing.liveState == .activeWorking, incoming.liveState == .openIdle {
                return incoming
            }
            return existing
        }
        if incoming.title.count > existing.title.count {
            return incoming
        }
        return existing
    }

    private func rowCanTailProbe(_ row: Row) -> Bool {
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
        // rollout-YYYY-MM-DDThh-mm-ss-<uuid>.jsonl
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
        let supportedSources: Set<SessionSource> = [.codex, .claude, .opencode]
        let allSessions = codexIndexer.allSessions + claudeIndexer.allSessions + opencodeIndexer.allSessions

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
        if incoming.modifiedAt != existing.modifiedAt { return incoming.modifiedAt > existing.modifiedAt ? incoming : existing }
        let incomingStart = incoming.startTime ?? .distantPast
        let existingStart = existing.startTime ?? .distantPast
        if incomingStart != existingStart { return incomingStart > existingStart ? incoming : existing }
        if incoming.filePath != existing.filePath { return incoming.filePath < existing.filePath ? incoming : existing }
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

    private func sourceLabel(for source: SessionSource) -> String {
        switch source {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .opencode: return "OpenCode"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .droid: return "Droid"
        case .openclaw: return "OpenClaw"
        case .cursor: return "Cursor"
        }
    }
}
