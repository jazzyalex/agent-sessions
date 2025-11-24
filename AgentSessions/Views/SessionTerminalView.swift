import SwiftUI

/// Terminal-style session view with filters, optional gutter, and legend toggles.
struct SessionTerminalView: View {
    let session: Session
    let findQuery: String
    let findToken: Int
    let findDirection: Int
    let findReset: Bool
    @Binding var externalMatchCount: Int
    @Binding var externalCurrentMatchIndex: Int
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13

    @State private var lines: [TerminalLine] = []

    enum RoleToggle: CaseIterable {
        case user
        case assistant
        case tools
        case errors
    }

    @AppStorage("TerminalRoleToggles") private var roleToggleRaw: String = "user,assistant,tools,errors"
    @State private var activeRoles: Set<RoleToggle> = Set(RoleToggle.allCases)

    // Line indices for navigation
    @State private var userLineIndices: [Int] = []
    @State private var toolLineIndices: [Int] = []
    @State private var errorLineIndices: [Int] = []

    // Local find state
    @State private var matchingLineIDs: [Int] = []
    @State private var matchIDSet: Set<Int> = []
    @State private var currentMatchLineID: Int? = nil

    // Derived agent label for legend chips (Codex / Claude / Gemini)
    private var agentLegendLabel: String {
        switch session.source {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    private var filteredLines: [TerminalLine] {
        guard !activeRoles.isEmpty else { return lines }
        return lines.filter { line in
            switch line.role {
            case .user:
                return activeRoles.contains(.user)
            case .assistant:
                return activeRoles.contains(.assistant)
            case .toolInput, .toolOutput:
                return activeRoles.contains(.tools)
            case .error:
                return activeRoles.contains(.errors)
            case .meta:
                return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear {
            loadRoleToggles()
            rebuildLines()
        }
        .onChange(of: session.events.count) { _, _ in
            rebuildLines()
        }
    }

    private var toolbar: some View {
        HStack {
            // Left: All + role toggles (legend chips act as toggles)
            HStack(spacing: 6) {
                Button(action: {
                    activeRoles = Set(RoleToggle.allCases)
                    persistRoleToggles()
                }) {
                    Text("All")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(activeRoles.count == RoleToggle.allCases.count ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                }
                .buttonStyle(.borderless)

                legendToggle(color: .blue, label: "User", role: .user)
                legendToggle(color: .green, label: agentLegendLabel, role: .assistant)
                legendToggle(color: .teal, label: "Tools", role: .tools)
                legendToggle(color: .red, label: "Errors", role: .errors)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var content: some View {
        GeometryReader { outerGeo in
            HStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(filteredLines) { line in
                                TerminalLineView(
                                    line: line,
                                    isMatch: matchIDSet.contains(line.id),
                                    isCurrentMatch: currentMatchLineID == line.id,
                                    fontSize: transcriptFontSize
                                )
                                .id(line.id)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .onChange(of: currentMatchLineID) { _, newValue in
                        guard let id = newValue else { return }
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }

        // Respond to toolbar-driven find requests.
        .onChange(of: findToken) { _, _ in
            handleFindRequest(proxy: proxy)
        }
    }
            }
            .padding(.horizontal, 8)
        }
    }

    private func rebuildLines() {
        let built = TerminalBuilder.buildLines(for: session, showMeta: false)
        lines = built

        userLineIndices = built.enumerated().compactMap { idx, line in
            line.role == .user ? idx : nil
        }
        toolLineIndices = built.enumerated().compactMap { idx, line in
            (line.role == .toolInput || line.role == .toolOutput) ? idx : nil
        }
        errorLineIndices = built.enumerated().compactMap { idx, line in
            line.role == .error ? idx : nil
        }

        // Reset local find state when rebuilding.
        matchingLineIDs = []
        matchIDSet = []
        currentMatchLineID = nil
    }

    private func loadRoleToggles() {
        let parts = roleToggleRaw.split(separator: ",").map { String($0) }
        var roles: Set<RoleToggle> = []
        for p in parts {
            switch p {
            case "user": roles.insert(.user)
            case "assistant": roles.insert(.assistant)
            case "tools": roles.insert(.tools)
            case "errors": roles.insert(.errors)
            default: break
            }
        }
        if roles.isEmpty { roles = Set(RoleToggle.allCases) }
        activeRoles = roles
    }

    private func persistRoleToggles() {
        let parts = activeRoles.map { role -> String in
            switch role {
            case .user: return "user"
            case .assistant: return "assistant"
            case .tools: return "tools"
            case .errors: return "errors"
            }
        }
        roleToggleRaw = parts.joined(separator: ",")
    }

    private func legendToggle(color: Color, label: String, role: RoleToggle) -> some View {
        let isOn = activeRoles.contains(role)
        return Button(action: {
            if isOn {
                activeRoles.remove(role)
            } else {
                activeRoles.insert(role)
            }
            persistRoleToggles()
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color.opacity(isOn ? 1.0 : 0.3))
                    .frame(width: 8, height: 8)
                Text(label)
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isOn ? color.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.borderless)
    }

    /// Execute a find request driven by the unified toolbar.
    private func handleFindRequest(proxy: ScrollViewProxy) {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matchingLineIDs = []
            matchIDSet = []
            currentMatchLineID = nil
            externalMatchCount = 0
            externalCurrentMatchIndex = 0
            return
        }

        // Recompute matches over the currently filtered lines.
        let lowerQuery = query.lowercased()
        var ids: [Int] = []
        for line in filteredLines {
            if line.text.range(of: lowerQuery, options: [.caseInsensitive]) != nil {
                ids.append(line.id)
            }
        }
        matchingLineIDs = ids
        matchIDSet = Set(ids)
        externalMatchCount = ids.count

        guard !ids.isEmpty else {
            currentMatchLineID = nil
            externalCurrentMatchIndex = 0
            return
        }

        // Determine which match to select.
        if findReset {
            externalCurrentMatchIndex = 0
        } else {
            var nextIndex = externalCurrentMatchIndex + (findDirection >= 0 ? 1 : -1)
            if nextIndex < 0 {
                nextIndex = ids.count - 1
            } else if nextIndex >= ids.count {
                nextIndex = 0
            }
            externalCurrentMatchIndex = nextIndex
        }

        let clampedIndex = min(max(externalCurrentMatchIndex, 0), ids.count - 1)
        let lineID = ids[clampedIndex]
        currentMatchLineID = lineID

        withAnimation {
            proxy.scrollTo(lineID, anchor: .center)
        }
    }

    private func scrollToApproximateLine(at ratio: Double,
                                         allLines: [TerminalLine],
                                         filteredLines: [TerminalLine],
                                         proxy: ScrollViewProxy) {
        guard !allLines.isEmpty else { return }
        guard !filteredLines.isEmpty else { return }

        let clampedRatio = min(max(ratio, 0), 1)
        let targetGlobalIndex = Int(clampedRatio * Double(allLines.count - 1))

        // Map the global index to the nearest visible filtered line.
        let targetLine: TerminalLine
        if let match = filteredLines.first(where: { $0.id >= targetGlobalIndex }) {
            targetLine = match
        } else if let last = filteredLines.last {
            targetLine = last
        } else {
            return
        }

        withAnimation {
            proxy.scrollTo(targetLine.id, anchor: .top)
        }
    }
}

// MARK: - Line view

private struct TerminalLineView: View {
    let line: TerminalLine
    let isMatch: Bool
    let isCurrentMatch: Bool
    let fontSize: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            prefixView
            Text(line.text)
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .foregroundColor(foregroundColor)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(background)
        .cornerRadius(4)
    }

    @ViewBuilder
    private var prefixView: some View {
        switch line.role {
        case .user:
            Text(">")
                .foregroundColor(.blue.opacity(0.7))
        case .toolInput:
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundColor(.teal.opacity(0.8))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundColor(.red.opacity(0.9))
        default:
            EmptyView()
        }
    }

    private var background: Color {
        var base: Color
        switch line.role {
        case .user:
            base = Color.blue.opacity(0.18)
        case .assistant:
            base = Color.green.opacity(0.18)
        case .toolInput:
            base = Color.indigo.opacity(0.24)
        case .toolOutput:
            base = Color.green.opacity(0.16)
        case .error:
            base = Color.red.opacity(0.55)
        case .meta:
            base = .clear
        }

        if isCurrentMatch {
            return Color.yellow.opacity(0.5)
        } else if isMatch {
            return base.opacity(0.9)
        } else {
            return base
        }
    }

    private var foregroundColor: Color {
        switch line.role {
        case .meta:
            return .secondary
        default:
            return .primary
        }
    }
}
