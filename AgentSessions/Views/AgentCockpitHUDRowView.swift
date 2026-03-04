import SwiftUI

private enum AgentCockpitHUDRowLayout {
    static let agentColumnWidth: CGFloat = 84
    static let projectColumnWidth: CGFloat = 80
    static let groupedProjectSpacerWidth: CGFloat = 4
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
        AgentCockpitHUDStatusDot(
            liveState: row.liveState,
            lastSeenAt: row.lastSeenAt
        )
        .accessibilityLabel(row.liveState == .active ? "Active" : "Idle")
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
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: AgentCockpitHUDRowLayout.projectColumnWidth, alignment: .leading)
            }

            highlightedText(sessionTitle)
                .font(.system(size: 13, weight: sessionTitleWeight, design: .monospaced))
                .foregroundStyle(.primary)
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
                    .frame(width: 64, alignment: .leading)
            }

            Text(sessionTitle)
                .font(.system(size: 13, weight: sessionTitleWeight, design: .monospaced))
                .foregroundStyle(.primary)
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

    private var elapsedColor: Color {
        colorScheme == .dark ? Color(hex: "6e6e73") : Color(hex: "8e8e93")
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
        Text(row.agentType.label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(badgeTextColor)
            .lineLimit(1)
    }

    private var badgeTextColor: Color {
        if isSelected { return .primary }
        if colorScheme == .light {
            switch row.agentType {
            case .codex:
                return Color(hex: "2b56b8")
            case .claude:
                return Color(hex: "b86a1d")
            case .shell:
                return Color(hex: "7a7a80")
            }
        }
        return row.agentType.standardTextColor
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

private struct AgentCockpitHUDStatusDot: View {
    let liveState: HUDLiveState
    let lastSeenAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: 7, height: 7)
            .scaleEffect(scale)
            .opacity(opacity)
            .shadow(color: haloColor.opacity(haloOpacity), radius: haloRadius)
            .onAppear { updateAnimation() }
            .onChange(of: liveState) { _, _ in updateAnimation() }
            .onChange(of: lastSeenAt) { _, _ in updateAnimation() }
            .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private var baseColor: Color {
        switch liveState {
        case .active:
            return Color(hex: "30d158")
        case .idle:
            return idleBaseColor
        }
    }

    private var idleBaseColor: Color {
        colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
    }

    private var shouldPulse: Bool {
        liveState == .idle && !reduceMotion
    }

    private var scale: CGFloat {
        guard shouldPulse else { return 1.0 }
        return animate ? 1.25 : 1.0
    }

    private var opacity: Double {
        guard shouldPulse else { return 1.0 }
        return animate ? 1.0 : 0.88
    }

    private var fillColor: Color {
        baseColor
    }

    private var haloColor: Color {
        idleBaseColor
    }

    private var haloOpacity: Double {
        guard liveState == .idle else { return 0 }
        guard shouldPulse else { return 0 }
        return animate ? 0.65 : 0.22
    }

    private var haloRadius: CGFloat {
        guard liveState == .idle else { return 0 }
        guard shouldPulse else { return 0 }
        return animate ? 4.8 : 3.2
    }

    private func updateAnimation() {
        guard shouldPulse else {
            animate = false
            return
        }
        animate = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            animate = true
        }
    }
}
