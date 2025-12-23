import SwiftUI
import AppKit

struct PinnedSessionsView: View {
    @ObservedObject var unified: UnifiedSessionIndexer
    @EnvironmentObject var archiveManager: SessionArchiveManager
    @State private var query: String = ""
    @State private var selection: Set<RowKey> = []
    @State private var pendingDeleteSelection: Set<RowKey> = []
    @State private var showDeleteConfirm: Bool = false

    private struct RowKey: Hashable {
        let source: SessionSource
        let id: String
    }

    private struct Row: Identifiable {
        let id: RowKey
        let title: String
        let sourceLabel: String
        let statusLabel: String
        let statusHelp: String
        let lastSyncLabel: String
        let sizeLabel: String
    }

    private var rows: [Row] {
        let base = unified.allSessions.filter { $0.isFavorite }
        let filtered: [Session]
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = base
        } else {
            let q = query.lowercased()
            filtered = base.filter { s in
                s.title.lowercased().contains(q) ||
                s.source.displayName.lowercased().contains(q) ||
                (s.repoName?.lowercased().contains(q) ?? false) ||
                (s.cwd?.lowercased().contains(q) ?? false)
            }
        }

        return filtered
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map { s in
                let info = archiveManager.info(source: s.source, id: s.id)
                return Row(
                    id: .init(source: s.source, id: s.id),
                    title: s.title,
                    sourceLabel: s.source.displayName,
                    statusLabel: archiveStatusLabel(for: info),
                    statusHelp: archiveStatusHelp(for: info),
                    lastSyncLabel: lastSyncLabel(for: info),
                    sizeLabel: sizeLabel(for: info)
                )
            }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Saved Sessions")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Table(rows, selection: $selection) {
                TableColumn("Title") { row in
                    Text(row.title)
                        .lineLimit(1)
                }
                TableColumn("Source") { row in
                    Text(row.sourceLabel)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Status") { row in
                    Text(row.statusLabel)
                        .foregroundStyle(.secondary)
                        .help(row.statusHelp)
                }
                TableColumn("Last Sync") { row in
                    Text(row.lastSyncLabel)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Size") { row in
                    Text(row.sizeLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 360)

            HStack {
                Text("\(rows.count) saved")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete Saved Copies…") { requestDeleteArchivedSelection() }
                    .disabled(selection.isEmpty)
                Button("Show Session Files") { revealUpstreamForSelection() }
                    .disabled(selection.count != 1)
                Button("Show Saved Copy") { revealArchiveForSelection() }
                    .disabled(selection.count != 1)
                Button("Remove from Saved") { unstarSelected() }
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(width: 820, height: 460)
        .alert("Delete Saved Copies?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { pendingDeleteSelection.removeAll() }
            Button("Delete", role: .destructive) { deleteArchivedSelection() }
        } message: {
            let count = pendingDeleteSelection.count
            Text("This will remove \(count) session\(count == 1 ? "" : "s") from Saved and move their local archive copies to the Trash. Original session files are not deleted.")
        }
        .onAppear {
            archiveManager.syncPinnedSessionsNow()
            backfillArchivesIfNeeded()
        }
        .onReceive(unified.$allSessions) { _ in backfillArchivesIfNeeded() }
    }

    private func unstarSelected() {
        let targets = selection
        selection.removeAll()
        for key in targets {
            if let s = unified.allSessions.first(where: { $0.id == key.id && $0.source == key.source }) {
                unified.toggleFavorite(s)
            } else {
                unified.toggleFavorite(key.id, source: key.source)
            }
        }
    }

    private func requestDeleteArchivedSelection() {
        pendingDeleteSelection = selection
        showDeleteConfirm = !pendingDeleteSelection.isEmpty
    }

    private func deleteArchivedSelection() {
        let targets = pendingDeleteSelection.isEmpty ? selection : pendingDeleteSelection
        pendingDeleteSelection.removeAll()
        selection.removeAll()
        for key in targets {
            archiveManager.deleteArchiveNow(source: key.source, id: key.id)
            if let s = unified.allSessions.first(where: { $0.id == key.id && $0.source == key.source }) {
                if s.isFavorite {
                    unified.toggleFavorite(s)
                }
            } else {
                let favorites = StarredSessionsStore()
                if favorites.pinnedIDs(for: key.source).contains(key.id) {
                    unified.toggleFavorite(key.id, source: key.source)
                }
            }
        }
    }

    private func archiveStatusLabel(for info: SessionArchiveInfo?) -> String {
        guard let info else {
            let pins = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions) as? Bool ?? true
            return pins ? "Saving…" : "Saved"
        }
        if info.upstreamMissing { return "Upstream missing" }
        switch info.status {
        case .none: return "Saved"
        case .staging: return "Saving…"
        case .syncing: return "Saved"
        case .final: return "Saved"
        case .error: return "Error"
        }
    }

    private func archiveStatusHelp(for info: SessionArchiveInfo?) -> String {
        let pins = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions) as? Bool ?? true
        guard pins else { return "Archiving is disabled in Settings." }
        guard let info else {
            return "Saved-copy metadata not initialized yet. Try “Show Saved Copy” to retry saving."
        }
        var parts: [String] = []
        if let err = info.lastError, !err.isEmpty {
            parts.append("Error: \(err)")
        }
        parts.append("Upstream: \(info.upstreamPath)")
        return parts.joined(separator: "\n")
    }

    private func lastSyncLabel(for info: SessionArchiveInfo?) -> String {
        guard let t = info?.lastSyncAt else { return "—" }
        let r = RelativeDateTimeFormatter()
        r.unitsStyle = .short
        return r.localizedString(for: t, relativeTo: Date())
    }

    private func sizeLabel(for info: SessionArchiveInfo?) -> String {
        guard let bytes = info?.archiveSizeBytes, bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func backfillArchivesIfNeeded() {
        let pins = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions) as? Bool ?? true
        guard pins else { return }

        // Backfill archives for previously-starred sessions when the user explicitly opens this window.
        for s in unified.allSessions where s.isFavorite {
            if archiveManager.info(source: s.source, id: s.id) == nil {
                archiveManager.pin(session: s)
            }
        }
    }

    private func revealUpstreamForSelection() {
        guard let key = selection.first else { return }
        guard let s = unified.allSessions.first(where: { $0.id == key.id && $0.source == key.source }) else { return }
        let url = URL(fileURLWithPath: s.filePath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } else {
            let parent = url.deletingLastPathComponent()
            NSWorkspace.shared.open(parent)
        }
    }

    private func revealArchiveForSelection() {
        guard let key = selection.first else { return }
        if archiveManager.info(source: key.source, id: key.id) == nil,
           let s = unified.allSessions.first(where: { $0.id == key.id && $0.source == key.source }) {
            archiveManager.pin(session: s)
        }
        guard let url = archiveManager.archiveFolderURL(source: key.source, id: key.id) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(archiveManager.archivesRootURL())
        }
    }
}
