import SwiftUI
import AppKit
import Foundation
import AVFoundation

private struct MatchOccurrence: Equatable {
    let range: NSRange
    let lineID: Int
}

private struct TextSnapshot {
    let text: String
    let lineRanges: [Int: NSRange]
    let orderedLineRanges: [NSRange]
    let orderedLineIDs: [Int]

    static let empty = TextSnapshot(text: "", lineRanges: [:], orderedLineRanges: [], orderedLineIDs: [])
}

/// Terminal-style session view with filters, optional gutter, and legend toggles.
struct SessionTerminalView: View {
    let session: Session
    // Unified Search (⌥⌘F): shared query from the sessions list, used for in-transcript navigation/highlights.
    let unifiedQuery: String
    let unifiedFindToken: Int
    let unifiedFindDirection: Int
    let unifiedFindReset: Bool
    let unifiedAllowMatchAutoScroll: Bool
    @Binding var unifiedExternalMatchCount: Int
    @Binding var unifiedExternalTotalMatchCount: Int
    @Binding var unifiedExternalCurrentMatchIndex: Int

    // Find (⌘F): local query, standard macOS find-in-document behavior.
    let findQuery: String
    let findToken: Int
    let findDirection: Int
    let findReset: Bool
    let allowMatchAutoScroll: Bool
    let jumpToken: Int
    let roleNavToken: Int
    let roleNavRole: RoleToggle
    let roleNavDirection: Int
    @Binding var externalMatchCount: Int
    @Binding var externalTotalMatchCount: Int
    @Binding var externalCurrentMatchIndex: Int
    @AppStorage("TranscriptFontSize") private var transcriptFontSize: Double = 13
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var lines: [TerminalLine] = []
    @State private var visibleLines: [TerminalLine] = []
    @State private var fullSnapshot: TextSnapshot = .empty
    @State private var visibleSnapshot: TextSnapshot = .empty
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

    // Unified Search navigation/highlight state
    @State private var unifiedMatchOccurrences: [MatchOccurrence] = []
    @State private var unifiedCurrentMatchLineID: Int? = nil

