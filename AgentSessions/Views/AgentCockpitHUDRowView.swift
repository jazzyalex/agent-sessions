import SwiftUI

private enum AgentCockpitHUDRowLayout {
    static let agentColumnWidth: CGFloat = 84
    static let projectColumnWidth: CGFloat = 80
    static let groupedProjectSpacerWidth: CGFloat = 4
    static let compactAgentColumnWidth: CGFloat = 64
    static let compactTabColumnWidth: CGFloat = 96
}

struct AgentCockpitHUDRowView: View {
    let row: HUDRow
    let shortcutIndex: Int?
    let isSelected: Bool
    let filterText: String
    let isGrouped: Bool
    let isCompact: Bool
    let isNewlyInserted: Bool
    let onTap: () -> Void
    @AppStorage(PreferencesKey.Cockpit.hudShowAgentNameInCompact) private var showAgentNameInCompact: Bool = true
    @AppStorage(PreferencesKey.Cockpit.showTabSubtitleInFullMode) private var showTabSubtitleInFullMode: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if isCompact {
                    compactLayout
                } else {
                    fullLayout
                }
            }
            .padding(.leading, isGrouped ? 24 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(backgroundColor)
            .overlay {
                if isNewlyInserted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.11))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.leading, isGrouped ? 24 : 12)
            }
        }
        .buttonStyle(.plain)
    }

    private var statusDot: some View {
        CodexLiveStatusDot(
            state: codexLiveState,
            color: statusDotColor,
            size: 7,
            lastSeenAt: row.lastSeenAt,
            idleReason: row.idleReason
        )
        .accessibilityLabel(row.liveState == .active ? "Active" : (row.idleReason?.label ?? "Waiting"))
        .frame(width: 9, alignment: .center)
    }

    private var fullLayout: some View {
        HStack(spacing: 6) {
            statusDot

            VStack(alignment: .leading, spacing: 2) {
                agentBadge

                if showTabSubtitleInFullMode, let tabTitle = normalizedTabTitle {
                    Text(tabTitle)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(elapsedColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(tabTitle)
                }
            }
            .frame(width: AgentCockpitHUDRowLayout.agentColumnWidth, alignment: .leading)

            if isGrouped {
                Color.clear
                    .frame(width: AgentCockpitHUDRowLayout.groupedProjectSpacerWidth, height: 1)
            } else {
                highlightedText(row.projectName)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: AgentCockpitHUDRowLayout.projectColumnWidth, alignment: .leading)
            }

            highlightedText(sessionTitle)
                .font(.system(size: 13, weight: sessionTitleWeight, design: .monospaced))
                .foregroundStyle(primaryTextColor)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.elapsed)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(elapsedColor)
                .lineLimit(1)
                .frame(minWidth: 30, alignment: .trailing)
                .help(row.lastActivityTooltip ?? "Last activity unavailable")

            if let shortcutLabel {
                Text(shortcutLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.primary.opacity(0.84) : Color.secondary.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(width: 56)
                    .background(Color.primary.opacity(isSelected ? 0.12 : 0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isSelected ? 0.20 : 0.10), lineWidth: 0.5)
                    )
            } else {
                Color.clear
                    .frame(width: 56, height: 20)
            }
        }
    }

    private var compactLayout: some View {
        HStack(spacing: 6) {
            statusDot

            if showAgentNameInCompact {
                agentBadge
                    .frame(width: AgentCockpitHUDRowLayout.compactAgentColumnWidth, alignment: .leading)
            }

            Text(compactTabWindowLabel)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(elapsedColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: AgentCockpitHUDRowLayout.compactTabColumnWidth, alignment: .leading)
                .help(normalizedTabTitle ?? "No tab/window title")

            Text(sessionTitle)
                .font(.system(size: 13, weight: sessionTitleWeight, design: .monospaced))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shortcutLabel: String? {
        if isSelected { return "↩" }
        guard let shortcutIndex, (1...9).contains(shortcutIndex) else { return nil }
        return "⌘\(shortcutIndex)"
    }

    private var normalizedTabTitle: String? {
        row.cleanedTabTitle
    }

    private var compactTabWindowLabel: String {
        let cleaned = normalizedTabTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "—" : cleaned
    }

    private var isStaleWaiting: Bool {
        AgentCockpitHUDView.isStaleWaiting(row)
    }

    private var elapsedColor: Color {
        let base = colorScheme == .dark ? Color(hex: "6e6e73") : Color(hex: "8e8e93")
        return isStaleWaiting ? base.opacity(0.72) : base
    }

    private var primaryTextColor: Color {
        isStaleWaiting ? Color.primary.opacity(0.82) : .primary
    }

    private var sessionTitle: String {
        let preview = row.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            return preview
        }
        return row.displayName
    }

    private var sessionTitleWeight: Font.Weight {
        row.liveState == .idle ? .semibold : .regular
    }

    private var agentBadge: some View {
        HStack(spacing: 2) {
            Text(row.agentType.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(badgeTextColor)
                .lineLimit(1)
            if row.activeSubagentCount > 0 {
                Text("(\(row.activeSubagentCount))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var badgeTextColor: Color {
        if isSelected { return .primary }
        let base: Color
        if colorScheme == .light {
            switch row.agentType {
            case .codex:
                base = Color(hex: "2b56b8")
            case .claude:
                base = Color(hex: "b86a1d")
            case .opencode:
                base = Color(hex: "1a7a4a")
            case .shell:
                base = Color(hex: "7a7a80")
            }
        } else {
            base = row.agentType.standardTextColor
        }
        return isStaleWaiting ? base.opacity(0.76) : base
    }

    private var codexLiveState: CodexLiveState {
        row.liveState == .active ? .activeWorking : .openIdle
    }

    private var statusDotColor: Color {
        switch row.liveState {
        case .active:
            return Color(hex: "30d158")
        case .idle:
            if row.idleReason == .errorOrStuck {
                return colorScheme == .dark ? Color(hex: "ff453a") : Color(hex: "d70015")
            }
            if isStaleWaiting {
                return colorScheme == .dark ? Color(hex: "c79033") : Color(hex: "b37512")
            }
            return colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
        }
    }

    private func highlightedText(_ text: String) -> Text {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Text(text)
        }

        guard let swiftRange = text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(text)
        }

        let prefix = String(text[..<swiftRange.lowerBound])
        let match = String(text[swiftRange])
        let suffix = String(text[swiftRange.upperBound...])

        return Text(prefix)
            + Text(match).bold().foregroundColor(.accentColor)
            + Text(suffix)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.055)
        }
        return .clear
    }
}

