import SwiftUI

struct SessionTimelineView: View {
    @EnvironmentObject var indexer: SessionIndexer
    let sessionID: String?
    @Binding var selectedEventID: String?

    var body: some View {
        if let sid = sessionID, let session = indexer.sessions.first(where: { $0.id == sid }) {
            List(selection: $selectedEventID) {
                ForEach(filteredEvents(session), id: \.id) { event in
                    EventRow(event: event)
                        .tag(event.id as String?)
                }
            }
            .navigationTitle("Timeline")
        } else {
            ContentUnavailableView("No Session Selected", systemImage: "text.bubble")
        }
    }

    private func filteredEvents(_ session: Session) -> [SessionEvent] {
        let selectedKinds = indexer.selectedKinds
        let q = indexer.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return session.events.filter { e in
            guard selectedKinds.contains(e.kind) else { return false }
            guard !q.isEmpty else { return true }
            let haystacks = [e.text?.lowercased(), e.toolInput?.lowercased(), e.toolOutput?.lowercased(), e.rawJSON.lowercased()]
            return haystacks.contains { ($0 ?? "").contains(q) }
        }
    }
}
private struct EventRow: View {
    @State private var expanded = false
    let event: SessionEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                kindBadge
                Text(timestampLabel)
                    .font(.caption).foregroundStyle(.secondary)
                    .help(fullTimestamp)
                Spacer()
                Button(action: { expanded.toggle() }) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
            }
            Group {
                if let text = event.text, !text.isEmpty {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(expanded ? nil : 3)
                } else if let out = event.toolOutput, !out.isEmpty {
                    Text(out)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(expanded ? nil : 3)
                } else {
                    Text("(no text)").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var timestampLabel: String {
        guard let ts = event.timestamp else { return "" }
        let r = RelativeDateTimeFormatter()
        r.unitsStyle = .short
        return r.localizedString(for: ts, relativeTo: Date())
    }

    private var fullTimestamp: String {
        guard let ts = event.timestamp else { return "" }
        return AppDateFormatting.dateTimeMedium(ts)
    }

    private var kindBadge: some View {
        let label: String
        let color: Color
        switch event.kind {
        case .user: label = "user"; color = .blue
        case .assistant: label = "assistant"; color = .green
        case .tool_call: label = event.toolName ?? "tool_call"; color = .orange
        case .tool_result: label = event.toolName ?? "tool_result"; color = .teal
        case .error: label = "error"; color = .red
        case .meta: label = "meta"; color = .gray
        }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
