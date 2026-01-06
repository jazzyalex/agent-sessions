import SwiftUI
import AppKit
import Foundation
import AVFoundation

/// Terminal-style session view with filters, optional gutter, and legend toggles.
struct SessionTerminalView: View {
    let session: Session
    let findQuery: String
    let findToken: Int
    let findDirection: Int
    let findReset: Bool
    let jumpToken: Int
    let roleNavToken: Int
    let roleNavRole: RoleToggle
    let roleNavDirection: Int
    @Binding var externalMatchCount: Int
    @Binding var externalCurrentMatchIndex: Int
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var lines: [TerminalLine] = []
    @State private var visibleLines: [TerminalLine] = []
    @State private var rebuildTask: Task<Void, Never>?

    enum RoleToggle: CaseIterable {
        case user
        case assistant
        case tools
        case errors
    }

    @AppStorage("TerminalRoleToggles") private var roleToggleRaw: String = "user,assistant,tools,errors"
    @State private var activeRoles: Set<RoleToggle> = Set(RoleToggle.allCases)

    // Line identifiers for navigation
    @State private var userLineIndices: [Int] = []
    @State private var assistantLineIndices: [Int] = []
    @State private var toolLineIndices: [Int] = []
    @State private var errorLineIndices: [Int] = []
    @State private var roleNavPositions: [RoleToggle: Int] = [:]

    // Local find state
    @State private var matchingLineIDs: [Int] = []
    @State private var matchIDSet: Set<Int> = []
    @State private var currentMatchLineID: Int? = nil
    @State private var conversationStartLineID: Int? = nil
    @State private var scrollTargetLineID: Int? = nil
    @State private var scrollTargetToken: Int = 0
    @State private var preambleUserBlockIndexes: Set<Int> = []

    // Derived agent label for legend chips (Codex / Claude / Gemini)
    private var agentLegendLabel: String {
        switch session.source {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .copilot: return "Copilot"
        case .droid: return "Droid"
        }
    }