#if DEBUG
private func previewRow(
    id: String,
    agentType: HUDAgentType,
    source: SessionSource,
    project: String,
    preview: String,
    idleReason: HUDIdleReason?
) -> HUDRow {
    HUDRow(
        id: id,
        source: source,
        agentType: agentType,
        projectName: project,
        displayName: preview,
        liveState: .idle,
        preview: preview,
        elapsed: "2m",
        lastSeenAt: Date(),
        itermSessionId: nil,
        revealURL: nil,
        tty: nil,
        termProgram: nil,
        lastActivityTooltip: "Just now",
        idleReason: idleReason
    )
}

private struct IdleReasonPreviewMatrix: View {
    private let rows: [HUDRow] = [
        previewRow(id: "1", agentType: .claude, source: .claude, project: "my-app",   preview: "implement auth module", idleReason: .generic),
        previewRow(id: "2", agentType: .codex,  source: .codex,  project: "frontend", preview: "fix layout bug",        idleReason: .generic),
        previewRow(id: "3", agentType: .claude, source: .claude, project: "legacy",   preview: "migrate to swift 6",   idleReason: .errorOrStuck),
        HUDRow(id: "4", source: .claude, agentType: .claude, projectName: "active-proj",
               displayName: "refactor db layer", liveState: .active, preview: "refactor db layer",
               elapsed: "12s", lastSeenAt: Date(), itermSessionId: nil, revealURL: nil, tty: nil, termProgram: nil),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                AgentCockpitHUDRowView(
                    row: row,
                    shortcutIndex: nil,
                    isSelected: false,
                    filterText: "",
                    isGrouped: false,
                    isCompact: false,
                    isNewlyInserted: false,
                    onTap: {}
                )
            }
        }
        .frame(width: 640)
        .padding(8)
    }
}

#Preview("Idle Reason States – Light") {
    IdleReasonPreviewMatrix()
        .preferredColorScheme(.light)
        .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Idle Reason States – Dark") {
    IdleReasonPreviewMatrix()
        .preferredColorScheme(.dark)
        .background(Color(NSColor.windowBackgroundColor))
}
#endif
