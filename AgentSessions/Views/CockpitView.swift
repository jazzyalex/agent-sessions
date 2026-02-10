import SwiftUI
import AppKit

struct CockpitView: View {
    @ObservedObject var codexIndexer: SessionIndexer
    @EnvironmentObject var activeCodex: CodexActiveSessionsModel
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var activeEnabled: Bool = true

    private enum Mode: String, CaseIterable, Identifiable {
        case active
        case all
        var id: String { rawValue }
        var title: String { self == .active ? "Active" : "All" }
    }

    @State private var mode: Mode = .active
    @State private var selection: Set<String> = []

    private struct Row: Identifiable {
        let id: String
        let title: String
        let repo: String
        let workspace: String
        let terminal: String
        let lastSeenLabel: String
        let isActive: Bool
        let focusURL: URL?
        let focusHelp: String
        let sessionID: String?
        let logPath: String?
        let workingDirectory: String?
    }

    private var activeRows: [Row] {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short

        let now = Date()
        var sessionsByLogPath: [String: Session] = [:]
        for s in codexIndexer.allSessions where s.source == .codex {
            sessionsByLogPath[normalizePath(s.filePath)] = s
        }

        return activeCodex.presences
            .sorted(by: { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) })
            .map { p in
                let logNorm = p.sessionLogPath.map(normalizePath)
                let session = logNorm.flatMap { sessionsByLogPath[$0] } ?? resolveBySessionID(p.sessionId)

                let title = session?.title
                    ?? p.sessionId.map { "Session \($0.prefix(8))" }
                    ?? "Active Codex session"

                let repo = session?.repoName ?? session?.repoDisplay ?? "—"
                let workspace = session?.cwd ?? p.workspaceRoot ?? "—"
                let termProgram = p.terminal?.termProgram ?? ""
                let terminal: String = {
                    if p.revealURL != nil { return "iTerm2" }
                    if termProgram.lowercased().contains("iterm") { return "iTerm2" }
                    if termProgram.lowercased().contains("terminal") { return "Terminal" }
                    return termProgram.isEmpty ? "—" : termProgram
                }()

                let lastSeenLabel: String = {
                    guard let t = p.lastSeenAt else { return "—" }
                    return formatter.localizedString(for: t, relativeTo: now)
                }()

                let focusHelp: String = {
                    if p.revealURL != nil { return "Focus the existing iTerm2 tab/window for this session." }
                    if let id = p.terminal?.itermSessionId, !id.isEmpty {
                        return "iTerm2 session id present but reveal URL could not be formed."
                    }
                    return "Focus is unavailable (missing iTerm2 session id)."
                }()

                return Row(
                    id: p.sourceFilePath ?? "\(p.sessionId ?? "unknown")|\(p.sessionLogPath ?? "unknown")",
                    title: title,
                    repo: repo,
                    workspace: workspace,
                    terminal: terminal,
                    lastSeenLabel: lastSeenLabel,
                    isActive: true,
                    focusURL: p.revealURL,
                    focusHelp: focusHelp,
                    sessionID: p.sessionId,
                    logPath: p.sessionLogPath,
                    workingDirectory: session?.cwd ?? p.workspaceRoot
                )
            }
    }

    private var allRows: [Row] {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let now = Date()

        return codexIndexer.allSessions
            .filter { $0.source == .codex }
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .map { s in
                let p = activeCodex.presence(for: s)
                let termProgram = p?.terminal?.termProgram ?? ""
                let terminal: String = {
                    if p?.revealURL != nil { return "iTerm2" }
                    if termProgram.lowercased().contains("iterm") { return "iTerm2" }
                    if termProgram.lowercased().contains("terminal") { return "Terminal" }
                    return termProgram.isEmpty ? "—" : termProgram
                }()
                let lastSeenLabel: String = {
                    guard let t = p?.lastSeenAt else { return "—" }
                    return formatter.localizedString(for: t, relativeTo: now)
                }()
                let focusHelp: String = {
                    if let url = p?.revealURL, url.absoluteString.hasPrefix("iterm2:") {
                        return "Focus the existing iTerm2 tab/window for this session."
                    }
                    if p == nil { return "This session is not currently active." }
                    return "Focus is unavailable (missing iTerm2 session id)."
                }()

                return Row(
                    id: s.id,
                    title: s.title,
                    repo: s.repoName ?? s.repoDisplay,
                    workspace: s.cwd ?? "—",
                    terminal: terminal,
                    lastSeenLabel: lastSeenLabel,
                    isActive: p != nil,
                    focusURL: p?.revealURL,
                    focusHelp: focusHelp,
                    sessionID: s.codexInternalSessionID ?? s.codexFilenameUUID,
                    logPath: s.filePath,
                    workingDirectory: s.cwd
                )
            }
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
    }

    private var content: some View {
        VStack(spacing: 10) {
            header

            if !activeEnabled {
                PreferenceCallout {
                    Text("Active session detection is disabled in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }

            Table(rows, selection: $selection) {
                TableColumn("Session") { row in
                    HStack(spacing: 8) {
                        if row.isActive {
                            Text("ACTIVE")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                                )
                                .cornerRadius(6)
                        }
                        Text(row.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                TableColumn("Project") { row in
                    Text(row.repo)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                TableColumn("Workspace") { row in
                    Text(row.workspace)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Terminal") { row in
                    Text(row.terminal)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Seen") { row in
                    Text(row.lastSeenLabel)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Focus") { row in
                    Button("Focus") { focus(row) }
                        .buttonStyle(.bordered)
                        .disabled(row.focusURL == nil)
                        .help(row.focusHelp)
                }
                .width(min: 78, ideal: 90, max: 100)
            }
            .frame(minHeight: 360)
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Focus in iTerm2") { focus(row) }
                        .disabled(row.focusURL == nil)
                        .help(row.focusHelp)
                    Divider()
                    Button("Reveal Log") { revealLog(row) }
                        .disabled(row.logPath == nil)
                        .help("Reveal the session log in Finder.")
                    Button("Open Working Directory") { openWorkingDirectory(row) }
                        .disabled(row.workingDirectory == nil)
                        .help("Open the working directory in Finder.")
                    Button("Copy Session ID") { copySessionID(row) }
                        .disabled(row.sessionID == nil)
                        .help("Copy the Codex session id to the clipboard.")
                } else {
                    Button("Focus") {}.disabled(true)
                    Button("Reveal Log") {}.disabled(true)
                    Button("Copy Session ID") {}.disabled(true)
                }
            }

            footer
        }
        .frame(width: 980, height: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Cockpit")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh") { activeCodex.refreshNow() }
                .help("Refresh active session registry now.")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var footerText: String {
        switch mode {
        case .active:
            return "\(activeRows.count) active"
        case .all:
            return "\(allRows.count) sessions"
        }
    }

    private var rows: [Row] {
        switch mode {
        case .active: return activeRows
        case .all: return allRows
        }
    }

    private func focus(_ row: Row) {
        guard let url = row.focusURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealLog(_ row: Row) {
        guard let path = row.logPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func openWorkingDirectory(_ row: Row) {
        guard let path = row.workingDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func copySessionID(_ row: Row) {
        guard let id = row.sessionID, !id.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    private func resolveBySessionID(_ id: String?) -> Session? {
        guard let id, !id.isEmpty else { return nil }
        // Best-effort: only check loaded sessions. (Log-path join is preferred and cheap.)
        return codexIndexer.allSessions.first(where: { s in
            s.source == .codex && (s.codexInternalSessionID == id || s.codexFilenameUUID == id)
        })
    }

    private func normalizePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
