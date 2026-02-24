import SwiftUI
import AppKit

struct CockpitView: View {
    @ObservedObject var codexIndexer: SessionIndexer
    @EnvironmentObject var activeCodex: CodexActiveSessionsModel
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled) private var activeEnabled: Bool = true
    @State private var selection: Set<String> = []

    private struct Row: Identifiable {
        let id: String
        let title: String
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

    private var activeRows: [Row] {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var sessionsByLogPath: [String: Session] = [:]
        for s in codexIndexer.allSessions where s.source == .codex {
            sessionsByLogPath[normalizePath(s.filePath)] = s
        }

        let mapped: [Row] = activeCodex.presences.map { p in
            let logNorm = p.sessionLogPath.map(normalizePath)
            let session = logNorm.flatMap { sessionsByLogPath[$0] } ?? resolveBySessionID(p.sessionId)

            let title = session?.title
                ?? p.sessionId.map { "Session \($0.prefix(8))" }
                ?? "Active Codex session"

            let repo = session?.repoName ?? session?.repoDisplay ?? "—"

            // Use a stable session timestamp (Codex filename timestamp / start time), not a heartbeat.
            let date = session?.modifiedAt ?? parseRolloutTimestamp(from: p.sessionLogPath)
            let dateLabel = date.map { dateFormatter.string(from: $0) } ?? "—"

            let termProgram = p.terminal?.termProgram ?? ""
            let terminal: String = {
                if p.revealURL != nil { return "iTerm2" }
                if termProgram.lowercased().contains("iterm") { return "iTerm2" }
                if termProgram.lowercased().contains("terminal") { return "Terminal" }
                return termProgram.isEmpty ? "—" : termProgram
            }()

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
                logNorm
                ?? p.sessionId
                ?? p.sourceFilePath
                ?? p.pid.map { "pid:\($0)" }
                ?? p.tty
                ?? "\(p.sessionLogPath ?? "unknown")|\(p.pid ?? -1)"

            return Row(
                id: stableID,
                title: title,
                repo: repo,
                date: date,
                dateLabel: dateLabel,
                terminal: terminal,
                termProgram: p.terminal?.termProgram,
                focusURL: p.revealURL,
                itermSessionId: p.terminal?.itermSessionId,
                tty: p.tty,
                focusHelp: focusHelp,
                sessionID: p.sessionId,
                logPath: p.sessionLogPath,
                workingDirectory: session?.cwd ?? p.workspaceRoot
            )
        }

        // Sort by session timestamp (newest first) so rows don't jump on heartbeat updates.
        return mapped.sorted { a, b in
            let da = a.date ?? .distantPast
            let db = b.date ?? .distantPast
            if da != db { return da > db }
            if a.repo != b.repo { return a.repo < b.repo }
            return a.title < b.title
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

            Table(activeRows, selection: $selection) {
                TableColumn("Name") { row in
                    HStack(spacing: 8) {
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
                TableColumn("Date") { row in
                    Text(row.dateLabel)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help(row.dateLabel)
                }
                .width(min: 140, ideal: 150, max: 170)
                TableColumn("Terminal") { row in
                    Text(row.terminal)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Focus") { row in
                    Button("Focus") { focus(row) }
                        .buttonStyle(.bordered)
                        .disabled(!canFocus(row))
                        .help(row.focusHelp)
                }
                .width(min: 78, ideal: 90, max: 100)
            }
            .frame(minHeight: 360)
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let id = ids.first, let row = activeRows.first(where: { $0.id == id }) {
                    Button("Focus in iTerm2") { focus(row) }
                        .disabled(!canFocus(row))
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
        "\(activeRows.count) active"
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

    private func canFocus(_ row: Row) -> Bool {
        CodexActiveSessionsModel.canAttemptITerm2Focus(
            itermSessionId: row.itermSessionId,
            tty: row.tty,
            termProgram: row.termProgram
        ) || row.focusURL != nil
    }

    private func parseRolloutTimestamp(from path: String?) -> Date? {
        guard let path else { return nil }
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

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.date(from: ts)
    }
}