    private var filteredLines: [TerminalLine] {
        visibleLines
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.6 : 0.35))
                .frame(height: 1)
        }
        .onAppear {
            loadRoleToggles()
            rebuildLines(priority: .userInitiated)
        }
        .onDisappear {
            rebuildTask?.cancel()
            rebuildTask = nil
        }
        .onChange(of: jumpToken) { _, _ in
            jumpToFirstPrompt()
        }
        .onChange(of: session.id) { _, _ in
            rebuildLines(priority: .userInitiated)
        }
        .onChange(of: activeRoles) { _, _ in
            visibleLines = roleFilteredLines(from: lines)
        }
        .onChange(of: roleNavToken) { _, _ in
            // Keyboard navigation should reveal the target role even if the user filtered it off.
            if !activeRoles.contains(roleNavRole) {
                activeRoles.insert(roleNavRole)
                persistRoleToggles()
            }
            navigateRole(roleNavRole, direction: roleNavDirection)
        }
        .onChange(of: session.events.count) { _, _ in
            rebuildLines(priority: .utility, debounceNanoseconds: 150_000_000)
        }
    }

    private var toolbar: some View {
        HStack {
            // Left: All + role toggles (legend chips act as toggles)
            HStack(spacing: 16) {
                allFilterButton()
                legendToggle(label: "User", role: .user)
                legendToggle(label: agentLegendLabel, role: .assistant)
                legendToggle(label: "Tools", role: .tools)
                legendToggle(label: "Errors", role: .errors)
            }
            .foregroundStyle(.secondary)

            Spacer()

                if shouldShowConversationStartControls, let _ = conversationStartLineID {
                    Button(action: { jumpToFirstPrompt() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.to.line")
                                .imageScale(.small)
                            Text("First prompt")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .help("Jump to the first user prompt after the preamble")
                }
            }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var content: some View {
        GeometryReader { outerGeo in
            HStack(spacing: 8) {
                TerminalTextScrollView(
                    lines: filteredLines,
                    fontSize: CGFloat(transcriptFontSize),
                    matchIDs: matchIDSet,
                    currentMatchLineID: currentMatchLineID,
                    highlightActive: !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    scrollTargetLineID: scrollTargetLineID,
                    scrollTargetToken: scrollTargetToken,
                    preambleUserBlockIndexes: preambleUserBlockIndexes,
                    colorScheme: colorScheme,
                    monochrome: stripMonochrome
                )
                .onChange(of: findToken) { _, _ in
                    handleFindRequest()
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private struct RebuildResult: Sendable {
        let lines: [TerminalLine]
        let conversationStartLineID: Int?
        let preambleUserBlockIndexes: Set<Int>
        let userLineIndices: [Int]
        let assistantLineIndices: [Int]
        let toolLineIndices: [Int]
        let errorLineIndices: [Int]
    }

    private func rebuildLines(priority: TaskPriority, debounceNanoseconds: UInt64 = 0) {
        rebuildTask?.cancel()

        let sessionSnapshot = session
        let skipAgentsPreamble = skipAgentsPreambleEnabled()

        rebuildTask = Task(priority: priority) { @MainActor in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }

            let result = await Task.detached(priority: priority) {
                Self.buildRebuildResult(session: sessionSnapshot, skipAgentsPreamble: skipAgentsPreamble)
            }.value

            guard !Task.isCancelled else { return }

            lines = result.lines
            visibleLines = roleFilteredLines(from: result.lines)
            conversationStartLineID = result.conversationStartLineID
            preambleUserBlockIndexes = result.preambleUserBlockIndexes
            userLineIndices = result.userLineIndices
            assistantLineIndices = result.assistantLineIndices
            toolLineIndices = result.toolLineIndices
            errorLineIndices = result.errorLineIndices

            // Reset local find state when rebuilding.
            matchingLineIDs = []
            matchIDSet = []
            currentMatchLineID = nil
            roleNavPositions = [:]
            externalMatchCount = 0
            externalCurrentMatchIndex = 0

            if skipAgentsPreamble, findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                jumpToFirstPrompt()
            }
        }
    }

    private func roleFilteredLines(from lines: [TerminalLine]) -> [TerminalLine] {
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

    nonisolated private static func buildRebuildResult(session: Session, skipAgentsPreamble: Bool) -> RebuildResult {
        let built = TerminalBuilder.buildLines(for: session, showMeta: false)
        let (decorated, dividerID) = applyConversationStartDividerIfNeeded(session: session, lines: built, enabled: skipAgentsPreamble)
        let preambleUserBlockIndexes = computePreambleUserBlockIndexes(session: session)

        // Collapse multi-line blocks into single navigable/message entries per role.
        var firstLineForBlock: [Int: Int] = [:]       // blockIndex -> first line id
        var roleForBlock: [Int: TerminalLineRole] = [:]

        for line in decorated {
            guard let blockIndex = line.blockIndex else { continue }
            if firstLineForBlock[blockIndex] == nil {
                firstLineForBlock[blockIndex] = line.id
                roleForBlock[blockIndex] = line.role
            }
        }

        func messageIDs(for roleMatch: (TerminalLineRole) -> Bool) -> [Int] {
            firstLineForBlock.compactMap { blockIndex, lineID in
                guard let role = roleForBlock[blockIndex], roleMatch(role) else { return nil }
                return lineID
            }
            .sorted()
        }

        return RebuildResult(
            lines: decorated,
            conversationStartLineID: dividerID,
            preambleUserBlockIndexes: preambleUserBlockIndexes,
            userLineIndices: messageIDs { $0 == .user },
            assistantLineIndices: messageIDs { $0 == .assistant },
            toolLineIndices: messageIDs { role in role == .toolInput || role == .toolOutput },
            errorLineIndices: messageIDs { $0 == .error }
        )
    }

    nonisolated private static func computePreambleUserBlockIndexes(session: Session) -> Set<Int> {
        // Only style preamble differently for Codex + Droid, where the "system prompt" is commonly embedded
        // as a user-authored-looking block.
        guard session.source == .codex || session.source == .droid else { return [] }

        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        var out: Set<Int> = []
        out.reserveCapacity(4)
        for (idx, block) in blocks.enumerated() where block.kind == .user {
            if Session.isAgentsPreambleText(block.text) {
                out.insert(idx)
            }
        }
        return out
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

    private func allFilterButton() -> some View {
        let isActive = activeRoles.count == RoleToggle.allCases.count
        return Button(action: {
            activeRoles = Set(RoleToggle.allCases)
            persistRoleToggles()
        }) {
            Text("All")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func legendToggle(label: String, role: RoleToggle) -> some View {
        let isOn = activeRoles.contains(role)
        let swatch = TerminalRolePalette.swiftUI(role: TerminalRolePalette.role(for: role), scheme: colorScheme, monochrome: stripMonochrome)
        let indices = indicesForRole(role)
        let hasLines = !indices.isEmpty
        let navDisabled = !isOn || !hasLines
        let showCount = true
        let status = navigationStatus(for: role)
        let countText = "\(formattedCount(status.current))/\(formattedCount(status.total))"

        return HStack(spacing: 6) {
            Button(action: {
                if isOn {
                    activeRoles.remove(role)
                } else {
                    activeRoles.insert(role)
                }
                persistRoleToggles()
            }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(swatch.accent.opacity(isOn ? 1.0 : 0.35))
                        .frame(width: 9, height: 9)
                    Text(label)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isOn ? .primary : .secondary)
                    if showCount {
                        Text(countText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Button(action: { navigateRole(role, direction: -1) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(navDisabled ? Color.secondary.opacity(0.35) : Color.secondary)
                .disabled(navDisabled)
                .help(previousHelpText(for: role))

                Button(action: { navigateRole(role, direction: 1) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(navDisabled ? Color.secondary.opacity(0.35) : Color.secondary)
                .disabled(navDisabled)
                .help(nextHelpText(for: role))
            }
        }
    }

    private func formattedCount(_ count: Int) -> String {
        let clamped = min(max(count, 0), 999_999)
        let base = clamped.formatted(.number.grouping(.automatic))
        if count > 999_999 {
            return base + "+"
        }
        return base
    }

    private func navigationStatus(for role: RoleToggle) -> (current: Int, total: Int) {
        let ids = indicesForRole(role)
        let total = ids.count
        guard total > 0 else { return (0, 0) }
        let sorted = ids.sorted()

        if let stored = roleNavPositions[role], stored >= 0, stored < total {
            return (stored + 1, total)
        }

        if let currentID = currentMatchLineID, let pos = sorted.firstIndex(of: currentID) {
            return (pos + 1, total)
        }

        return (0, total)
    }

    private func indicesForRole(_ role: RoleToggle) -> [Int] {
        switch role {
        case .user:
            return userLineIndices
        case .assistant:
            return assistantLineIndices
        case .tools:
            return toolLineIndices
        case .errors:
            return errorLineIndices
        }
    }

    private func previousHelpText(for role: RoleToggle) -> String {
        switch role {
        case .user: return "Previous user prompt (⌥⌘↑)"
        case .assistant: return "Previous agent response"
        case .tools: return "Previous tool call/output (⌥⌘←)"
        case .errors: return "Previous error (⌥⌘⇧↑)"
        }
    }

    private func nextHelpText(for role: RoleToggle) -> String {
        switch role {
        case .user: return "Next user prompt (⌥⌘↓)"
        case .assistant: return "Next agent response"
        case .tools: return "Next tool call/output (⌥⌘→)"
        case .errors: return "Next error (⌥⌘⇧↓)"
        }
    }

    private func navigateRole(_ role: RoleToggle, direction: Int) {
        guard activeRoles.contains(role) else { return }
        let ids = indicesForRole(role)
        guard !ids.isEmpty else { return }

        let sorted = ids.sorted()
        let step = direction >= 0 ? 1 : -1
        let count = sorted.count

        func wrapIndex(_ value: Int) -> Int {
            (value % count + count) % count
        }

        let startIndex: Int
        if let stored = roleNavPositions[role], stored >= 0, stored < count {
            startIndex = stored
        } else if let currentID = currentMatchLineID, let pos = sorted.firstIndex(of: currentID) {
            startIndex = pos
        } else {
            startIndex = direction >= 0 ? 0 : (count - 1)
        }

        let nextIndex = wrapIndex(startIndex + step)
        roleNavPositions[role] = nextIndex
        currentMatchLineID = sorted[nextIndex]
    }

    /// Execute a find request driven by the unified toolbar.
    private func handleFindRequest() {
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
        var ids: [Int] = []
        for line in filteredLines {
            if line.text.range(of: query, options: [.caseInsensitive]) != nil {
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
    }

    private var shouldShowConversationStartControls: Bool {
        skipAgentsPreambleEnabled() && (conversationStartLineID != nil)
    }

    private func skipAgentsPreambleEnabled() -> Bool {
        let d = UserDefaults.standard
        let key = PreferencesKey.Unified.skipAgentsPreamble
        if d.object(forKey: key) == nil { return true }
        return d.bool(forKey: key)
    }

    private func jumpToFirstPrompt() {
        guard let target = conversationStartLineID else { return }
        scrollTargetLineID = target
        scrollTargetToken &+= 1
    }

    nonisolated private static func applyConversationStartDividerIfNeeded(session: Session, lines: [TerminalLine], enabled: Bool) -> ([TerminalLine], Int?) {
        guard enabled else { return (lines, nil) }

        // Droid: system reminders can be embedded in the first user message but should be hidden by default.
        // When present, insert the divider above the first real user prompt while keeping the preamble
        // visible above (Codex-style: auto-jump, but you can scroll up).
        if session.source == .droid {
            func firstNonEmptyLine(_ text: String) -> String? {
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let t = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
                return nil
            }

            var sawPreamble = false
            var promptLine: String? = nil
            for ev in session.events where ev.kind == .user {
                guard let raw = ev.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
                if Session.isAgentsPreambleText(raw) {
                    sawPreamble = true
                    continue
                }
                guard sawPreamble else { break }
                promptLine = firstNonEmptyLine(raw)
                break
            }
            if let promptLine {
                if let insertAt = lines.firstIndex(where: { $0.role == .user && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == promptLine }) {
                    return insertConversationStartDivider(lines: lines, insertAt: insertAt)
                }
            }
        }

        let marker = "</INSTRUCTIONS>"
        guard let closeIndex = lines.firstIndex(where: { $0.text.contains(marker) }) else {
            guard let insertAt = claudeConversationStartLineIndexIfNeeded(lines: lines) else { return (lines, nil) }
            return insertConversationStartDivider(lines: lines, insertAt: insertAt)
        }
        // Find first non-empty user line after the closing marker.
        var promptIndex: Int? = nil
        var i = closeIndex + 1
        while i < lines.count {
            let line = lines[i]
            if line.role == .user {
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !trimmed.contains(marker) {
                    promptIndex = i
                    break
                }
            }
            i += 1
        }
        guard let insertAt = promptIndex else { return (lines, nil) }
        return insertConversationStartDivider(lines: lines, insertAt: insertAt)
    }

    nonisolated private static func insertConversationStartDivider(lines: [TerminalLine], insertAt: Int) -> ([TerminalLine], Int?) {
        // Avoid double insertion.
        if lines.contains(where: { $0.role == .meta && $0.text.contains("Conversation starts here") }) {
            return (lines, insertAt)
        }

        var out: [TerminalLine] = []
        out.reserveCapacity(lines.count + 1)
        for (idx, line) in lines.enumerated() {
            if idx == insertAt {
                out.append(TerminalLine(
                    id: -1,
                    text: "──────── Conversation starts here ────────",
                    role: .meta,
                    eventIndex: nil,
                    blockIndex: nil
                ))
            }
            out.append(line)
        }
        // Reindex IDs to remain stable/incremental.
        out = out.enumerated().map { newIdx, line in
            TerminalLine(
                id: newIdx,
                text: line.text,
                role: line.role,
                eventIndex: line.eventIndex,
                blockIndex: line.blockIndex
            )
        }

        // Divider line is at insertAt after reindex.
        return (out, insertAt)
    }

    nonisolated private static func claudeConversationStartLineIndexIfNeeded(lines: [TerminalLine]) -> Int? {
        // Claude Code sometimes prefixes sessions with a "Caveat + local command transcript" block.
        // When present, jump to the first real prompt line (not the caveat or XML-like tags).
        let anchor = "caveat: the messages below were generated by the user while running local commands"
        let hasCaveat = lines.prefix(120).contains(where: { $0.role == .user && $0.text.lowercased().contains(anchor) })
        guard hasCaveat else { return nil }

        for (idx, line) in lines.enumerated() where line.role == .user {
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let lower = t.lowercased()
            if lower.hasPrefix("caveat:") { continue }
            if lower.contains("<command-name>") || lower.contains("<command-message>") || lower.contains("<command-args>") { continue }
            if lower.contains("<local-command-stdout") { continue }
            if t.hasPrefix("<") { continue }
            return idx
        }
        return nil
    }
}

// MARK: - Line view

private struct TerminalLineView: View {
    let line: TerminalLine
    let isMatch: Bool
    let isCurrentMatch: Bool
    let fontSize: Double
    let monochrome: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            prefixView
            Text(line.text)
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .foregroundColor(swatch.foreground)
        }
        .textSelection(.enabled)
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
                .foregroundColor(swatch.accent)
                .allowsHitTesting(false)
        case .toolInput:
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundColor(swatch.accent)
                .allowsHitTesting(false)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundColor(swatch.accent)
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    private var background: Color {
        if isCurrentMatch {
            return Color.yellow.opacity(0.5)
        } else if isMatch {
            return (swatch.background ?? swatch.accent.opacity(0.22)).opacity(0.95)
        } else {
            return swatch.background ?? Color.clear
        }
    }

    private var swatch: TerminalRolePalette.SwiftUISwatch {
        TerminalRolePalette.swiftUI(role: line.role.paletteRole, scheme: colorScheme, monochrome: monochrome)
    }
}

// MARK: - Button Styles

// MARK: - NSTextView-backed selectable terminal renderer

private struct TerminalRolePalette {
    enum Role {
        case user
        case assistant
        case toolInput
        case toolOutput
        case error
        case meta
    }

    struct SwiftUISwatch {
        let foreground: Color
        let background: Color?
        let accent: Color
    }

    struct AppKitSwatch {
        let foreground: NSColor
        let background: NSColor?
        let accent: NSColor
    }

    static func role(for toggle: SessionTerminalView.RoleToggle) -> Role {
        switch toggle {
        case .user: return .user
        case .assistant: return .assistant
        // Tools toggle includes both input/output; use tool input as the representative swatch.
        case .tools: return .toolInput
        case .errors: return .error
        }
    }

    static func swiftUI(role: Role, scheme: ColorScheme, monochrome: Bool = false) -> SwiftUISwatch {
        let appKitColors = baseColors(for: role, scheme: scheme, monochrome: monochrome)
        return SwiftUISwatch(
            foreground: Color(nsColor: appKitColors.foreground),
            background: appKitColors.background.map { Color(nsColor: $0) },
            accent: Color(nsColor: appKitColors.accent)
        )
    }

    static func appKit(role: Role, scheme: ColorScheme, monochrome: Bool = false) -> AppKitSwatch {
        baseColors(for: role, scheme: scheme, monochrome: monochrome)
    }

    private static func baseColors(for role: Role, scheme: ColorScheme, monochrome: Bool) -> AppKitSwatch {
        let isDark = (scheme == .dark)

        func tinted(_ color: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
            color.withAlphaComponent(isDark ? dark : light)
        }

        if monochrome {
            // Monochrome mode: use gray shades
            switch role {
            case .user:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: NSColor(white: 0.5, alpha: isDark ? 0.20 : 0.12),
                    accent: NSColor(white: 0.5, alpha: 1.0)
                )
            case .assistant:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: NSColor(white: 0.4, alpha: isDark ? 0.18 : 0.10),
                    accent: NSColor(white: 0.4, alpha: 1.0)
                )
            case .toolInput:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: NSColor(white: 0.6, alpha: isDark ? 0.22 : 0.14),
                    accent: NSColor(white: 0.6, alpha: 1.0)
                )
            case .toolOutput:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: NSColor(white: 0.6, alpha: isDark ? 0.22 : 0.14),
                    accent: NSColor(white: 0.6, alpha: 1.0)
                )
            case .error:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: NSColor(white: 0.3, alpha: isDark ? 0.30 : 0.20),
                    accent: NSColor(white: 0.3, alpha: 1.0)
                )
            case .meta:
                return AppKitSwatch(
                    foreground: NSColor.secondaryLabelColor,
                    background: nil,
                    accent: NSColor.secondaryLabelColor
                )
            }
        } else {
            // Color mode: high-contrast palette tuned for scanning in both dark/light modes.
            switch role {
            case .user:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(NSColor.systemBlue, light: 0.20, dark: 0.25),
                    accent: NSColor.systemBlue
                )
            case .assistant:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(NSColor.systemGreen, light: 0.08, dark: 0.12),
                    accent: NSColor.systemGreen
                )
            case .toolInput:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(NSColor.systemPurple, light: 0.16, dark: 0.18),
                    accent: NSColor.systemPurple
                )
            case .toolOutput:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(NSColor.systemTeal, light: 0.16, dark: 0.18),
                    accent: NSColor.systemTeal
                )
            case .error:
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(NSColor.systemRed, light: 0.28, dark: 0.40),
                    accent: NSColor.systemRed
                )
            case .meta:
                return AppKitSwatch(
                    foreground: NSColor.secondaryLabelColor,
                    background: nil,
                    accent: NSColor.secondaryLabelColor
                )
            }
        }
    }
}

private extension TerminalLineRole {
    var paletteRole: TerminalRolePalette.Role {
        switch self {
        case .user: return .user
        case .assistant: return .assistant
        case .toolInput: return .toolInput
        case .toolOutput: return .toolOutput
        case .error: return .error
        case .meta: return .meta
        }
    }

    var signatureToken: Int {
        switch self {
        case .user: return 1
        case .assistant: return 2
        case .toolInput: return 3
        case .toolOutput: return 4
        case .error: return 5
        case .meta: return 6
        }
    }
}

private struct TerminalTextScrollView: NSViewRepresentable {
    let lines: [TerminalLine]
    let fontSize: CGFloat
    let matchIDs: Set<Int>
    let currentMatchLineID: Int?
    let highlightActive: Bool
    let scrollTargetLineID: Int?
    let scrollTargetToken: Int
    let preambleUserBlockIndexes: Set<Int>
    let colorScheme: ColorScheme
    let monochrome: Bool

    final class Coordinator: NSObject, NSTextViewDelegate, AVSpeechSynthesizerDelegate {
        var lineRanges: [Int: NSRange] = [:]
        var lineRoles: [Int: TerminalLineRole] = [:]
        var lastLinesSignature: Int = 0
        var lastFontSize: CGFloat = 0
        var lastMonochrome: Bool = false
        var lastColorScheme: ColorScheme = .light
        var lastScrollToken: Int = 0

        var lastMatchIDs: Set<Int> = []
        var lastCurrentMatchLineID: Int? = nil

        var lines: [TerminalLine] = []
        var orderedLineRanges: [NSRange] = []

        private weak var activeTextView: NSTextView?
        private var activeBlockText: String = ""
        private let speechSynthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()
        private let speechQueue = DispatchQueue(label: "com.agentsessions.speechSynthesizer", qos: .default)
        private var isSpeaking: Bool = false

        override init() {
            super.init()
            speechSynthesizer.delegate = self
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange, toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
            guard let event = NSApp.currentEvent else { return newSelectedCharRange }
            let isContextClick =
                event.type == .rightMouseDown ||
                event.type == .rightMouseUp ||
                event.type == .otherMouseDown ||
                event.type == .otherMouseUp ||
                (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) ||
                (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
            if isContextClick {
                return oldSelectedCharRange
            }
            return newSelectedCharRange
        }

        func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            self.activeTextView = textView
            self.activeBlockText = blockText(at: charIndex) ?? ""

            let out = NSMenu(title: "Transcript")
            out.autoenablesItems = false

            let hasSelection = textView.selectedRange().length > 0
            let copySelection = NSMenuItem(title: "Copy", action: hasSelection ? #selector(copySelectionOnly(_:)) : nil, keyEquivalent: "")
            copySelection.target = hasSelection ? self : nil
            copySelection.isEnabled = hasSelection
            out.addItem(copySelection)

            let copyBlock = NSMenuItem(title: "Copy Block", action: #selector(copyBlock(_:)), keyEquivalent: "")
            copyBlock.target = self
            copyBlock.isEnabled = !activeBlockText.isEmpty
            out.addItem(copyBlock)

            out.addItem(.separator())

            let speak = NSMenuItem(title: "Speak", action: #selector(speakSelectionOrBlock(_:)), keyEquivalent: "")
            speak.target = self
            speak.isEnabled = textView.selectedRange().length > 0 || !activeBlockText.isEmpty
            out.addItem(speak)

            let stop = NSMenuItem(title: "Stop Speaking", action: #selector(stopSpeaking(_:)), keyEquivalent: "")
            stop.target = self
            stop.isEnabled = isSpeaking
            out.addItem(stop)

            return out
        }

        @objc private func copySelectionOnly(_ sender: Any?) {
            guard let tv = activeTextView else { return }
            guard tv.selectedRange().length > 0 else { return }
            tv.copy(sender)
        }

        @objc private func copyBlock(_ sender: Any?) {
            guard !activeBlockText.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(activeBlockText, forType: .string)
        }

        @objc private func speakSelectionOrBlock(_ sender: Any?) {
            guard let tv = activeTextView else { return }
            let selection = tv.selectedRange()
            let text: String = {
                if selection.length > 0 {
                    return (tv.string as NSString).substring(with: selection)
                }
                return activeBlockText
            }()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier) ?? AVSpeechSynthesisVoice()
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.volume = 1.0
            speechQueue.async { [weak self] in
                guard let self else { return }
                if self.speechSynthesizer.isSpeaking {
                    self.speechSynthesizer.stopSpeaking(at: .immediate)
                }
                self.speechSynthesizer.speak(utterance)
            }
        }

        @objc private func stopSpeaking(_ sender: Any?) {
            speechQueue.async { [weak self] in
                self?.speechSynthesizer.stopSpeaking(at: .immediate)
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = true
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = false
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = false
            }
        }

        private func blockText(at charIndex: Int) -> String? {
            guard !lines.isEmpty else { return nil }
            guard let lineIndex = lineIndex(at: charIndex) else { return nil }
            let block = lines[lineIndex].blockIndex

            var start = lineIndex
            while start > 0, lines[start - 1].blockIndex == block {
                start -= 1
            }
            var end = lineIndex
            while end + 1 < lines.count, lines[end + 1].blockIndex == block {
                end += 1
            }

            let chunk = lines[start...end].map(\.text).joined(separator: "\n")
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func lineIndex(at charIndex: Int) -> Int? {
            let ranges = orderedLineRanges
            guard !ranges.isEmpty else { return nil }

            var low = 0
            var high = ranges.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let r = ranges[mid]
                if charIndex < r.location {
                    high = mid - 1
                    continue
                }
                if charIndex >= (r.location + r.length) {
                    low = mid + 1
                    continue
                }
                return mid
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private var effectiveMatchIDs: Set<Int> {
        highlightActive ? matchIDs : []
    }

    private var effectiveCurrentMatchLineID: Int? {
        highlightActive ? currentMatchLineID : nil
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindPanel = true
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.autoresizingMask = [.width]
        textView.textContainer?.lineFragmentPadding = 0
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.backgroundColor = NSColor.textBackgroundColor

        scroll.documentView = textView

        applyContent(to: textView, context: context)
        context.coordinator.lastLinesSignature = signature(for: lines)
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastMonochrome = monochrome
        context.coordinator.lastColorScheme = colorScheme
        context.coordinator.lastMatchIDs = effectiveMatchIDs
        context.coordinator.lastCurrentMatchLineID = effectiveCurrentMatchLineID
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }

        let lineSig = signature(for: lines)
        let fontChanged = abs((context.coordinator.lastFontSize) - fontSize) > 0.1
        let monochromeChanged = context.coordinator.lastMonochrome != monochrome
        let schemeChanged = context.coordinator.lastColorScheme != colorScheme
        let needsReload = lineSig != context.coordinator.lastLinesSignature || fontChanged || monochromeChanged || schemeChanged

        if needsReload {
            applyContent(to: tv, context: context)
            context.coordinator.lastLinesSignature = lineSig
            context.coordinator.lastFontSize = fontSize
            context.coordinator.lastMonochrome = monochrome
            context.coordinator.lastColorScheme = colorScheme
        } else if context.coordinator.lastMatchIDs != effectiveMatchIDs || context.coordinator.lastCurrentMatchLineID != effectiveCurrentMatchLineID {
            updateHighlights(in: tv, context: context, matches: effectiveMatchIDs, currentLineID: effectiveCurrentMatchLineID)
        }

        if let target = currentMatchLineID, let range = context.coordinator.lineRanges[target] {
            tv.scrollRangeToVisible(range)
        }

        if scrollTargetToken != context.coordinator.lastScrollToken,
           let target = scrollTargetLineID,
           let range = context.coordinator.lineRanges[target] {
            scrollRangeToTop(tv, range: range)
            context.coordinator.lastScrollToken = scrollTargetToken
        }
    }

    private func scrollRangeToTop(_ tv: NSTextView, range: NSRange) {
        guard let scrollView = tv.enclosingScrollView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else {
            tv.scrollRangeToVisible(range)
            return
        }

        lm.ensureLayout(for: tc)
        let glyph = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyph, in: tc)
        let origin = tv.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y

        let padding = max(0, tv.textContainerInset.height)
        let y = max(0, rect.minY - padding)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyContent(to textView: NSTextView, context: Context) {
        let (attr, ranges) = buildAttributedString(matches: effectiveMatchIDs, currentLineID: effectiveCurrentMatchLineID)
        context.coordinator.lineRanges = ranges
        context.coordinator.lineRoles = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.role) })
        context.coordinator.lines = lines
        context.coordinator.orderedLineRanges = lines.compactMap { ranges[$0.id] }
        context.coordinator.lastMatchIDs = effectiveMatchIDs
        context.coordinator.lastCurrentMatchLineID = effectiveCurrentMatchLineID
        textView.textStorage?.setAttributedString(attr)

        // Ensure container tracks width
        let width = max(1, textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }

    private func updateHighlights(in textView: NSTextView, context: Context, matches: Set<Int>, currentLineID: Int?) {
        let oldMatches = context.coordinator.lastMatchIDs
        let newMatches = matches
        let oldCurrent = context.coordinator.lastCurrentMatchLineID
        let newCurrent = currentLineID

        var affected = oldMatches.symmetricDifference(newMatches)
        if let oldCurrent { affected.insert(oldCurrent) }
        if let newCurrent { affected.insert(newCurrent) }
        guard !affected.isEmpty else { return }

        let currentHighlight = NSColor.systemYellow.withAlphaComponent(0.5)
        let matchHighlight = NSColor.systemYellow.withAlphaComponent(0.25)

        let userSwatch = TerminalRolePalette.appKit(role: .user, scheme: colorScheme, monochrome: monochrome)
        let assistantSwatch = TerminalRolePalette.appKit(role: .assistant, scheme: colorScheme, monochrome: monochrome)
        let toolInputSwatch = TerminalRolePalette.appKit(role: .toolInput, scheme: colorScheme, monochrome: monochrome)
        let toolOutputSwatch = TerminalRolePalette.appKit(role: .toolOutput, scheme: colorScheme, monochrome: monochrome)
        let errorSwatch = TerminalRolePalette.appKit(role: .error, scheme: colorScheme, monochrome: monochrome)
        let metaSwatch = TerminalRolePalette.appKit(role: .meta, scheme: colorScheme, monochrome: monochrome)

        func swatch(for role: TerminalLineRole) -> TerminalRolePalette.AppKitSwatch {
            switch role {
            case .user: return userSwatch
            case .assistant: return assistantSwatch
            case .toolInput: return toolInputSwatch
            case .toolOutput: return toolOutputSwatch
            case .error: return errorSwatch
            case .meta: return metaSwatch
            }
        }

        for lineID in affected {
            guard let range = context.coordinator.lineRanges[lineID] else { continue }
            guard let role = context.coordinator.lineRoles[lineID] else { continue }
            let baseBackground = swatch(for: role).background

            if lineID == newCurrent {
                textView.textStorage?.addAttribute(.backgroundColor, value: currentHighlight, range: range)
            } else if newMatches.contains(lineID) {
                textView.textStorage?.addAttribute(.backgroundColor, value: matchHighlight, range: range)
            } else if let bg = baseBackground {
                textView.textStorage?.addAttribute(.backgroundColor, value: bg, range: range)
            } else {
                textView.textStorage?.removeAttribute(.backgroundColor, range: range)
            }
        }

        context.coordinator.lastMatchIDs = newMatches
        context.coordinator.lastCurrentMatchLineID = newCurrent
    }

    private func buildAttributedString(matches: Set<Int>, currentLineID: Int?) -> (NSAttributedString, [Int: NSRange]) {
        let attr = NSMutableAttributedString()
        var ranges: [Int: NSRange] = [:]
        ranges.reserveCapacity(lines.count)

        let regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let currentHighlight = NSColor.systemYellow.withAlphaComponent(0.5)
        let matchHighlight = NSColor.systemYellow.withAlphaComponent(0.25)

        let userSwatch = TerminalRolePalette.appKit(role: .user, scheme: colorScheme, monochrome: monochrome)
        let assistantSwatch = TerminalRolePalette.appKit(role: .assistant, scheme: colorScheme, monochrome: monochrome)
        let toolInputSwatch = TerminalRolePalette.appKit(role: .toolInput, scheme: colorScheme, monochrome: monochrome)
        let toolOutputSwatch = TerminalRolePalette.appKit(role: .toolOutput, scheme: colorScheme, monochrome: monochrome)
        let errorSwatch = TerminalRolePalette.appKit(role: .error, scheme: colorScheme, monochrome: monochrome)
        let metaSwatch = TerminalRolePalette.appKit(role: .meta, scheme: colorScheme, monochrome: monochrome)

        func swatch(for role: TerminalLineRole) -> TerminalRolePalette.AppKitSwatch {
            switch role {
            case .user: return userSwatch
            case .assistant: return assistantSwatch
            case .toolInput: return toolInputSwatch
            case .toolOutput: return toolOutputSwatch
            case .error: return errorSwatch
            case .meta: return metaSwatch
            }
        }

        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineSpacing = 1.5
        baseParagraph.paragraphSpacing = 0
        baseParagraph.lineBreakMode = .byWordWrapping

        func paragraph(spacingBefore: CGFloat) -> NSParagraphStyle {
            let p = (baseParagraph.mutableCopy() as? NSMutableParagraphStyle) ?? baseParagraph
            p.paragraphSpacingBefore = spacingBefore
            return p
        }

        let paragraph0 = paragraph(spacingBefore: 0)
        let paragraph8 = paragraph(spacingBefore: 8)
        let paragraph10 = paragraph(spacingBefore: 10)
        let paragraph14 = paragraph(spacingBefore: 14)

        var previousBlockIndex: Int? = nil

        for (idx, line) in lines.enumerated() {
            let text = line.text
            let lineString = idx == lines.count - 1 ? text : text + "\n"
            let ns = lineString as NSString
            let range = NSRange(location: attr.length, length: ns.length)
            ranges[line.id] = range

            let isNewBlock = idx > 0 && previousBlockIndex != line.blockIndex
            previousBlockIndex = line.blockIndex

            let paragraphStyle: NSParagraphStyle = {
                guard isNewBlock else { return paragraph0 }
                switch line.role {
                case .user:
                    return paragraph14
                case .assistant:
                    return paragraph8
                case .toolInput, .toolOutput, .error, .meta:
                    return paragraph10
                }
            }()

            let isPreambleUserLine: Bool = {
                guard line.role == .user else { return false }
                guard let blockIndex = line.blockIndex else { return false }
                return preambleUserBlockIndexes.contains(blockIndex)
            }()

            let isCurrent = (line.id == currentLineID)
            let isMatch = matches.contains(line.id)
            let lineSwatch = swatch(for: line.role)

            var attributes: [NSAttributedString.Key: Any] = [
                .font: (line.role == .user && !isPreambleUserLine) ? boldFont : regularFont,
                .foregroundColor: lineSwatch.foreground,
                .paragraphStyle: paragraphStyle
            ]

            if isCurrent {
                attributes[.backgroundColor] = currentHighlight
            } else if isMatch {
                attributes[.backgroundColor] = matchHighlight
            } else if let bg = lineSwatch.background {
                attributes[.backgroundColor] = bg
            }

            attr.append(NSAttributedString(string: lineString, attributes: attributes))
        }

        return (attr, ranges)
    }

    private func signature(for lines: [TerminalLine]) -> Int {
        var hasher = Hasher()
        hasher.combine(lines.count)

        func combine(_ line: TerminalLine) {
            hasher.combine(line.id)
            hasher.combine(line.role.signatureToken)
            hasher.combine(line.text.count)
        }

        if let first = lines.first { combine(first) }
        if let last = lines.last { combine(last) }
        if lines.count >= 3 { combine(lines[lines.count / 2]) }
        if lines.count >= 9 {
            combine(lines[lines.count / 4])
            combine(lines[(lines.count * 3) / 4])
        }
        return hasher.finalize()
    }
}