    // Local Find state
    @State private var findMatchOccurrences: [MatchOccurrence] = []
    @State private var findCurrentMatchLineID: Int? = nil
    @State private var conversationStartLineID: Int? = nil
    @State private var scrollTargetLineID: Int? = nil
    @State private var scrollTargetToken: Int = 0
    @State private var roleNavScrollTargetLineID: Int? = nil
    @State private var roleNavScrollToken: Int = 0
    @State private var preambleUserBlockIndexes: Set<Int> = []
    @State private var autoScrollSessionID: String? = nil

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
            autoScrollSessionID = nil
            rebuildLines(priority: .userInitiated)
        }
        .onChange(of: activeRoles) { _, _ in
            visibleLines = roleFilteredLines(from: lines)
            visibleSnapshot = buildTextSnapshot(lines: visibleLines)
            if !unifiedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recomputeUnifiedMatches(resetIndex: true)
            }
            if !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recomputeFindMatches(resetIndex: true)
            }
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
                    sessionSource: session.source,
                    unifiedFindQuery: unifiedQuery,
                    unifiedMatchOccurrences: unifiedMatchOccurrences,
                    unifiedCurrentMatchLineID: unifiedCurrentMatchLineID,
                    unifiedHighlightActive: !unifiedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    unifiedAllowMatchAutoScroll: unifiedAllowMatchAutoScroll,
                    findQuery: findQuery,
                    findCurrentMatchLineID: findCurrentMatchLineID,
                    findHighlightActive: !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    allowMatchAutoScroll: allowMatchAutoScroll,
                    scrollTargetLineID: scrollTargetLineID,
                    scrollTargetToken: scrollTargetToken,
                    roleNavScrollTargetLineID: roleNavScrollTargetLineID,
                    roleNavScrollToken: roleNavScrollToken,
                    preambleUserBlockIndexes: preambleUserBlockIndexes,
                    colorScheme: colorScheme,
                    monochrome: stripMonochrome
                )
                .onChange(of: unifiedFindToken) { _, _ in handleUnifiedFindRequest() }
                .onChange(of: findToken) { _, _ in handleFindRequest() }
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
            fullSnapshot = buildTextSnapshot(lines: result.lines)
            visibleSnapshot = buildTextSnapshot(lines: visibleLines)
            conversationStartLineID = result.conversationStartLineID
            preambleUserBlockIndexes = result.preambleUserBlockIndexes
            userLineIndices = result.userLineIndices
            assistantLineIndices = result.assistantLineIndices
            toolLineIndices = result.toolLineIndices
            errorLineIndices = result.errorLineIndices

            // Reset Unified Search + Find state when rebuilding.
            unifiedMatchOccurrences = []
            unifiedCurrentMatchLineID = nil
            unifiedExternalMatchCount = 0
            unifiedExternalTotalMatchCount = 0
            unifiedExternalCurrentMatchIndex = 0

            findMatchOccurrences = []
            findCurrentMatchLineID = nil
            roleNavPositions = [:]
            externalMatchCount = 0
            externalTotalMatchCount = 0
            externalCurrentMatchIndex = 0

            if !unifiedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recomputeUnifiedMatches(resetIndex: true)
            }
            if !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recomputeFindMatches(resetIndex: true)
            }

            if unifiedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                applyAutoScrollIfNeeded(sessionID: sessionSnapshot.id, skipAgentsPreamble: skipAgentsPreamble)
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
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let built = TerminalBuilder.buildLines(for: session, showMeta: false)
        let (decorated, dividerID) = applyConversationStartDividerIfNeeded(session: session, lines: built, enabled: skipAgentsPreamble)
        let preambleUserBlockIndexes = computePreambleUserBlockIndexes(session: session)

        // Collapse multi-line blocks into single navigable/message entries per role.
        var firstLineForBlock: [Int: Int] = [:]       // blockIndex -> first line id
        var roleForBlock: [Int: TerminalLineRole] = [:]
        var toolGroupKeyForBlock: [Int: String] = [:]
        var lastToolGroupKey: String? = nil
        var lastToolName: String? = nil

        for line in decorated {
            guard let blockIndex = line.blockIndex else { continue }
            if firstLineForBlock[blockIndex] == nil {
                firstLineForBlock[blockIndex] = line.id
                roleForBlock[blockIndex] = line.role
            }
        }

        if !blocks.isEmpty {
            for (idx, block) in blocks.enumerated() {
                guard block.kind == .toolCall || block.kind == .toolOut else {
                    lastToolGroupKey = nil
                    lastToolName = nil
                    continue
                }

                let normalizedName = block.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var derivedKey: String? = nil

                if let toolBlock = ToolTextBlockNormalizer.normalize(block: block, source: session.source),
                   let groupKey = toolBlock.groupKey,
                   !groupKey.isEmpty {
                    derivedKey = groupKey
                }

                if derivedKey == nil,
                   block.kind == .toolOut,
                   let last = lastToolGroupKey {
                    if let lastName = lastToolName, let normalizedName {
                        if lastName == normalizedName { derivedKey = last }
                    } else {
                        derivedKey = last
                    }
                }

                if derivedKey == nil {
                    derivedKey = "tool-block-\(idx)"
                }

                toolGroupKeyForBlock[idx] = derivedKey
                lastToolGroupKey = derivedKey
                if let normalizedName { lastToolName = normalizedName }
            }
        }

        func messageIDs(for roleMatch: (TerminalLineRole) -> Bool) -> [Int] {
            firstLineForBlock.compactMap { blockIndex, lineID in
                guard let role = roleForBlock[blockIndex], roleMatch(role) else { return nil }
                return lineID
            }
            .sorted()
        }

        func toolMessageIDs() -> [Int] {
            var grouped: [String: Int] = [:]
            for (blockIndex, lineID) in firstLineForBlock {
                guard let role = roleForBlock[blockIndex], role == .toolInput || role == .toolOutput else { continue }
                let key = toolGroupKeyForBlock[blockIndex] ?? "tool-block-\(blockIndex)"
                if let existing = grouped[key] {
                    grouped[key] = min(existing, lineID)
                } else {
                    grouped[key] = lineID
                }
            }
            return grouped.values.sorted()
        }

        return RebuildResult(
            lines: decorated,
            conversationStartLineID: dividerID,
            preambleUserBlockIndexes: preambleUserBlockIndexes,
            userLineIndices: messageIDs { $0 == .user },
            assistantLineIndices: messageIDs { $0 == .assistant },
            toolLineIndices: toolMessageIDs(),
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
        let swatch = TerminalRolePalette.swiftUI(
            role: TerminalRolePalette.role(for: role),
            sessionSource: role == .assistant ? session.source : nil,
            scheme: colorScheme,
            monochrome: stripMonochrome
        )
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
            .help(toggleHelpText(for: role))

            HStack(spacing: 4) {
                ZStack {
                    Button(action: { navigateRole(role, direction: -1) }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(navDisabled ? Color.secondary.opacity(0.35) : Color.secondary)
                    .disabled(navDisabled)
                }
                .help(previousHelpText(for: role))

                ZStack {
                    Button(action: { navigateRole(role, direction: 1) }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(navDisabled ? Color.secondary.opacity(0.35) : Color.secondary)
                    .disabled(navDisabled)
                }
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

        if let currentID = unifiedCurrentMatchLineID, let pos = sorted.firstIndex(of: currentID) {
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

    private func toggleHelpText(for role: RoleToggle) -> String {
        switch role {
        case .user: return "Show/hide user prompts"
        case .assistant: return "Show/hide agent responses"
        case .tools: return "Show/hide tool calls and outputs"
        case .errors: return "Show/hide errors"
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
        } else if let currentID = unifiedCurrentMatchLineID, let pos = sorted.firstIndex(of: currentID) {
            startIndex = pos
        } else {
            startIndex = direction >= 0 ? 0 : (count - 1)
        }

        let nextIndex = wrapIndex(startIndex + step)
        roleNavPositions[role] = nextIndex
        unifiedCurrentMatchLineID = sorted[nextIndex]
        roleNavScrollTargetLineID = sorted[nextIndex]
        roleNavScrollToken &+= 1
    }

    /// Execute a Unified Search request driven by the sessions list.
    private func handleUnifiedFindRequest() {
        recomputeUnifiedMatches(resetIndex: unifiedFindReset, direction: unifiedFindDirection)
    }

    /// Execute a local Find request driven by the find bar.
    private func handleFindRequest() {
        recomputeFindMatches(resetIndex: findReset, direction: findDirection)
    }

    private func recomputeUnifiedMatches(resetIndex: Bool, direction: Int = 1) {
        let query = unifiedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            unifiedMatchOccurrences = []
            unifiedCurrentMatchLineID = nil
            unifiedExternalMatchCount = 0
            unifiedExternalTotalMatchCount = 0
            unifiedExternalCurrentMatchIndex = 0
            return
        }

        let visibleRanges = SearchTextMatcher.matchRanges(in: visibleSnapshot.text, query: query)
        let visibleOccurrences = occurrences(from: visibleRanges, in: visibleSnapshot)
        unifiedMatchOccurrences = visibleOccurrences
        unifiedExternalMatchCount = visibleOccurrences.count

        let totalRanges = SearchTextMatcher.matchRanges(in: fullSnapshot.text, query: query)
        unifiedExternalTotalMatchCount = totalRanges.count

        guard !visibleOccurrences.isEmpty else {
            unifiedCurrentMatchLineID = nil
            unifiedExternalCurrentMatchIndex = 0
            return
        }

        // Determine which match to select.
        if resetIndex {
            unifiedExternalCurrentMatchIndex = 0
        } else {
            var nextIndex = unifiedExternalCurrentMatchIndex + (direction >= 0 ? 1 : -1)
            if nextIndex < 0 {
                nextIndex = visibleOccurrences.count - 1
            } else if nextIndex >= visibleOccurrences.count {
                nextIndex = 0
            }
            unifiedExternalCurrentMatchIndex = nextIndex
        }

        let clampedIndex = min(max(unifiedExternalCurrentMatchIndex, 0), visibleOccurrences.count - 1)
        unifiedCurrentMatchLineID = visibleOccurrences[clampedIndex].lineID
    }

    private func recomputeFindMatches(resetIndex: Bool, direction: Int = 1) {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            findMatchOccurrences = []
            findCurrentMatchLineID = nil
            externalMatchCount = 0
            externalTotalMatchCount = 0
            externalCurrentMatchIndex = 0
            return
        }

        let visibleRanges = SearchTextMatcher.matchRanges(in: visibleSnapshot.text, query: query)
        let visibleOccurrences = occurrences(from: visibleRanges, in: visibleSnapshot)
        findMatchOccurrences = visibleOccurrences
        externalMatchCount = visibleOccurrences.count

        let totalRanges = SearchTextMatcher.matchRanges(in: fullSnapshot.text, query: query)
        externalTotalMatchCount = totalRanges.count

        guard !visibleOccurrences.isEmpty else {
            findCurrentMatchLineID = nil
            externalCurrentMatchIndex = 0
            return
        }

        if resetIndex {
            externalCurrentMatchIndex = 0
        } else {
            var nextIndex = externalCurrentMatchIndex + (direction >= 0 ? 1 : -1)
            if nextIndex < 0 {
                nextIndex = visibleOccurrences.count - 1
            } else if nextIndex >= visibleOccurrences.count {
                nextIndex = 0
            }
            externalCurrentMatchIndex = nextIndex
        }

        let clampedIndex = min(max(externalCurrentMatchIndex, 0), visibleOccurrences.count - 1)
        findCurrentMatchLineID = visibleOccurrences[clampedIndex].lineID
    }

    private func buildTextSnapshot(lines: [TerminalLine]) -> TextSnapshot {
        guard !lines.isEmpty else { return .empty }
        var text = ""
        text.reserveCapacity(lines.count * 32)
        var lineRanges: [Int: NSRange] = [:]
        lineRanges.reserveCapacity(lines.count)
        var orderedLineRanges: [NSRange] = []
        orderedLineRanges.reserveCapacity(lines.count)
        var orderedLineIDs: [Int] = []
        orderedLineIDs.reserveCapacity(lines.count)

        var location = 0
        for (idx, line) in lines.enumerated() {
            let lineString = idx == lines.count - 1 ? line.text : line.text + "\n"
            let length = lineString.utf16.count
            let range = NSRange(location: location, length: length)
            text.append(lineString)
            lineRanges[line.id] = range
            orderedLineRanges.append(range)
            orderedLineIDs.append(line.id)
            location += length
        }

        return TextSnapshot(text: text,
                            lineRanges: lineRanges,
                            orderedLineRanges: orderedLineRanges,
                            orderedLineIDs: orderedLineIDs)
    }

    private func occurrences(from ranges: [NSRange], in snapshot: TextSnapshot) -> [MatchOccurrence] {
        guard !ranges.isEmpty else { return [] }
        var out: [MatchOccurrence] = []
        out.reserveCapacity(ranges.count)
        for range in ranges {
            guard let lineID = lineID(for: range.location, in: snapshot) else { continue }
            out.append(MatchOccurrence(range: range, lineID: lineID))
        }
        return out
    }

    private func lineID(for location: Int, in snapshot: TextSnapshot) -> Int? {
        let ranges = snapshot.orderedLineRanges
        let ids = snapshot.orderedLineIDs
        guard !ranges.isEmpty else { return nil }

        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let r = ranges[mid]
            if location < r.location {
                high = mid - 1
                continue
            }
            if location >= (r.location + r.length) {
                low = mid + 1
                continue
            }
            return ids[mid]
        }
        return nil
    }

    private func skipAgentsPreambleEnabled() -> Bool {
        let d = UserDefaults.standard
        let key = PreferencesKey.Unified.skipAgentsPreamble
        if d.object(forKey: key) == nil { return true }
        return d.bool(forKey: key)
    }

    private func sessionViewAutoScrollTarget() -> SessionViewAutoScrollTarget {
        let d = UserDefaults.standard
        let key = PreferencesKey.Unified.sessionViewAutoScrollTarget
        guard let raw = d.string(forKey: key),
              let parsed = SessionViewAutoScrollTarget(rawValue: raw) else {
            return .lastUserPrompt
        }
        return parsed
    }

    private func applyAutoScrollIfNeeded(sessionID: String, skipAgentsPreamble: Bool) {
        guard autoScrollSessionID != sessionID else { return }

        let target = sessionViewAutoScrollTarget()
        guard let lineID = userPromptLineID(for: target, skipAgentsPreamble: skipAgentsPreamble) else { return }
        autoScrollSessionID = sessionID
        jumpToUserPrompt(lineID: lineID)
    }

    private func userPromptLineID(for target: SessionViewAutoScrollTarget, skipAgentsPreamble: Bool) -> Int? {
        guard !userLineIndices.isEmpty else { return nil }
        switch target {
        case .lastUserPrompt:
            return userLineIndices.last
        case .firstUserPrompt:
            if skipAgentsPreamble, let dividerID = conversationStartLineID {
                if let after = userLineIndices.first(where: { $0 > dividerID }) {
                    return after
                }
            }
            return userLineIndices.first
        }
    }

    private func jumpToFirstPrompt() {
        guard let lineID = userPromptLineID(for: .firstUserPrompt, skipAgentsPreamble: skipAgentsPreambleEnabled()) else { return }
        jumpToUserPrompt(lineID: lineID)
    }

    private func jumpToUserPrompt(lineID: Int) {
        if !activeRoles.contains(.user) {
            activeRoles.insert(.user)
            persistRoleToggles()
        }
        updateUserNavigationPosition(lineID: lineID)
        roleNavScrollTargetLineID = lineID
        roleNavScrollToken &+= 1
    }

    private func updateUserNavigationPosition(lineID: Int) {
        if let position = userLineIndices.firstIndex(of: lineID) {
            roleNavPositions[.user] = position
        }
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
                    Group {
                        Text(line.text)
                    }
                    .font(.system(size: fontSize,
                                  weight: (line.role == .toolInput && isToolLabelLine(line.text)) ? .semibold : .regular,
                                  design: (line.role == .toolInput) ? .monospaced : .default))
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

    private func isToolLabelLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let labels: Set<String> = ["bash", "read", "list", "glob", "grep", "plan", "task", "tool"]
        if labels.contains(lower) { return true }
        if lower.hasPrefix("task ("), lower.hasSuffix(")") { return true }
        return false
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

    static func swiftUI(role: Role, sessionSource: SessionSource? = nil, scheme: ColorScheme, monochrome: Bool = false) -> SwiftUISwatch {
        let appKitColors = baseColors(for: role, sessionSource: sessionSource, scheme: scheme, monochrome: monochrome)
        return SwiftUISwatch(
            foreground: Color(nsColor: appKitColors.foreground),
            background: appKitColors.background.map { Color(nsColor: $0) },
            accent: Color(nsColor: appKitColors.accent)
        )
    }

    static func appKit(role: Role, sessionSource: SessionSource? = nil, scheme: ColorScheme, monochrome: Bool = false) -> AppKitSwatch {
        baseColors(for: role, sessionSource: sessionSource, scheme: scheme, monochrome: monochrome)
    }

    private static func baseColors(for role: Role, sessionSource: SessionSource?, scheme: ColorScheme, monochrome: Bool) -> AppKitSwatch {
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
                let accentBase = sessionSource.map { TranscriptColorSystem.agentBrandAccent(source: $0) } ?? NSColor.secondaryLabelColor
                return AppKitSwatch(
                    foreground: NSColor.labelColor,
                    background: tinted(accentBase, light: 0.08, dark: 0.12),
                    accent: accentBase
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
	                    background: tinted(NSColor.systemGreen, light: 0.10, dark: 0.14),
	                    accent: NSColor.systemGreen
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

// MARK: - Terminal layout + decorations (Color view)

private final class TerminalLayoutManager: NSLayoutManager {
    enum BlockKind {
        case user
        case userInterrupt
        case agent
        case toolCall
        case toolOutput
        case error
        case localCommand
    }

    struct BlockDecoration {
        let range: NSRange
        let kind: BlockKind
    }

    struct FindMatch {
        let range: NSRange
        let isCurrentLine: Bool
    }

    struct LineIndexEntry {
        let id: Int
        let range: NSRange
    }

    var isDark: Bool = false
    var agentBrandAccent: NSColor = NSColor.secondaryLabelColor
    var blocks: [BlockDecoration] = []
	    var lineIndex: [LineIndexEntry] = []
	    var matchLineIDs: Set<Int> = []
	    var currentMatchLineID: Int? = nil
	    var matches: [FindMatch] = []
	    var localFindRanges: [NSRange] = []
	    var localFindCurrentLineID: Int? = nil

    private struct BlockStyle {
        let fill: NSColor
        let accent: NSColor?
        let accentWidth: CGFloat
        let paddingY: CGFloat
    }

	    private func style(for kind: BlockKind) -> BlockStyle {
	        // Tuned for consistent contrast in light/dark:
	        // - subtle tint fill
	        // - optional left accent bar
	        // - thin stroke for definition
	        let dark = isDark

        func rgba(_ color: NSColor, alpha: CGFloat) -> NSColor { color.withAlphaComponent(alpha) }

	        switch kind {
        case .user:
            let base: NSColor = TranscriptColorSystem.semanticAccent(.user)
            return BlockStyle(
                fill: rgba(base, alpha: dark ? 0.12 : 0.04),
                accent: rgba(base, alpha: dark ? 0.70 : 0.50),
                accentWidth: 4,
                paddingY: 6
            )
        case .userInterrupt:
            let base: NSColor = TranscriptColorSystem.semanticAccent(.user)
            return BlockStyle(
                fill: rgba(base, alpha: dark ? 0.10 : 0.03),
                accent: rgba(base, alpha: dark ? 0.70 : 0.50),
                accentWidth: 4,
                paddingY: 6
            )
        case .agent:
            let base = agentBrandAccent
            return BlockStyle(
                fill: rgba(base, alpha: dark ? 0.06 : 0.012),
                accent: rgba(base, alpha: dark ? 0.60 : 0.42),
                accentWidth: 4,
                paddingY: 6
            )
        case .localCommand:
            let base: NSColor = TranscriptColorSystem.semanticAccent(.user)
            return BlockStyle(
                fill: rgba(base, alpha: dark ? 0.10 : 0.03),
                accent: rgba(base, alpha: dark ? 0.70 : 0.50),
                accentWidth: 4,
                paddingY: 6
            )
	        case .toolCall:
	            let base: NSColor = TranscriptColorSystem.semanticAccent(.toolCall)
	            return BlockStyle(
	                fill: rgba(base, alpha: dark ? 0.10 : 0.03),
	                accent: rgba(base, alpha: dark ? 0.78 : 0.60),
	                accentWidth: 4,
                    paddingY: 8
	            )
	        case .toolOutput:
	            let base: NSColor = TranscriptColorSystem.semanticAccent(.toolOutputSuccess)
	            return BlockStyle(
	                fill: rgba(base, alpha: dark ? 0.10 : 0.03),
	                accent: rgba(base, alpha: dark ? 0.78 : 0.60),
	                accentWidth: 4,
                    paddingY: 8
	            )
	        case .error:
	            let base: NSColor = TranscriptColorSystem.semanticAccent(.error)
	            return BlockStyle(
	                fill: rgba(base, alpha: dark ? 0.11 : 0.035),
	                accent: rgba(base, alpha: dark ? 0.82 : 0.65),
	                accentWidth: 4,
                    paddingY: 8
	            )
	        }
	    }

    private func blockDecoration(containing charIndex: Int) -> BlockDecoration? {
        // Binary search by character location (blocks are non-overlapping and sorted by construction).
        var low = 0
        var high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let r = blocks[mid].range
            if charIndex < r.location {
                high = mid - 1
                continue
            }
            if charIndex >= (r.location + r.length) {
                low = mid + 1
                continue
            }
            return blocks[mid]
        }
        return nil
    }

    private func lineID(at charIndex: Int) -> Int? {
        var low = 0
        var high = lineIndex.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let r = lineIndex[mid].range
            if charIndex < r.location {
                high = mid - 1
                continue
            }
            if charIndex >= (r.location + r.length) {
                low = mid + 1
                continue
            }
            return lineIndex[mid].id
        }
        return nil
    }

	    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
	        // Draw block cards + find highlights, then let AppKit draw any remaining backgrounds (including selection).

	        if let tc = textContainers.first {
	            drawBlockCards(forGlyphRange: glyphsToShow, in: tc, at: origin)
	            drawFindHighlights(forGlyphRange: glyphsToShow, in: tc, at: origin)
	            drawFindLineMarkers(forGlyphRange: glyphsToShow, in: tc, at: origin)
	            drawLocalFindLineMarker(forGlyphRange: glyphsToShow, in: tc, at: origin)
	            drawLocalFindOutlines(forGlyphRange: glyphsToShow, in: tc, at: origin)
	        }

	        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
	    }

	    private func drawLocalFindOutlines(forGlyphRange glyphsToShow: NSRange, in tc: NSTextContainer, at origin: CGPoint) {
	        guard !localFindRanges.isEmpty else { return }

	        let stroke = NSColor.systemBlue.withAlphaComponent(isDark ? 0.92 : 0.85)
	        let glow = NSColor.systemBlue.withAlphaComponent(isDark ? 0.55 : 0.30)

	        for r0 in localFindRanges {
	            let matchGlyphs = glyphRange(forCharacterRange: r0, actualCharacterRange: nil)
	            guard NSIntersectionRange(matchGlyphs, glyphsToShow).length > 0 else { continue }

	            enumerateLineFragments(forGlyphRange: matchGlyphs) { _, _, container, glyphRange, _ in
	                guard container === tc else { return }
	                let g = NSIntersectionRange(glyphRange, matchGlyphs)
	                guard g.length > 0 else { return }

	                var rect = self.boundingRect(forGlyphRange: g, in: tc)
	                rect = rect.offsetBy(dx: origin.x, dy: origin.y)
	                rect = rect.insetBy(dx: -2.0, dy: -1.0)

	                let radius: CGFloat = 4
	                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

	                NSGraphicsContext.saveGraphicsState()
	                let shadow = NSShadow()
	                shadow.shadowBlurRadius = 8
	                shadow.shadowOffset = .zero
	                shadow.shadowColor = glow
	                shadow.set()
	                stroke.setStroke()
	                path.lineWidth = 1.6
	                path.stroke()
	                NSGraphicsContext.restoreGraphicsState()
	            }
	        }
	    }

		    private func drawLocalFindLineMarker(forGlyphRange glyphsToShow: NSRange, in tc: NSTextContainer, at origin: CGPoint) {
		        guard let currentID = localFindCurrentLineID else { return }
		        guard let entry = lineIndex.first(where: { $0.id == currentID }) else { return }

		        let lineGlyphs = glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
		        guard NSIntersectionRange(lineGlyphs, glyphsToShow).length > 0 else { return }

		        let fill = NSColor.systemBlue.withAlphaComponent(isDark ? 0.95 : 0.88)
		        let cardInsetX: CGFloat = 8
		        var renderedGlyphStarts: Set<Int> = []

		        guard let firstMatch = localFindRanges.first else { return }
		        let matchGlyphs = glyphRange(forCharacterRange: firstMatch, actualCharacterRange: nil)
		        guard NSIntersectionRange(matchGlyphs, glyphsToShow).length > 0 else { return }

		        enumerateLineFragments(forGlyphRange: matchGlyphs) { rect, _, container, glyphRange, _ in
		            guard container === tc else { return }
		            if renderedGlyphStarts.contains(glyphRange.location) { return }
		            renderedGlyphStarts.insert(glyphRange.location)

		            let g = NSIntersectionRange(glyphRange, matchGlyphs)
		            guard g.length > 0 else { return }

		            var matchRect = self.boundingRect(forGlyphRange: g, in: tc)
		            matchRect = matchRect.offsetBy(dx: origin.x, dy: origin.y)

		            let charIndex = self.characterIndexForGlyph(at: g.location)
		            let blockAccentWidth: CGFloat = {
		                guard let b = self.blockDecoration(containing: charIndex) else { return 0 }
		                return self.style(for: b.kind).accentWidth
		            }()

		            let width: CGFloat = max(6, blockAccentWidth + 2)
		            let height = max(2, matchRect.height - 2)
		            let y = matchRect.minY + 1
		            let x = rect.minX + origin.x + cardInsetX

		            let barRect = CGRect(x: x, y: y, width: width, height: height)
		            let bar = NSBezierPath(rect: barRect)

		            fill.setFill()
		            bar.fill()
		        }
		    }

    private func drawBlockCards(forGlyphRange glyphsToShow: NSRange, in tc: NSTextContainer, at origin: CGPoint) {
        guard !blocks.isEmpty else { return }

        let cardCornerRadius: CGFloat = 8
        let cardInsetX: CGFloat = 8

        for block in blocks {
            let blockGlyphs = glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            guard NSIntersectionRange(blockGlyphs, glyphsToShow).length > 0 else { continue }

            var unionRect: CGRect? = nil
            enumerateLineFragments(forGlyphRange: blockGlyphs) { rect, usedRect, _, _, _ in
                let r = rect.offsetBy(dx: origin.x, dy: origin.y)
                let u = usedRect.offsetBy(dx: origin.x, dy: origin.y)
                let mixed = CGRect(
                    x: r.minX,
                    y: u.minY,
                    width: max(0, r.maxX - r.minX),
                    height: max(0, u.maxY - u.minY)
                )
                unionRect = unionRect.map { $0.union(mixed) } ?? mixed
            }
            guard var cardRect = unionRect else { continue }

            let style = style(for: block.kind)

            // Card geometry: keep whitespace between blocks, but add internal padding.
            cardRect = cardRect.insetBy(dx: cardInsetX, dy: 0)
            cardRect = cardRect.insetBy(dx: 0, dy: -style.paddingY)
            let path = NSBezierPath(roundedRect: cardRect, xRadius: cardCornerRadius, yRadius: cardCornerRadius)

            style.fill.setFill()
            path.fill()

            if let accent = style.accent, style.accentWidth > 0 {
                let stripInsetY = style.paddingY
                accent.setFill()
                let y0 = cardRect.minY + stripInsetY
                let h = max(0, cardRect.height - (stripInsetY * 2))
                if h > 0 {
                    let stripRect = CGRect(x: cardRect.minX, y: y0, width: style.accentWidth, height: h)
                    let radius = style.accentWidth / 2
                    if block.kind == .agent {
                        // Agent strip: two-tone inset style so it won't be confused with semantic success strips.
                        let outer = NSBezierPath(roundedRect: stripRect, xRadius: radius, yRadius: radius)
                        accent.withAlphaComponent(min(1, accent.alphaComponent)).setFill()
                        outer.fill()

                        let innerRect = stripRect.insetBy(dx: 1.0, dy: 1.0)
                        if innerRect.width > 0, innerRect.height > 0 {
                            let innerRadius = max(0, (innerRect.width / 2))
                            let inner = NSBezierPath(roundedRect: innerRect, xRadius: innerRadius, yRadius: innerRadius)
                            accent.withAlphaComponent(min(1, accent.alphaComponent + 0.30)).setFill()
                            inner.fill()
                        }
                    } else {
                        NSBezierPath(roundedRect: stripRect, xRadius: radius, yRadius: radius).fill()
                    }
                    if block.kind == .user {
                        let rightStripRect = CGRect(x: cardRect.maxX - style.accentWidth, y: y0, width: style.accentWidth, height: h)
                        let rightRadius = style.accentWidth / 2
                        accent.setFill()
                        NSBezierPath(roundedRect: rightStripRect, xRadius: rightRadius, yRadius: rightRadius).fill()
                    }
                }
            }
        }
    }

    private func drawFindHighlights(forGlyphRange glyphsToShow: NSRange, in tc: NSTextContainer, at origin: CGPoint) {
        guard !matches.isEmpty else { return }

        let yellow = NSColor.systemYellow
        let fill = yellow.withAlphaComponent(isDark ? 0.32 : 0.22)
        let stroke = yellow.withAlphaComponent(isDark ? 0.70 : 0.55)
        let currentStroke = yellow.withAlphaComponent(isDark ? 0.90 : 0.85)

        for m in matches {
            let matchGlyphs = glyphRange(forCharacterRange: m.range, actualCharacterRange: nil)
            guard NSIntersectionRange(matchGlyphs, glyphsToShow).length > 0 else { continue }

            enumerateLineFragments(forGlyphRange: matchGlyphs) { _, _, container, glyphRange, _ in
                guard container === tc else { return }
                let g = NSIntersectionRange(glyphRange, matchGlyphs)
                guard g.length > 0 else { return }
                var r = self.boundingRect(forGlyphRange: g, in: tc)
                r = r.offsetBy(dx: origin.x, dy: origin.y)
                r = r.insetBy(dx: -1.5, dy: -0.5)

                let radius: CGFloat = 3
                let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
                fill.setFill()
                p.fill()

                if m.isCurrentLine {
                    currentStroke.setStroke()
                    p.lineWidth = 1
                    p.stroke()

                    // Stronger “underline” hint (bottom rule) for current match.
                    let y = r.maxY - 2.0
                    let underline = NSBezierPath()
                    underline.move(to: CGPoint(x: r.minX + 1, y: y))
                    underline.line(to: CGPoint(x: r.maxX - 1, y: y))
                    underline.lineWidth = 2
                    currentStroke.setStroke()
                    underline.stroke()
                } else {
                    stroke.setStroke()
                    p.lineWidth = 1
                    p.stroke()
                }
            }
        }
    }

    private func drawFindLineMarkers(forGlyphRange glyphsToShow: NSRange, in tc: NSTextContainer, at origin: CGPoint) {
        guard !matches.isEmpty else { return }

        let yellow = NSColor.systemYellow
        let anyFill = yellow.withAlphaComponent(isDark ? 0.65 : 0.50)
        let currentFill = yellow.withAlphaComponent(isDark ? 0.85 : 0.75)
        let cardInsetX: CGFloat = 8
        var renderedGlyphStarts: Set<Int> = []

        for match in matches {
            let matchGlyphs = glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
            guard NSIntersectionRange(matchGlyphs, glyphsToShow).length > 0 else { continue }

            enumerateLineFragments(forGlyphRange: matchGlyphs) { rect, _, container, glyphRange, _ in
                guard container === tc else { return }
                let g = NSIntersectionRange(glyphRange, matchGlyphs)
                guard g.length > 0 else { return }
                if renderedGlyphStarts.contains(glyphRange.location) { return }
                renderedGlyphStarts.insert(glyphRange.location)

                let charIndex = self.characterIndexForGlyph(at: g.location)
                guard let lineID = self.lineID(at: charIndex) else { return }

                let isCurrentLine = (lineID == self.currentMatchLineID)
                let blockAccentWidth: CGFloat = {
                    guard let b = self.blockDecoration(containing: charIndex) else { return 0 }
                    return self.style(for: b.kind).accentWidth
                }()

                let width: CGFloat = max(isCurrentLine ? 4 : 3, blockAccentWidth)
                let height = max(2, rect.height - 4)
                let y = rect.minY + 2 + origin.y
                let x = rect.minX + origin.x + cardInsetX

                let pill = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                                        xRadius: width / 2,
                                        yRadius: width / 2)
                (isCurrentLine ? currentFill : anyFill).setFill()
                pill.fill()
            }
        }
    }
}

private struct TerminalTextScrollView: NSViewRepresentable {
    let lines: [TerminalLine]
    let fontSize: CGFloat
    let sessionSource: SessionSource
    let unifiedFindQuery: String
    let unifiedMatchOccurrences: [MatchOccurrence]
    let unifiedCurrentMatchLineID: Int?
    let unifiedHighlightActive: Bool
    let unifiedAllowMatchAutoScroll: Bool
    let findQuery: String
    let findCurrentMatchLineID: Int?
    let findHighlightActive: Bool
    let allowMatchAutoScroll: Bool
    let scrollTargetLineID: Int?
    let scrollTargetToken: Int
    let roleNavScrollTargetLineID: Int?
    let roleNavScrollToken: Int
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
        var lastRoleNavScrollToken: Int = 0

        var lastUnifiedFindQuery: String = ""
        var lastUnifiedMatchOccurrences: [MatchOccurrence] = []
        var lastUnifiedCurrentMatchLineID: Int? = nil

        var lastFindQuery: String = ""
        var lastFindCurrentMatchLineID: Int? = nil

        var lines: [TerminalLine] = []
        var orderedLineRanges: [NSRange] = []
        var orderedLineIDs: [Int] = []

        private weak var activeTextView: NSTextView?
        weak var activeLayoutManager: TerminalLayoutManager?
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

    private var effectiveUnifiedMatchOccurrences: [MatchOccurrence] {
        unifiedHighlightActive ? unifiedMatchOccurrences : []
    }

    private var effectiveUnifiedCurrentMatchLineID: Int? {
        unifiedHighlightActive ? unifiedCurrentMatchLineID : nil
    }

    private var effectiveFindCurrentMatchLineID: Int? {
        findHighlightActive ? findCurrentMatchLineID : nil
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textStorage = NSTextStorage()
        let layoutManager = TerminalLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindPanel = true
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.backgroundColor = NSColor.textBackgroundColor

        scroll.documentView = textView

        context.coordinator.activeLayoutManager = layoutManager
        applyContent(to: textView, context: context)
        context.coordinator.lastLinesSignature = signature(for: lines)
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastMonochrome = monochrome
        context.coordinator.lastColorScheme = colorScheme
        context.coordinator.lastUnifiedFindQuery = unifiedFindQuery
        context.coordinator.lastUnifiedMatchOccurrences = effectiveUnifiedMatchOccurrences
        context.coordinator.lastUnifiedCurrentMatchLineID = effectiveUnifiedCurrentMatchLineID
        context.coordinator.lastFindQuery = findQuery
        context.coordinator.lastFindCurrentMatchLineID = effectiveFindCurrentMatchLineID
        context.coordinator.lastRoleNavScrollToken = roleNavScrollToken
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
        } else {
            let unifiedChanged =
                context.coordinator.lastUnifiedMatchOccurrences != effectiveUnifiedMatchOccurrences ||
                context.coordinator.lastUnifiedCurrentMatchLineID != effectiveUnifiedCurrentMatchLineID ||
                context.coordinator.lastUnifiedFindQuery != unifiedFindQuery
            if unifiedChanged {
                updateUnifiedHighlights(in: tv,
                                       context: context,
                                       query: unifiedFindQuery,
                                       occurrences: effectiveUnifiedMatchOccurrences,
                                       currentLineID: effectiveUnifiedCurrentMatchLineID)
            }

            let findChanged =
                context.coordinator.lastFindQuery != findQuery ||
                context.coordinator.lastFindCurrentMatchLineID != effectiveFindCurrentMatchLineID
            if findChanged {
                updateLocalFindOverlay(in: tv,
                                       context: context,
                                       query: findQuery,
                                       currentLineID: effectiveFindCurrentMatchLineID)
            }
        }

        if allowMatchAutoScroll,
           findHighlightActive,
           let target = effectiveFindCurrentMatchLineID,
           let range = context.coordinator.lineRanges[target] {
            tv.scrollRangeToVisible(range)
        } else if unifiedAllowMatchAutoScroll,
                  unifiedHighlightActive,
                  let target = effectiveUnifiedCurrentMatchLineID,
                  let range = context.coordinator.lineRanges[target] {
            tv.scrollRangeToVisible(range)
        }

        if scrollTargetToken != context.coordinator.lastScrollToken,
           let target = scrollTargetLineID,
           let range = context.coordinator.lineRanges[target] {
            scrollRangeToTop(tv, range: range)
            context.coordinator.lastScrollToken = scrollTargetToken
        }

        if roleNavScrollToken != context.coordinator.lastRoleNavScrollToken,
           let target = roleNavScrollTargetLineID,
           let range = context.coordinator.lineRanges[target] {
            tv.scrollRangeToVisible(range)
            context.coordinator.lastRoleNavScrollToken = roleNavScrollToken
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
        let (attr, ranges) = buildAttributedString()
        context.coordinator.lineRanges = ranges
        context.coordinator.lineRoles = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.role) })
        context.coordinator.lines = lines
        context.coordinator.orderedLineRanges = lines.compactMap { ranges[$0.id] }
        context.coordinator.orderedLineIDs = lines.map(\.id)
        context.coordinator.lastUnifiedMatchOccurrences = effectiveUnifiedMatchOccurrences
        context.coordinator.lastUnifiedCurrentMatchLineID = effectiveUnifiedCurrentMatchLineID
        context.coordinator.lastUnifiedFindQuery = unifiedFindQuery
        context.coordinator.lastFindQuery = findQuery
        context.coordinator.lastFindCurrentMatchLineID = effectiveFindCurrentMatchLineID
        textView.textStorage?.setAttributedString(attr)

        if let lm = (textView.layoutManager as? TerminalLayoutManager) ?? context.coordinator.activeLayoutManager {
            lm.isDark = (colorScheme == .dark)
            lm.agentBrandAccent = TranscriptColorSystem.agentBrandAccent(source: sessionSource)
            lm.lineIndex = zip(lines.map(\.id), lines.compactMap { ranges[$0.id] }).map { TerminalLayoutManager.LineIndexEntry(id: $0.0, range: $0.1) }
            lm.blocks = buildBlockDecorations(ranges: ranges)
            updateLayoutManagerUnifiedFind(lm,
                                           query: unifiedFindQuery,
                                           occurrences: effectiveUnifiedMatchOccurrences,
                                           currentLineID: effectiveUnifiedCurrentMatchLineID)
            updateLayoutManagerLocalFind(lm,
                                         query: findQuery,
                                         currentLineID: effectiveFindCurrentMatchLineID,
                                         ranges: ranges)
        }

        // Ensure container tracks width
        let width = max(1, textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }

    private func updateUnifiedHighlights(in textView: NSTextView, context: Context, query: String, occurrences: [MatchOccurrence], currentLineID: Int?) {
        guard let lm = (textView.layoutManager as? TerminalLayoutManager) ?? context.coordinator.activeLayoutManager else { return }
        lm.isDark = (colorScheme == .dark)
        updateLayoutManagerUnifiedFind(lm,
                                       query: query,
                                       occurrences: occurrences,
                                       currentLineID: currentLineID)
        textView.setNeedsDisplay(textView.bounds)
        context.coordinator.lastUnifiedFindQuery = query
        context.coordinator.lastUnifiedMatchOccurrences = occurrences
        context.coordinator.lastUnifiedCurrentMatchLineID = currentLineID
    }

    private func updateLocalFindOverlay(in textView: NSTextView, context: Context, query: String, currentLineID: Int?) {
        guard let lm = (textView.layoutManager as? TerminalLayoutManager) ?? context.coordinator.activeLayoutManager else { return }
        lm.isDark = (colorScheme == .dark)
        updateLayoutManagerLocalFind(lm, query: query, currentLineID: currentLineID, ranges: context.coordinator.lineRanges)
        textView.setNeedsDisplay(textView.bounds)
        context.coordinator.lastFindQuery = query
        context.coordinator.lastFindCurrentMatchLineID = currentLineID
    }

    private func buildBlockDecorations(ranges: [Int: NSRange]) -> [TerminalLayoutManager.BlockDecoration] {
        var out: [TerminalLayoutManager.BlockDecoration] = []
        out.reserveCapacity(64)

        var startIdx: Int? = nil
        var currentBlock: Int? = nil
        var rolesInBlock: Set<TerminalLineRole> = []

        func isLocalCommandMetaBlock(start: Int, end: Int) -> Bool {
            guard start <= end else { return false }
            for line in lines[start...end] where line.role == .meta {
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("Local Command") {
                    return true
                }
            }
            return false
        }

        func isUserInterruptMetaBlock(start: Int, end: Int) -> Bool {
            guard start <= end else { return false }
            for line in lines[start...end] where line.role == .meta {
                if TerminalBuilder.isUserInterruptMarker(line.text) {
                    return true
                }
            }
            return false
        }

        func finishBlock(endIdx: Int) {
            guard let s = startIdx else { return }
            guard currentBlock != nil else { return }
            guard let startRange = ranges[lines[s].id] else { return }
            guard let endRange = ranges[lines[endIdx].id] else { return }

            let start = startRange.location
            let end = endRange.location + endRange.length
            guard end > start else { return }

            let kind: TerminalLayoutManager.BlockKind? = {
                if rolesInBlock.count == 1, rolesInBlock.contains(.meta) {
                    if isUserInterruptMetaBlock(start: s, end: endIdx) { return .userInterrupt }
                    return isLocalCommandMetaBlock(start: s, end: endIdx) ? .localCommand : nil
                }
                if rolesInBlock.contains(.error) { return .error }
                if rolesInBlock.contains(.toolInput) { return .toolCall }
                if rolesInBlock.contains(.toolOutput) { return .toolOutput }
                if rolesInBlock.contains(.user) { return .user }
                return .agent
            }()

            if let kind {
                out.append(.init(range: NSRange(location: start, length: end - start), kind: kind))
            }
        }

        for (idx, line) in lines.enumerated() {
            guard let blockIndex = line.blockIndex else {
                // Treat nil block index lines as a standalone “agent” block for consistent spacing, but only if non-empty.
                if startIdx != nil {
                    finishBlock(endIdx: idx - 1)
                    startIdx = nil
                    currentBlock = nil
                    rolesInBlock = []
                }
                if line.role != .meta, let r = ranges[line.id], r.length > 0 {
                    out.append(.init(range: r, kind: line.role == .user ? .user : .agent))
                }
                continue
            }

            if currentBlock == nil {
                currentBlock = blockIndex
                startIdx = idx
                rolesInBlock = [line.role]
                continue
            }

            if currentBlock != blockIndex {
                finishBlock(endIdx: idx - 1)
                currentBlock = blockIndex
                startIdx = idx
                rolesInBlock = [line.role]
                continue
            }

            rolesInBlock.insert(line.role)
        }

        if startIdx != nil {
            finishBlock(endIdx: lines.count - 1)
        }

        return out.sorted { $0.range.location < $1.range.location }
    }

    private func updateLayoutManagerUnifiedFind(_ lm: TerminalLayoutManager, query: String, occurrences: [MatchOccurrence], currentLineID: Int?) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !occurrences.isEmpty else {
            lm.matchLineIDs = []
            lm.currentMatchLineID = nil
            lm.matches = []
            return
        }

        let matches = occurrences.map { occurrence in
            TerminalLayoutManager.FindMatch(range: occurrence.range, isCurrentLine: occurrence.lineID == currentLineID)
        }
        lm.matchLineIDs = Set(occurrences.map(\.lineID))
        lm.currentMatchLineID = currentLineID
        lm.matches = matches.sorted { $0.range.location < $1.range.location }
    }

    private func updateLayoutManagerLocalFind(_ lm: TerminalLayoutManager, query: String, currentLineID: Int?, ranges: [Int: NSRange]) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let currentLineID else {
            lm.localFindRanges = []
            lm.localFindCurrentLineID = nil
            return
        }
        guard let base = ranges[currentLineID] else {
            lm.localFindRanges = []
            lm.localFindCurrentLineID = nil
            return
        }
        guard let line = lines.first(where: { $0.id == currentLineID }) else {
            lm.localFindRanges = []
            lm.localFindCurrentLineID = nil
            return
        }

        let text = line.text as NSString
        var out: [NSRange] = []
        out.reserveCapacity(4)
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: q, options: [.caseInsensitive], range: search)
            if found.location == NSNotFound { break }
            out.append(NSRange(location: base.location + found.location, length: found.length))
            let nextLoc = found.location + max(1, found.length)
            if nextLoc >= text.length { break }
            search = NSRange(location: nextLoc, length: text.length - nextLoc)
        }
        lm.localFindRanges = out
        lm.localFindCurrentLineID = out.isEmpty ? nil : currentLineID
    }

	private func buildAttributedString() -> (NSAttributedString, [Int: NSRange]) {
		        let attr = NSMutableAttributedString()
		        var ranges: [Int: NSRange] = [:]
		        ranges.reserveCapacity(lines.count)

			        let systemRegularFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
				        let systemUserFont = systemRegularFont
		        let monoRegularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                let monoSemiboldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)

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
	            // Card layout:
	            // - keep a consistent left/right internal padding (accounts for accent strip + 16px content padding)
	            // - rely on paragraph spacing for whitespace between cards
	            let cardInsetX: CGFloat = 8
	            let leftPaddingFromCardEdge: CGFloat = 20 // Accent strip + 16px padding
	            let rightPaddingFromCardEdge: CGFloat = 16
	            p.firstLineHeadIndent = cardInsetX + leftPaddingFromCardEdge
	            p.headIndent = cardInsetX + leftPaddingFromCardEdge
	            p.tailIndent = -(cardInsetX + rightPaddingFromCardEdge)
	            return p
	        }

	        let paragraph0 = paragraph(spacingBefore: 0)
	        let blockGap: CGFloat = 18
	        let paragraphGap = paragraph(spacingBefore: blockGap)
	        let paragraphMetaGap = paragraph(spacingBefore: 10)

        var previousBlockIndex: Int? = nil

        for (idx, line) in lines.enumerated() {
            let text = line.text
            let lineString = idx == lines.count - 1 ? text : text + "\n"
            let ns = lineString as NSString
            let range = NSRange(location: attr.length, length: ns.length)
            ranges[line.id] = range

            let isFirstLineOfBlock = idx == 0 || previousBlockIndex != line.blockIndex
            let isNewBlock = idx > 0 && previousBlockIndex != line.blockIndex
            previousBlockIndex = line.blockIndex

	            let paragraphStyle: NSParagraphStyle = {
	                guard isNewBlock else { return paragraph0 }
	                if line.role == .meta { return paragraphMetaGap }
	                return paragraphGap
	            }()

            let isPreambleUserLine: Bool = {
                guard line.role == .user else { return false }
                guard let blockIndex = line.blockIndex else { return false }
                return preambleUserBlockIndexes.contains(blockIndex)
            }()

	            let lineSwatch = swatch(for: line.role)

	            let baseFont: NSFont = {
	                if line.role == .toolInput {
                        return isFirstLineOfBlock ? monoSemiboldFont : monoRegularFont
                    }
		                if line.role == .user && !isPreambleUserLine { return systemUserFont }
	                return systemRegularFont
	            }()

		            let attributes: [NSAttributedString.Key: Any] = [
		                .font: baseFont,
		                .foregroundColor: lineSwatch.foreground,
		                .paragraphStyle: paragraphStyle
		            ]

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
