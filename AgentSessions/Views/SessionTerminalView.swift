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

private struct InlineSessionImage: Identifiable, Hashable, Sendable {
    let sessionID: String
    let sessionFileURL: URL
    let imageEventID: String
    let userPromptIndex: Int?
    let sessionImageIndex: Int
    let span: Base64ImageDataURLScanner.Span

    var id: String { "\(sessionID)-\(span.id)" }
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
    @AppStorage("InlineSessionImageThumbnailsEnabled") private var inlineSessionImageThumbnailsEnabled: Bool = true
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
    @State private var eventIDToUserLineID: [String: Int] = [:]
    @State private var pendingEventJumpID: String? = nil
    @State private var pendingUserPromptIndex: Int? = nil
    @State private var transcriptFocusToken: Int = 0
    @State private var imageHighlightLineID: Int? = nil
    @State private var imageHighlightToken: Int = 0
    @State private var roleNavPositions: [RoleToggle: Int] = [:]

    @State private var inlineImagesByUserBlockIndex: [Int: [InlineSessionImage]] = [:]
    @State private var inlineImagesSignature: Int = 0
    @State private var hasInlineImagesInSession: Bool = false
    @State private var inlineImagesVisibleInSession: Bool = true
    @State private var inlineImagesTask: Task<Void, Never>?
    @State private var selectedInlineImageUserBlockIndex: Int? = nil

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

    private var effectiveInlineImagesSignature: Int {
        var hasher = Hasher()
        hasher.combine(inlineImagesSignature)
        hasher.combine(inlineSessionImageThumbnailsEnabled)
        return hasher.finalize()
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
            refreshInlineImages()
        }
        .onDisappear {
            rebuildTask?.cancel()
            rebuildTask = nil
            inlineImagesTask?.cancel()
            inlineImagesTask = nil
        }
        .onChange(of: jumpToken) { _, _ in
            jumpToFirstPrompt()
        }
        .onChange(of: session.id) { _, _ in
            autoScrollSessionID = nil
            imageHighlightLineID = nil
            selectedInlineImageUserBlockIndex = nil
            rebuildLines(priority: .userInitiated)
            refreshInlineImages()
        }
        .onChange(of: session.events.count) { _, _ in
            refreshInlineImages()
        }
        .onChange(of: inlineSessionImageThumbnailsEnabled) { _, _ in
            // Avoid background scanning work when the feature is disabled.
            refreshInlineImages()
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
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSessionEventFromImages)) { n in
            guard let sid = n.object as? String, sid == session.id else { return }
            if let userPromptIndex = n.userInfo?["userPromptIndex"] as? Int {
                updateSelectedInlineImageBlockIndex(forUserPromptIndex: userPromptIndex)
                if !jumpToUserPromptIndex(userPromptIndex) {
                    pendingUserPromptIndex = userPromptIndex
                }
            } else if let eventID = n.userInfo?["eventID"] as? String {
                updateSelectedInlineImageBlockIndex(forEventID: eventID)
                if !jumpToEventID(eventID) {
                    pendingEventJumpID = eventID
                }
            } else {
                return
            }
            transcriptFocusToken &+= 1
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
                if (session.source == .codex || session.source == .claude), hasInlineImagesInSession {
                    imagesPill()
                }
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
                    inlineImagesEnabled: inlineSessionImageThumbnailsEnabled
                        && hasInlineImagesInSession
                        && (session.source == .codex || session.source == .claude)
                        && inlineImagesVisibleInSession,
                    inlineImagesByUserBlockIndex: inlineImagesByUserBlockIndex,
                    inlineImagesSignature: effectiveInlineImagesSignature,
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
                    imageHighlightLineID: imageHighlightLineID,
                    imageHighlightToken: imageHighlightToken,
                    focusRequestToken: transcriptFocusToken,
                    colorScheme: colorScheme,
                    monochrome: stripMonochrome
                )
                .onChange(of: unifiedFindToken) { _, _ in handleUnifiedFindRequest() }
                .onChange(of: findToken) { _, _ in handleFindRequest() }
            }
            .padding(.horizontal, 8)
        }
    }

    private func refreshInlineImages() {
        inlineImagesTask?.cancel()
        inlineImagesTask = nil

        guard inlineSessionImageThumbnailsEnabled else {
            hasInlineImagesInSession = false
            inlineImagesByUserBlockIndex = [:]
            inlineImagesSignature = 0
            return
        }

        guard session.source == .codex || session.source == .claude else {
            hasInlineImagesInSession = false
            inlineImagesByUserBlockIndex = [:]
            inlineImagesSignature = 0
            return
        }

        let sessionSnapshot = session
        let url = URL(fileURLWithPath: sessionSnapshot.filePath)

        inlineImagesTask = Task(priority: .utility) { @MainActor in
            let outcome = await Task.detached(priority: .utility) { () -> (Bool, [Int: [InlineSessionImage]], Int) in
                guard FileManager.default.fileExists(atPath: url.path) else { return (false, [:], 0) }

                let hasAny: Bool = {
                    switch sessionSnapshot.source {
                    case .codex:
                        return Base64ImageDataURLScanner.fileContainsBase64ImageDataURL(at: url, shouldCancel: { Task.isCancelled })
                    case .claude:
                        return ClaudeBase64ImageScanner.fileContainsUserBase64Image(at: url, shouldCancel: { Task.isCancelled })
                    default:
                        return false
                    }
                }()
                guard hasAny, !Task.isCancelled else { return (hasAny, [:], 0) }

                let located: [Base64ImageDataURLScanner.LocatedSpan] = {
                    do {
                        switch sessionSnapshot.source {
                        case .codex:
                            return try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: url, maxMatches: 400, shouldCancel: { Task.isCancelled })
                        case .claude:
                            return try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 400, shouldCancel: { Task.isCancelled })
                        default:
                            return []
                        }
                    } catch {
                        return []
                    }
                }()

                let filtered: [Base64ImageDataURLScanner.LocatedSpan] = {
                    switch sessionSnapshot.source {
                    case .codex:
                        return located.filter {
                            Base64ImageDataURLScanner.isLikelyImageURLContext(at: url, startOffset: $0.span.startOffset)
                        }
                    case .claude:
                        return located
                    default:
                        return []
                    }
                }()
                guard !filtered.isEmpty, !Task.isCancelled else { return (false, [:], 0) }

                let blocks = SessionTranscriptBuilder.coalescedBlocks(for: sessionSnapshot, includeMeta: false)
                var userEventIDToBlockIndex: [String: Int] = [:]
                userEventIDToBlockIndex.reserveCapacity(64)
                for (idx, block) in blocks.enumerated() where block.kind == .user {
                    userEventIDToBlockIndex[block.eventID] = idx
                }

                let userEventIndices: [Int] = sessionSnapshot.events.enumerated().compactMap { (idx, ev) in
                    ev.kind == .user ? idx : nil
                }

                func isPreambleUserEventIndex(_ idx: Int) -> Bool {
                    guard sessionSnapshot.source == .codex || sessionSnapshot.source == .droid || sessionSnapshot.source == .claude else { return false }
                    guard sessionSnapshot.events.indices.contains(idx) else { return false }
                    guard sessionSnapshot.events[idx].kind == .user else { return false }
                    return Session.isAgentsPreambleText(sessionSnapshot.events[idx].text ?? "")
                }

                func nearestUserEventIndex(for lineIndex: Int) -> Int? {
                    guard !userEventIndices.isEmpty else { return nil }

                    let prior = userEventIndices.filter { $0 <= lineIndex }
                    if let preferred = prior.last(where: { !isPreambleUserEventIndex($0) }) ?? prior.last {
                        return preferred
                    }

                    let after = userEventIndices.filter { $0 > lineIndex }
                    if let preferred = after.first(where: { !isPreambleUserEventIndex($0) }) ?? after.first {
                        return preferred
                    }
                    return nil
                }

                func userPromptIndexForLineIndex(_ lineIndex: Int) -> Int? {
                    guard lineIndex >= 0 else { return nil }
                    var userIndex: Int? = nil
                    var seenUsers = 0
                    for (idx, event) in sessionSnapshot.events.enumerated() {
                        if event.kind == .user {
                            if idx <= lineIndex {
                                userIndex = seenUsers
                            } else if userIndex == nil {
                                userIndex = seenUsers
                            }
                            seenUsers += 1
                        }
                        if idx > lineIndex, userIndex != nil { break }
                    }
                    return userIndex
                }

                var out: [Int: [InlineSessionImage]] = [:]
                out.reserveCapacity(min(16, userEventIDToBlockIndex.count))
                var sessionImageIndex = 1

                for item in filtered {
                    if Task.isCancelled { break }

                    guard let targetUserEventIndex = nearestUserEventIndex(for: item.lineIndex) else { continue }
                    let targetUserEventID = sessionSnapshot.events[targetUserEventIndex].id
                    guard let targetUserBlockIndex = userEventIDToBlockIndex[targetUserEventID] else { continue }

                    let imageEventID = SessionIndexer.eventID(forPath: url.path, index: item.lineIndex)
                    let userPromptIndex = userPromptIndexForLineIndex(item.lineIndex)

                    let img = InlineSessionImage(
                        sessionID: sessionSnapshot.id,
                        sessionFileURL: url,
                        imageEventID: imageEventID,
                        userPromptIndex: userPromptIndex,
                        sessionImageIndex: sessionImageIndex,
                        span: item.span
                    )
                    out[targetUserBlockIndex, default: []].append(img)
                    sessionImageIndex += 1
                }

                var hasher = Hasher()
                hasher.combine(out.values.reduce(0) { $0 + $1.count })
                if let first = located.first {
                    hasher.combine(first.span.startOffset)
                    hasher.combine(first.span.endOffset)
                }
                if let last = located.last {
                    hasher.combine(last.span.startOffset)
                    hasher.combine(last.span.endOffset)
                }

                return (true, out, hasher.finalize())
            }.value

            guard !Task.isCancelled else { return }
            hasInlineImagesInSession = !outcome.1.isEmpty
            inlineImagesByUserBlockIndex = outcome.1
            inlineImagesSignature = outcome.2
        }
    }

    private func imagesPill() -> some View {
        let isOn = inlineImagesVisibleInSession
        let imageBlockIndices = sortedInlineImageUserBlockIndices()
        let navDisabled = imageBlockIndices.isEmpty
        let status = inlineImageNavigationStatus()
        let countText = "\(formattedCount(status.current))/\(formattedCount(status.total))"

        return HStack(spacing: 6) {
            Button(action: {
                inlineImagesVisibleInSession.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn ? Color.secondary : Color.secondary.opacity(0.55))
                    Text("Images")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isOn ? .primary : .secondary)
                    Text(countText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .help(isOn ? "Hide inline images in this view" : "Show inline images in this view")

            HStack(spacing: 4) {
                ZStack {
                    Button(action: { navigateInlineImages(direction: -1) }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(navDisabled ? Color.secondary.opacity(0.35) : Color.secondary)
                    .disabled(navDisabled)
                }
                .help("Previous image prompt")

                ZStack {
                    Button(action: { navigateInlineImages(direction: 1) }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(navDisabled ? Color.secondary.opacity(0.35) : Color.secondary)
                    .disabled(navDisabled)
                }
                .help("Next image prompt")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func sortedInlineImageUserBlockIndices() -> [Int] {
        inlineImagesByUserBlockIndex
            .filter { !($0.value.isEmpty) }
            .map(\.key)
            .sorted()
    }

    private func inlineImageNavigationStatus() -> (current: Int, total: Int) {
        let blocks = sortedInlineImageUserBlockIndices()
        let total = blocks.count
        guard total > 0 else { return (0, 0) }

        if let selected = selectedInlineImageUserBlockIndex, let pos = blocks.firstIndex(of: selected) {
            return (pos + 1, total)
        }
        return (1, total)
    }

    private func navigateInlineImages(direction: Int) {
        let blocks = sortedInlineImageUserBlockIndices()
        guard !blocks.isEmpty else { return }

        let count = blocks.count

        func wrapIndex(_ value: Int) -> Int {
            (value % count + count) % count
        }

        let nextIndex: Int = {
            if let selected = selectedInlineImageUserBlockIndex, let pos = blocks.firstIndex(of: selected) {
                let step = direction >= 0 ? 1 : -1
                return wrapIndex(pos + step)
            }
            return direction >= 0 ? 0 : (count - 1)
        }()

        let targetUserBlockIndex = blocks[nextIndex]
        selectedInlineImageUserBlockIndex = targetUserBlockIndex

        guard let eventID = eventIDForUserBlockIndex(targetUserBlockIndex) else { return }
        _ = jumpToEventID(eventID)
    }

    private func eventIDForUserBlockIndex(_ userBlockIndex: Int) -> String? {
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        guard blocks.indices.contains(userBlockIndex) else { return nil }
        return blocks[userBlockIndex].eventID
    }

    private func updateSelectedInlineImageBlockIndex(forUserPromptIndex userPromptIndex: Int) {
        for (blockIndex, images) in inlineImagesByUserBlockIndex {
            if images.contains(where: { $0.userPromptIndex == userPromptIndex }) {
                selectedInlineImageUserBlockIndex = blockIndex
                return
            }
        }
    }

    private func updateSelectedInlineImageBlockIndex(forEventID eventID: String) {
        for (blockIndex, images) in inlineImagesByUserBlockIndex {
            if images.contains(where: { $0.imageEventID == eventID }) {
                selectedInlineImageUserBlockIndex = blockIndex
                return
            }
        }

        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        if let matchIndex = blocks.firstIndex(where: { $0.eventID == eventID }) {
            if !(inlineImagesByUserBlockIndex[matchIndex]?.isEmpty ?? true) {
                selectedInlineImageUserBlockIndex = matchIndex
            }
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
        let eventIDToUserLineID: [String: Int]
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
            eventIDToUserLineID = result.eventIDToUserLineID

            if let pendingIndex = pendingUserPromptIndex, jumpToUserPromptIndex(pendingIndex) {
                pendingUserPromptIndex = nil
            }
            if let pending = pendingEventJumpID, jumpToEventID(pending) {
                pendingEventJumpID = nil
            }

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

        var eventIDToUserLineID: [String: Int] = [:]
        if !blocks.isEmpty {
            let userBlockIndices = blocks.enumerated().compactMap { $0.element.kind == .user ? $0.offset : nil }

            func nearestUserBlockIndex(for idx: Int) -> Int? {
                let prior = userBlockIndices.filter { $0 <= idx }
                if let preferred = prior.last(where: { !preambleUserBlockIndexes.contains($0) }) ?? prior.last {
                    return preferred
                }
                let after = userBlockIndices.filter { $0 > idx }
                if let preferred = after.first(where: { !preambleUserBlockIndexes.contains($0) }) ?? after.first {
                    return preferred
                }
                return nil
            }

            for (idx, block) in blocks.enumerated() {
                let targetUserBlock: Int?
                if block.kind == .user {
                    targetUserBlock = idx
                } else {
                    targetUserBlock = nearestUserBlockIndex(for: idx)
                }
                guard let targetUserBlock,
                      let lineID = firstLineForBlock[targetUserBlock] else { continue }
                eventIDToUserLineID[block.eventID] = lineID
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
            errorLineIndices: messageIDs { $0 == .error },
            eventIDToUserLineID: eventIDToUserLineID
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

    private func jumpToUserPromptIndex(_ index: Int) -> Bool {
        guard index >= 0, index < userLineIndices.count else { return false }
        let lineID = userLineIndices[index]
        jumpToUserPrompt(lineID: lineID)
        imageHighlightLineID = lineID
        imageHighlightToken &+= 1
        return true
    }

    private func jumpToEventID(_ eventID: String) -> Bool {
        guard let lineID = eventIDToUserLineID[eventID] else { return false }
        jumpToUserPrompt(lineID: lineID)
        imageHighlightLineID = lineID
        imageHighlightToken &+= 1
        return true
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
	                                  weight: lineFontWeight,
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
	
	    private var lineFontWeight: Font.Weight {
	        if line.role == .user { return .semibold }
	        if line.role == .toolInput && isToolLabelLine(line.text) { return .semibold }
	        return .regular
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
            case userPreamble
            case userInterrupt
            case systemNotice
            case agent
            case toolCall
            case toolOutput
            case error
            case localCommand
            case imageAnchor
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
        case .user, .userPreamble:
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
	        case .systemNotice:
	            let base = NSColor.systemOrange
	            return BlockStyle(
	                fill: rgba(base, alpha: dark ? 0.10 : 0.03),
	                accent: rgba(base, alpha: dark ? 0.82 : 0.65),
	                accentWidth: 4,
	                paddingY: 8
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
        case .imageAnchor:
            let base: NSColor = NSColor.systemPurple
            return BlockStyle(
                fill: rgba(base, alpha: dark ? 0.12 : 0.05),
                accent: rgba(base, alpha: dark ? 0.78 : 0.60),
                accentWidth: 5,
                paddingY: 6
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
    let inlineImagesEnabled: Bool
    let inlineImagesByUserBlockIndex: [Int: [InlineSessionImage]]
    let inlineImagesSignature: Int
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
    let imageHighlightLineID: Int?
    let imageHighlightToken: Int
    let focusRequestToken: Int
    let colorScheme: ColorScheme
    let monochrome: Bool

    private final class InlineImageAttachment: NSTextAttachment {
        let imageID: String
        let fixedSize: NSSize

        init(imageID: String, fixedSize: NSSize) {
            self.imageID = imageID
            self.fixedSize = fixedSize
            super.init(data: nil, ofType: nil)
            self.attachmentCell = InlineImageAttachmentCell(thumbnail: nil, fixedSize: fixedSize)
        }

        required init?(coder: NSCoder) {
            self.imageID = ""
            self.fixedSize = .zero
            super.init(coder: coder)
            self.attachmentCell = InlineImageAttachmentCell(thumbnail: nil, fixedSize: .zero)
        }

        func setThumbnail(_ image: NSImage?) {
            if let cell = attachmentCell as? InlineImageAttachmentCell {
                cell.thumbnail = image
                if image != nil {
                    cell.isFailed = false
                }
            }
        }

        func setFailed(_ failed: Bool) {
            (attachmentCell as? InlineImageAttachmentCell)?.isFailed = failed
        }
    }

    private final class InlineImageAttachmentCell: NSTextAttachmentCell {
        var thumbnail: NSImage?
        var isFailed: Bool = false
        let fixedSize: NSSize

        init(thumbnail: NSImage?, fixedSize: NSSize) {
            self.thumbnail = thumbnail
            self.fixedSize = fixedSize
            super.init(imageCell: thumbnail)
        }

        required init(coder: NSCoder) {
            self.thumbnail = nil
            self.fixedSize = .zero
            super.init(coder: coder)
        }

        override func cellSize() -> NSSize {
            fixedSize
        }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
            let radius: CGFloat = 10
            let bg = NSColor.gray.withAlphaComponent(0.08)
            let stroke = NSColor.gray.withAlphaComponent(0.18)

            let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            bg.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()

            if let image = thumbnail {
                let inset: CGFloat = 10
                let target = cellFrame.insetBy(dx: inset, dy: inset)
                let imgSize = image.size
                if imgSize.width > 0, imgSize.height > 0 {
                    let scale = min(target.width / imgSize.width, target.height / imgSize.height)
                    let w = imgSize.width * scale
                    let h = imgSize.height * scale
                    let rect = NSRect(x: target.midX - w / 2, y: target.midY - h / 2, width: w, height: h)
                    image.draw(in: rect)
                }
                return
            }

            let symbolName = isFailed ? "photo.badge.exclamationmark" : "photo"
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            symbol?.isTemplate = true
            if let symbol {
                let tint = NSColor.secondaryLabelColor
                let symbolSize: CGFloat = min(28, min(cellFrame.width, cellFrame.height) * 0.35)
                let rect = NSRect(x: cellFrame.midX - symbolSize / 2, y: cellFrame.midY - symbolSize / 2, width: symbolSize, height: symbolSize)
                tint.set()
                symbol.draw(in: rect)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, AVSpeechSynthesizerDelegate {
        static let inlineImageIDKey = NSAttributedString.Key("AgentSessionsInlineImageID")

        private final class InlineImageHoverPreviewViewController: NSViewController {
            private let imageView = NSImageView()
            private let spinner = NSProgressIndicator()
            private let hintLabel = NSTextField(labelWithString: "Click to open Image Browser")
            private let errorLabel = NSTextField(labelWithString: "")
            private let labelsStack = NSStackView()

            override func loadView() {
                let content = NSView()

                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 8
                imageView.layer?.masksToBounds = true

                spinner.translatesAutoresizingMaskIntoConstraints = false
                spinner.style = .spinning
                spinner.controlSize = .small

                hintLabel.translatesAutoresizingMaskIntoConstraints = false
                hintLabel.font = NSFont.systemFont(ofSize: 11)
                hintLabel.textColor = .secondaryLabelColor

                errorLabel.translatesAutoresizingMaskIntoConstraints = false
                errorLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                errorLabel.textColor = .systemRed
                errorLabel.lineBreakMode = .byWordWrapping
                errorLabel.maximumNumberOfLines = 2
                errorLabel.isHidden = true

                labelsStack.translatesAutoresizingMaskIntoConstraints = false
                labelsStack.orientation = .vertical
                labelsStack.alignment = .leading
                labelsStack.distribution = .fill
                labelsStack.spacing = 2
                labelsStack.addArrangedSubview(errorLabel)
                labelsStack.addArrangedSubview(hintLabel)

                content.addSubview(imageView)
                content.addSubview(spinner)
                content.addSubview(labelsStack)

                NSLayoutConstraint.activate([
                    imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
                    imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                    imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

                    labelsStack.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
                    labelsStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                    labelsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                    labelsStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

                    spinner.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                    spinner.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),

                    imageView.widthAnchor.constraint(equalToConstant: 360),
                    imageView.heightAnchor.constraint(equalToConstant: 260),
                ])

                view = content
            }

            func setState(image: NSImage?, error: String? = nil) {
                imageView.image = image
                if let error {
                    errorLabel.stringValue = error
                    errorLabel.isHidden = false
                    spinner.stopAnimation(nil)
                    return
                }

                errorLabel.stringValue = ""
                errorLabel.isHidden = true
                if image == nil {
                    spinner.startAnimation(nil)
                } else {
                    spinner.stopAnimation(nil)
                }
            }
        }

        var lineRanges: [Int: NSRange] = [:]
        var lineRoles: [Int: TerminalLineRole] = [:]
        var lastLinesSignature: Int = 0
        var lastFontSize: CGFloat = 0
        var lastMonochrome: Bool = false
        var lastColorScheme: ColorScheme = .light
        var lastInlineImagesSignature: Int = 0
        var lastScrollToken: Int = 0
        var lastRoleNavScrollToken: Int = 0
        var lastFocusRequestToken: Int = 0
        var lastImageHighlightToken: Int = 0

        var lastUnifiedFindQuery: String = ""
        var lastUnifiedMatchOccurrences: [MatchOccurrence] = []
        var lastUnifiedCurrentMatchLineID: Int? = nil

        var lastFindQuery: String = ""
        var lastFindCurrentMatchLineID: Int? = nil

        var lines: [TerminalLine] = []
        var orderedLineRanges: [NSRange] = []
        var orderedLineIDs: [Int] = []

        private weak var activeTextView: NSTextView?
        private weak var activeScrollView: NSScrollView?
        weak var activeLayoutManager: TerminalLayoutManager?
        private var activeBlockText: String = ""
        private let speechSynthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()
        private let speechQueue = DispatchQueue(label: "com.agentsessions.speechSynthesizer", qos: .default)
        private var isSpeaking: Bool = false

        var inlineImagesEnabled: Bool = false
        private var inlineImagesByID: [String: InlineSessionImage] = [:]
        private var inlineAttachmentsByID: [String: InlineImageAttachment] = [:]
        private var inlineAttachmentRangesByID: [String: NSRange] = [:]
        private var inlineThumbnailCache: [String: NSImage] = [:]
        private var inlineThumbnailTasks: [String: Task<Void, Never>] = [:]
        private var inlinePreviewFileCache: [String: URL] = [:]
        private var inlineHoverPreviewCache: [String: NSImage] = [:]
        private var inlineDecodeFailedIDs: Set<String> = []
        private var inlineHoverTask: Task<Void, Never>? = nil
        private var inlineHoverPopover: NSPopover? = nil
        private var inlineHoverController: InlineImageHoverPreviewViewController? = nil
        private var inlineHoverImageID: String? = nil
        private var inlineContextImageID: String? = nil
        private var scrollIdleWorkItem: DispatchWorkItem? = nil
        private var scrollObserver: NSObjectProtocol? = nil

        override init() {
            super.init()
            speechSynthesizer.delegate = self
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            inlineThumbnailTasks.values.forEach { $0.cancel() }
            inlineHoverTask?.cancel()
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
            closeInlineHoverPopover()

            if inlineImagesEnabled,
               let ts = textView.textStorage,
               charIndex >= 0,
               charIndex < ts.length,
               let id = ts.attribute(Self.inlineImageIDKey, at: charIndex, effectiveRange: nil) as? String {
                inlineContextImageID = id
                return inlineImageContextMenu()
            }
            inlineContextImageID = nil

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
            let sel = tv.selectedRange()
            guard sel.length > 0 else { return }
            let s = (tv.string as NSString).substring(with: sel)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(s, forType: .string)
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

        // MARK: - Inline images

        func installScrollObserver(scrollView: NSScrollView, textView: TerminalTextView) {
            if activeScrollView !== scrollView {
                if let scrollObserver {
                    NotificationCenter.default.removeObserver(scrollObserver)
                }
                scrollObserver = nil
            }

            activeScrollView = scrollView
            activeTextView = textView

            if scrollObserver == nil {
                scrollView.contentView.postsBoundsChangedNotifications = true
                scrollObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.closeInlineHoverPopover()
                    self?.scheduleIdleThumbnailLoad(delay: 0.2)
                }
            }

            // Initial load after first render.
            scheduleIdleThumbnailLoad(delay: 0.05)
        }

        func updateInlineImages(enabled: Bool, imagesByUserBlockIndex: [Int: [InlineSessionImage]], signature: Int, textView: TerminalTextView) {
            inlineImagesEnabled = enabled
            lastInlineImagesSignature = signature

            if !enabled {
                inlineImagesByID = [:]
                inlineAttachmentsByID = [:]
                inlineAttachmentRangesByID = [:]
                inlineDecodeFailedIDs = []
                inlineThumbnailTasks.values.forEach { $0.cancel() }
                inlineThumbnailTasks = [:]
                scrollIdleWorkItem?.cancel()
                scrollIdleWorkItem = nil
                closeInlineHoverPopover()
                return
            }

            var byID: [String: InlineSessionImage] = [:]
            for images in imagesByUserBlockIndex.values {
                for img in images {
                    byID[img.id] = img
                }
            }
            inlineImagesByID = byID

            indexInlineImageAttachments(in: textView)
        }

        private func indexInlineImageAttachments(in textView: TerminalTextView) {
            inlineAttachmentsByID = [:]
            inlineAttachmentRangesByID = [:]

            guard let ts = textView.textStorage, ts.length > 0 else { return }
            let full = NSRange(location: 0, length: ts.length)
            ts.enumerateAttribute(Self.inlineImageIDKey, in: full, options: []) { value, range, _ in
                guard let id = value as? String else { return }
                inlineAttachmentRangesByID[id] = range
                if let att = ts.attribute(.attachment, at: range.location, effectiveRange: nil) as? InlineImageAttachment {
                    inlineAttachmentsByID[id] = att
                    if let cached = inlineThumbnailCache[id] {
                        att.setThumbnail(cached)
                    }
                    if inlineDecodeFailedIDs.contains(id) {
                        att.setFailed(true)
                    }
                }
            }
        }

        private func scheduleIdleThumbnailLoad(delay: TimeInterval) {
            scrollIdleWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.loadVisibleThumbnails(prefetchViewports: 1)
            }
            scrollIdleWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        private func loadVisibleThumbnails(prefetchViewports: Int) {
            guard inlineImagesEnabled else { return }
            guard let tv = activeTextView, let scroll = activeScrollView else { return }
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            guard let ts = tv.textStorage, ts.length > 0 else { return }

            var rect = scroll.contentView.bounds
            if prefetchViewports > 0 {
                let pad = rect.height * CGFloat(prefetchViewports)
                rect = rect.insetBy(dx: 0, dy: -pad)
            }

            let glyphRange = lm.glyphRange(forBoundingRect: rect, in: tc)
            let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

            var ids: Set<String> = []
            ts.enumerateAttribute(Self.inlineImageIDKey, in: charRange, options: []) { value, _, _ in
                if let id = value as? String {
                    ids.insert(id)
                }
            }

            for id in ids {
                startThumbnailLoad(id: id)
            }
        }

        private func startThumbnailLoad(id: String) {
            guard inlineImagesEnabled else { return }
            guard !inlineDecodeFailedIDs.contains(id) else { return }
            guard inlineThumbnailCache[id] == nil else { return }
            guard inlineThumbnailTasks[id] == nil else { return }
            guard let meta = inlineImagesByID[id] else { return }

            let maxDecodedBytes = 25 * 1024 * 1024
            let maxPixels = 480
            let url = meta.sessionFileURL
            let span = meta.span

            inlineThumbnailTasks[id] = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                let img: NSImage? = await Task.detached(priority: .utility) {
                    do {
                        let decoded = try CodexSessionImagePayload.decodeImageData(url: url,
                                                                                  span: span,
                                                                                  maxDecodedBytes: maxDecodedBytes,
                                                                                  shouldCancel: { Task.isCancelled })
                        return CodexSessionImagePayload.makeThumbnail(from: decoded, maxPixelSize: maxPixels)
                    } catch {
                        return nil
                    }
                }.value

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inlineThumbnailTasks[id] = nil
                    guard let img else {
                        self.markInlineImageDecodeFailed(id: id)
                        return
                    }
                    self.inlineThumbnailCache[id] = img
                    self.inlineAttachmentsByID[id]?.setThumbnail(img)
                    if let tv = self.activeTextView, let range = self.inlineAttachmentRangesByID[id] {
                        tv.layoutManager?.invalidateDisplay(forCharacterRange: range)
                    }
                }
            }
        }

        @MainActor
        private func markInlineImageDecodeFailed(id: String) {
            inlineDecodeFailedIDs.insert(id)
            inlineThumbnailCache[id] = nil
            inlineHoverPreviewCache[id] = nil
            inlinePreviewFileCache[id] = nil
            inlineAttachmentsByID[id]?.setFailed(true)

            if inlineHoverImageID == id {
                inlineHoverController?.setState(image: nil, error: "Unable to decode image.")
            }

            if let tv = activeTextView, let range = inlineAttachmentRangesByID[id] {
                tv.layoutManager?.invalidateDisplay(forCharacterRange: range)
                tv.needsDisplay = true
            }
        }

        @MainActor
        func handleInlineImageDoubleClick(id: String) {
            guard inlineImagesEnabled else { return }
            closeInlineHoverPopover()
            guard let meta = inlineImagesByID[id] else { return }
            NotificationCenter.default.post(
                name: .showImagesForInlineImage,
                object: meta.sessionID,
                userInfo: ["selectedItemID": id]
            )
        }

        @MainActor
        func handleInlineImageHover(id: String?, anchorRect: NSRect, in view: NSView) {
            guard inlineImagesEnabled else {
                closeInlineHoverPopover()
                return
            }
            guard let id else {
                closeInlineHoverPopover()
                return
            }
            if inlineDecodeFailedIDs.contains(id) {
                if inlineHoverPopover == nil {
                    let popover = NSPopover()
                    popover.behavior = .transient
                    popover.animates = false
                    inlineHoverPopover = popover
                }
                if inlineHoverController == nil {
                    let controller = InlineImageHoverPreviewViewController()
                    inlineHoverController = controller
                    inlineHoverPopover?.contentViewController = controller
                }
                inlineHoverImageID = id
                inlineHoverController?.setState(image: nil, error: "Unable to decode image.")
                if inlineHoverPopover?.isShown != true {
                    inlineHoverPopover?.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
                }
                return
            }

            let didChangeID = inlineHoverImageID != id
            if didChangeID {
                inlineHoverImageID = id
                inlineHoverTask?.cancel()
            }

            if inlineHoverPopover == nil {
                let popover = NSPopover()
                popover.behavior = .transient
                popover.animates = false
                inlineHoverPopover = popover
            }

            if inlineHoverController == nil {
                let controller = InlineImageHoverPreviewViewController()
                inlineHoverController = controller
                inlineHoverPopover?.contentViewController = controller
            }

            startThumbnailLoad(id: id)
            let img = inlineHoverPreviewCache[id] ?? inlineThumbnailCache[id]
            inlineHoverController?.setState(image: img)

            if didChangeID, inlineHoverPopover?.isShown == true {
                inlineHoverPopover?.performClose(nil)
            }
            if inlineHoverPopover?.isShown != true {
                inlineHoverPopover?.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
            }

            guard inlineHoverPreviewCache[id] == nil else { return }
            guard let meta = inlineImagesByID[id] else { return }

            let maxDecodedBytes = 25 * 1024 * 1024
            let maxPixels = 1200
            let url = meta.sessionFileURL
            let span = meta.span

            inlineHoverTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                let preview: NSImage? = await Task.detached(priority: .utility) {
                    do {
                        let decoded = try CodexSessionImagePayload.decodeImageData(url: url,
                                                                                  span: span,
                                                                                  maxDecodedBytes: maxDecodedBytes,
                                                                                  shouldCancel: { Task.isCancelled })
                        return CodexSessionImagePayload.makeThumbnail(from: decoded, maxPixelSize: maxPixels)
                    } catch {
                        return nil
                    }
                }.value

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard let preview else {
                        self.markInlineImageDecodeFailed(id: id)
                        return
                    }
                    self.inlineHoverPreviewCache[id] = preview
                    if self.inlineHoverImageID == id {
                        self.inlineHoverController?.setState(image: preview)
                    }
                }
            }
        }

        private func closeInlineHoverPopover() {
            inlineHoverTask?.cancel()
            inlineHoverTask = nil
            inlineHoverImageID = nil
            inlineHoverPopover?.performClose(nil)
        }

        private func ensureInlinePreviewFileURL(id: String) async -> URL? {
            if let url = inlinePreviewFileCache[id] { return url }
            guard let meta = inlineImagesByID[id] else { return nil }

            let maxDecodedBytes = 25 * 1024 * 1024
            let sourceURL = meta.sessionFileURL
            let span = meta.span
            let ext = CodexSessionImagePayload.suggestedFileExtension(for: span.mediaType)
            let filename = "image-\(String(meta.sessionID.prefix(6)))-\(meta.sessionImageIndex).\(ext)"

            do {
                // This is triggered by explicit user actions (context menu / Preview / copy / save).
                // Avoid priority inversions by doing the decode work on the current task's priority.
                let decoded = try CodexSessionImagePayload.decodeImageData(url: sourceURL,
                                                                          span: span,
                                                                          maxDecodedBytes: maxDecodedBytes,
                                                                          shouldCancel: { Task.isCancelled })
                if Task.isCancelled { return nil }

                let tempRoot = FileManager.default.temporaryDirectory
                let dir = tempRoot.appendingPathComponent("AgentSessions/InlineImagePreview", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let destination = uniqueDestinationURL(in: dir, filename: filename)
                try decoded.write(to: destination, options: [.atomic])

                await MainActor.run { [weak self] in
                    self?.inlinePreviewFileCache[id] = destination
                }
                return destination
            } catch {
                await MainActor.run { [weak self] in
                    self?.markInlineImageDecodeFailed(id: id)
                }
                return nil
            }
        }

        @MainActor
        private func openInPreviewApp(_ url: URL) {
            guard let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                NSWorkspace.shared.open(url)
                return
            }

            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: config, completionHandler: nil)
        }

	        private func inlineImageContextMenu() -> NSMenu {
	            let out = NSMenu(title: "Image")
	            out.autoenablesItems = false

	            let openPreview = NSMenuItem(title: "Open in Preview", action: #selector(openInlineImageInPreview(_:)), keyEquivalent: "")
	            openPreview.target = self
	            out.addItem(openPreview)

	            out.addItem(.separator())

	            let copyPath = NSMenuItem(title: "Copy Image Path (for CLI agent)", action: #selector(copyInlineImagePath(_:)), keyEquivalent: "")
	            copyPath.target = self
	            out.addItem(copyPath)

	            let copyImage = NSMenuItem(title: "Copy Image", action: #selector(copyInlineImage(_:)), keyEquivalent: "")
	            copyImage.target = self
	            out.addItem(copyImage)

	            out.addItem(.separator())

	            let saveDownloads = NSMenuItem(title: "Save to Downloads", action: #selector(saveInlineImageToDownloads(_:)), keyEquivalent: "")
	            saveDownloads.target = self
	            out.addItem(saveDownloads)

            let save = NSMenuItem(title: "Save…", action: #selector(saveInlineImageWithPanel(_:)), keyEquivalent: "")
            save.target = self
            out.addItem(save)

            return out
        }

        @objc private func openInlineImageInPreview(_ sender: Any?) {
            guard let id = inlineContextImageID else { return }
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                guard let url = await self.ensureInlinePreviewFileURL(id: id) else { return }
                await MainActor.run {
                    self.openInPreviewApp(url)
                }
            }
        }

        @objc private func copyInlineImagePath(_ sender: Any?) {
            guard let id = inlineContextImageID, let meta = inlineImagesByID[id] else { return }
            let maxDecodedBytes = 25 * 1024 * 1024
            let sourceURL = meta.sessionFileURL
            let span = meta.span
            let ext = CodexSessionImagePayload.suggestedFileExtension(for: span.mediaType)
            let filename = "image-\(String(meta.sessionID.prefix(6)))-\(meta.sessionImageIndex).\(ext)"

            Task(priority: .userInitiated) {
                do {
                    let decoded = try await Task.detached(priority: .utility) {
                        try CodexSessionImagePayload.decodeImageData(url: sourceURL,
                                                                     span: span,
                                                                     maxDecodedBytes: maxDecodedBytes,
                                                                     shouldCancel: { Task.isCancelled })
                    }.value
                    if Task.isCancelled { return }

                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSessions/ImageClipboard", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let destination = uniqueDestinationURL(in: dir, filename: filename)
                    try decoded.write(to: destination, options: [.atomic])

                    await MainActor.run {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.writeObjects([destination as NSURL])
                        pasteboard.setString(destination.path, forType: .string)
                    }
                } catch {
                    // Best-effort copy; no UI error.
                }
            }
        }

        @objc private func copyInlineImage(_ sender: Any?) {
            guard let id = inlineContextImageID, let meta = inlineImagesByID[id] else { return }
            let maxDecodedBytes = 25 * 1024 * 1024
            let sourceURL = meta.sessionFileURL
            let span = meta.span

            Task(priority: .userInitiated) {
                do {
                    let decoded = try await Task.detached(priority: .utility) {
                        try CodexSessionImagePayload.decodeImageData(url: sourceURL,
                                                                     span: span,
                                                                     maxDecodedBytes: maxDecodedBytes,
                                                                     shouldCancel: { Task.isCancelled })
                    }.value
                    if Task.isCancelled { return }
                    guard let image = NSImage(data: decoded) else { return }

                    await MainActor.run {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.writeObjects([image])
                        if let tiff = image.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            pasteboard.setData(png, forType: .png)
                        }
                    }
                } catch {
                    // Best-effort copy; no UI error.
                }
            }
        }

        @objc private func saveInlineImageToDownloads(_ sender: Any?) {
            guard let id = inlineContextImageID, let meta = inlineImagesByID[id] else { return }
            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
            let maxDecodedBytes = 25 * 1024 * 1024
            let sourceURL = meta.sessionFileURL
            let span = meta.span
            let ext = CodexSessionImagePayload.suggestedFileExtension(for: span.mediaType)
            let filename = "image-\(String(meta.sessionID.prefix(6)))-\(meta.sessionImageIndex).\(ext)"
            let destination = uniqueDestinationURL(in: downloads, filename: filename)

            Task(priority: .userInitiated) {
                do {
                    let decoded = try await Task.detached(priority: .utility) {
                        try CodexSessionImagePayload.decodeImageData(url: sourceURL,
                                                                     span: span,
                                                                     maxDecodedBytes: maxDecodedBytes,
                                                                     shouldCancel: { Task.isCancelled })
                    }.value
                    if Task.isCancelled { return }
                    try decoded.write(to: destination, options: [.atomic])
                } catch {
                    // Best-effort save; no UI error.
                }
            }
        }

        @objc private func saveInlineImageWithPanel(_ sender: Any?) {
            guard let id = inlineContextImageID, let meta = inlineImagesByID[id] else { return }

            let span = meta.span
            let ext = CodexSessionImagePayload.suggestedFileExtension(for: span.mediaType)
            let utType = CodexSessionImagePayload.suggestedUTType(for: span.mediaType)
            let filename = "image-\(String(meta.sessionID.prefix(6)))-\(meta.sessionImageIndex).\(ext)"

            let panel = NSSavePanel()
            panel.allowedContentTypes = [utType]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = filename

            let maxDecodedBytes = 25 * 1024 * 1024
            let sourceURL = meta.sessionFileURL
            let sourceSpan = span

            let destinationKeyWindow = NSApp.keyWindow
            let onComplete: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let destination = panel.url else { return }
                Task(priority: .userInitiated) {
                    do {
                        let decoded = try await Task.detached(priority: .utility) {
                            try CodexSessionImagePayload.decodeImageData(url: sourceURL,
                                                                         span: sourceSpan,
                                                                         maxDecodedBytes: maxDecodedBytes,
                                                                         shouldCancel: { Task.isCancelled })
                        }.value
                        if Task.isCancelled { return }
                        try decoded.write(to: destination, options: [.atomic])
                    } catch {
                        // Best-effort save; no UI error.
                    }
                }
            }

            if let win = destinationKeyWindow {
                panel.beginSheetModal(for: win, completionHandler: onComplete)
            } else {
                onComplete(panel.runModal())
            }
        }

        private func uniqueDestinationURL(in dir: URL, filename: String) -> URL {
            let base = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            var candidate = dir.appendingPathComponent(filename)
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                let next = "\(base)-\(counter).\(ext)"
                candidate = dir.appendingPathComponent(next)
                counter += 1
            }
            return candidate
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

	    final class TerminalTextView: NSTextView {
	        weak var inlineImageCoordinator: Coordinator?

	        private var mouseDownLocationInWindow: NSPoint? = nil
	        private var selectionAtMouseDown: NSRange = NSRange(location: 0, length: 0)
	        private var hoverTrackingArea: NSTrackingArea? = nil
	
	        private func inlineImageHit(at point: NSPoint) -> (id: String, range: NSRange)? {
	            guard let ts = textStorage, ts.length > 0 else { return nil }
	            guard let lm = layoutManager, let tc = textContainer else { return nil }

	            // Layout manager coordinates are in text-container space (not view space).
	            let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)

	            let idx = lm.characterIndex(for: containerPoint, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
	            guard idx != NSNotFound else { return nil }

	            func matchAt(_ c: Int) -> (id: String, range: NSRange)? {
	                guard c >= 0 && c < ts.length else { return nil }
	                var effectiveRange = NSRange(location: NSNotFound, length: 0)
	                guard let id = ts.attribute(Coordinator.inlineImageIDKey, at: c, effectiveRange: &effectiveRange) as? String,
	                      effectiveRange.location != NSNotFound else { return nil }
	                let glyphs = lm.glyphRange(forCharacterRange: effectiveRange, actualCharacterRange: nil)
	                var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
	                rect = rect.insetBy(dx: -4, dy: -4)
	                guard rect.contains(containerPoint) else { return nil }
	                return (id, effectiveRange)
	            }

	            // Prefer direct point->character mapping, but allow small index drift around attachments.
	            if let hit = matchAt(idx) ?? matchAt(idx - 1) ?? matchAt(idx + 1) {
	                return hit
	            }

	            // Fallback: scan a small neighborhood and use bounding boxes for confirmation.
	            let start = max(0, idx - 8)
	            let end = min(ts.length, idx + 8)
	            let scan = NSRange(location: start, length: max(0, end - start))
	            if scan.length == 0 { return nil }

	            var found: (id: String, range: NSRange)? = nil
	            ts.enumerateAttribute(Coordinator.inlineImageIDKey, in: scan, options: []) { value, range, stop in
	                guard let id = value as? String else { return }
	                let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
	                var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
	                rect = rect.insetBy(dx: -4, dy: -4)
	                if rect.contains(containerPoint) {
	                    found = (id, range)
	                    stop.pointee = true
	                }
	            }
	            return found
	        }

	        private func inlineImageID(at point: NSPoint) -> String? {
	            inlineImageHit(at: point)?.id
	        }
	
	        private func inlineImageIDWithEffectiveRange(at point: NSPoint) -> (id: String, range: NSRange)? {
	            inlineImageHit(at: point)
	        }

	        override func mouseDown(with event: NSEvent) {
	            let handledModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
	            if event.type == .leftMouseDown,
	               handledModifiers.isEmpty {
	                let point = convert(event.locationInWindow, from: nil)
	                if let id = inlineImageID(at: point) {
	                    Task { @MainActor in
	                        // Single click opens the Image Browser for the current session and selects this image.
	                        inlineImageCoordinator?.handleInlineImageDoubleClick(id: id)
	                    }
	                    return
	                }
	            }

	            if event.type == .leftMouseDown {
	                mouseDownLocationInWindow = event.locationInWindow
	                selectionAtMouseDown = selectedRange()
	            } else {
	                mouseDownLocationInWindow = nil
	            }
	            super.mouseDown(with: event)
	        }

		        override func mouseUp(with event: NSEvent) {
	            super.mouseUp(with: event)

	            guard event.type == .leftMouseUp else { return }
	            guard !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option) else { return }

            if selectedRange().length > 0, selectedRange() != selectionAtMouseDown {
                return
            }

	            if let down = mouseDownLocationInWindow {
	                let dx = abs(down.x - event.locationInWindow.x)
	                let dy = abs(down.y - event.locationInWindow.y)
	                if dx > 3 || dy > 3 { return }
	            }

		            let point = convert(event.locationInWindow, from: nil)
		            if let hit = inlineImageIDWithEffectiveRange(at: point),
                       let lm = layoutManager,
                       let tc = textContainer {
                        let charRange = NSRange(location: hit.range.location, length: max(1, hit.range.length))
                        let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                        rect.origin.x += textContainerOrigin.x
                        rect.origin.y += textContainerOrigin.y
                        rect = rect.insetBy(dx: -4, dy: -4)
		                Task { @MainActor in
		                    inlineImageCoordinator?.handleInlineImageHover(id: hit.id, anchorRect: rect, in: self)
		                }
		            }
	        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
            }

            let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
            let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverTrackingArea = area
        }

	        override func mouseMoved(with event: NSEvent) {
	            super.mouseMoved(with: event)

	            guard let inlineImageCoordinator else { return }
	            let point = convert(event.locationInWindow, from: nil)
	            guard let hit = inlineImageIDWithEffectiveRange(at: point) else {
	                Task { @MainActor in
	                    inlineImageCoordinator.handleInlineImageHover(id: nil, anchorRect: .zero, in: self)
	                }
	                return
	            }
	            guard let lm = layoutManager, let tc = textContainer else { return }
	            let charRange = NSRange(location: hit.range.location, length: max(1, hit.range.length))
	            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
	            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
	            rect.origin.x += textContainerOrigin.x
	            rect.origin.y += textContainerOrigin.y
	            rect = rect.insetBy(dx: -4, dy: -4)

	            Task { @MainActor in
	                inlineImageCoordinator.handleInlineImageHover(id: hit.id, anchorRect: rect, in: self)
	            }
	        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            Task { @MainActor in
                inlineImageCoordinator?.handleInlineImageHover(id: nil, anchorRect: .zero, in: self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
                if event.modifierFlags.contains(.shift) {
                    window?.selectPreviousKeyView(nil)
                } else {
                    window?.selectNextKeyView(nil)
                }
                return
            }
            super.keyDown(with: event)
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

        let textView = TerminalTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindPanel = true
        textView.delegate = context.coordinator
        textView.inlineImageCoordinator = context.coordinator
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
        context.coordinator.installScrollObserver(scrollView: scroll, textView: textView)
        applyContent(to: textView, context: context)
        context.coordinator.lastLinesSignature = signature(for: lines)
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastMonochrome = monochrome
        context.coordinator.lastColorScheme = colorScheme
        context.coordinator.lastInlineImagesSignature = inlineImagesSignature
        context.coordinator.lastUnifiedFindQuery = unifiedFindQuery
        context.coordinator.lastUnifiedMatchOccurrences = effectiveUnifiedMatchOccurrences
        context.coordinator.lastUnifiedCurrentMatchLineID = effectiveUnifiedCurrentMatchLineID
        context.coordinator.lastFindQuery = findQuery
        context.coordinator.lastFindCurrentMatchLineID = effectiveFindCurrentMatchLineID
        context.coordinator.lastRoleNavScrollToken = roleNavScrollToken
        context.coordinator.lastFocusRequestToken = focusRequestToken
        context.coordinator.lastImageHighlightToken = imageHighlightToken
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? TerminalTextView else { return }
        context.coordinator.installScrollObserver(scrollView: nsView, textView: tv)

        let lineSig = signature(for: lines)
        let fontChanged = abs((context.coordinator.lastFontSize) - fontSize) > 0.1
        let monochromeChanged = context.coordinator.lastMonochrome != monochrome
        let schemeChanged = context.coordinator.lastColorScheme != colorScheme
        let inlineChanged = context.coordinator.lastInlineImagesSignature != inlineImagesSignature
        let inlineEnabledChanged = context.coordinator.inlineImagesEnabled != inlineImagesEnabled
        let needsReload = lineSig != context.coordinator.lastLinesSignature || fontChanged || monochromeChanged || schemeChanged || inlineChanged || inlineEnabledChanged

        if needsReload {
            applyContent(to: tv, context: context)
            context.coordinator.lastLinesSignature = lineSig
            context.coordinator.lastFontSize = fontSize
            context.coordinator.lastMonochrome = monochrome
            context.coordinator.lastColorScheme = colorScheme
            context.coordinator.lastInlineImagesSignature = inlineImagesSignature
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

        if context.coordinator.lastImageHighlightToken != imageHighlightToken {
            context.coordinator.lastImageHighlightToken = imageHighlightToken
            if let lm = (tv.layoutManager as? TerminalLayoutManager) ?? context.coordinator.activeLayoutManager {
                lm.blocks = buildBlockDecorations(ranges: context.coordinator.lineRanges)
                tv.setNeedsDisplay(tv.bounds)
            }
        }

        if context.coordinator.lastFocusRequestToken != focusRequestToken {
            context.coordinator.lastFocusRequestToken = focusRequestToken
            if let window = tv.window {
                window.makeFirstResponder(tv)
            }
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
        // Ensure container tracks width (also used for inline thumbnail sizing).
        let width = max(1, textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width)

        let (attr, ranges) = buildAttributedString(containerWidth: width)
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

        if let tv = textView as? TerminalTextView {
            context.coordinator.updateInlineImages(enabled: inlineImagesEnabled,
                                                  imagesByUserBlockIndex: inlineImagesByUserBlockIndex,
                                                  signature: inlineImagesSignature,
                                                  textView: tv)
        }

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
	
	        func isTurnAbortedMetaBlock(start: Int, end: Int) -> Bool {
	            guard start <= end else { return false }
	            for line in lines[start...end] where line.role == .meta {
	                let lower = line.text.lowercased()
	                if lower.contains("tag: turn_aborted") { return true }
	            }
	            return false
	        }

	        func finishBlock(endIdx: Int, blockIndex: Int?) {
	            guard let s = startIdx else { return }
	            guard currentBlock != nil else { return }
	            guard let startRange = ranges[lines[s].id] else { return }
            guard let endRange = ranges[lines[endIdx].id] else { return }

            let start = startRange.location
            let end = endRange.location + endRange.length
            guard end > start else { return }

	            let isPreambleUserBlock = blockIndex.map { preambleUserBlockIndexes.contains($0) } ?? false
	            let kind: TerminalLayoutManager.BlockKind? = {
	                if rolesInBlock.count == 1, rolesInBlock.contains(.meta) {
	                    if isUserInterruptMetaBlock(start: s, end: endIdx) { return .userInterrupt }
	                    if isTurnAbortedMetaBlock(start: s, end: endIdx) { return .systemNotice }
	                    return isLocalCommandMetaBlock(start: s, end: endIdx) ? .localCommand : nil
	                }
	                if rolesInBlock.contains(.error) { return .error }
	                if rolesInBlock.contains(.toolInput) { return .toolCall }
                if rolesInBlock.contains(.toolOutput) { return .toolOutput }
                if rolesInBlock.contains(.user) { return isPreambleUserBlock ? .userPreamble : .user }
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
                    finishBlock(endIdx: idx - 1, blockIndex: currentBlock)
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
                finishBlock(endIdx: idx - 1, blockIndex: currentBlock)
                currentBlock = blockIndex
                startIdx = idx
                rolesInBlock = [line.role]
                continue
            }

            rolesInBlock.insert(line.role)
        }

        if startIdx != nil {
            finishBlock(endIdx: lines.count - 1, blockIndex: currentBlock)
        }

        if let highlightLineID = imageHighlightLineID, let range = ranges[highlightLineID] {
            out.append(.init(range: range, kind: .imageAnchor))
        }

        return out.sorted {
            if $0.range.location == $1.range.location && $0.range.length == $1.range.length {
                if $0.kind == .imageAnchor { return false }
                if $1.kind == .imageAnchor { return true }
            }
            return $0.range.location < $1.range.location
        }
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

    private func buildAttributedString(containerWidth: CGFloat) -> (NSAttributedString, [Int: NSRange]) {
        let attr = NSMutableAttributedString()
        var ranges: [Int: NSRange] = [:]
        ranges.reserveCapacity(lines.count)

        let systemRegularFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let systemUserFont: NSFont = {
            let userFontSize = fontSize + 1
            if let optima = NSFont(name: "Optima", size: userFontSize) {
                let descriptor = optima.fontDescriptor.addingAttributes([
                    .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]
                ])
                if let weighted = NSFont(descriptor: descriptor, size: userFontSize) {
                    return weighted
                }
            }
            return NSFont.systemFont(ofSize: userFontSize, weight: .semibold)
        }()
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

        let cardInsetX: CGFloat = 8
        let leftPaddingFromCardEdge: CGFloat = 20 // Accent strip + 16px padding
        let rightPaddingFromCardEdge: CGFloat = 16
        let cardLeftIndent = cardInsetX + leftPaddingFromCardEdge
        let cardRightInset = cardInsetX + rightPaddingFromCardEdge

        func paragraph(spacingBefore: CGFloat) -> NSParagraphStyle {
            let p = (baseParagraph.mutableCopy() as? NSMutableParagraphStyle) ?? baseParagraph
            p.paragraphSpacingBefore = spacingBefore
            p.firstLineHeadIndent = cardLeftIndent
            p.headIndent = cardLeftIndent
            p.tailIndent = -(cardRightInset)
            return p
        }

        let paragraph0 = paragraph(spacingBefore: 0)
        let paragraphGap = paragraph(spacingBefore: 18)
        let paragraphMetaGap = paragraph(spacingBefore: 10)

        let contentWidth = max(1, containerWidth - (cardLeftIndent + cardRightInset))
        let thumbSpacing: CGFloat = 12
        let thumbMaxColumns: Int = 5
        let thumbMinWidthForColumnChoice: CGFloat = 140
        let thumbColumns: Int = {
            let raw = Int(floor((contentWidth + thumbSpacing) / (thumbMinWidthForColumnChoice + thumbSpacing)))
            return min(thumbMaxColumns, max(1, raw))
        }()
        let rawThumbWidth: CGFloat = floor((contentWidth - (thumbSpacing * CGFloat(max(0, thumbColumns - 1)))) / CGFloat(thumbColumns))
        let thumbSize: CGFloat = min(220, max(110, rawThumbWidth))

        let thumbParagraph: NSParagraphStyle = {
            let p = (baseParagraph.mutableCopy() as? NSMutableParagraphStyle) ?? baseParagraph
            p.paragraphSpacingBefore = 8
            p.firstLineHeadIndent = cardLeftIndent
            p.headIndent = cardLeftIndent
            p.tailIndent = -(cardRightInset)
            p.tabStops = []
            if thumbColumns > 1 {
                p.defaultTabInterval = thumbSize + thumbSpacing
                p.tabStops = (1..<thumbColumns).map { col in
                    let tabLoc = cardLeftIndent + (CGFloat(col) * (thumbSize + thumbSpacing))
                    return NSTextTab(textAlignment: .left, location: tabLoc)
                }
            }
            return p
        }()

        func appendInlineThumbnails(_ images: [InlineSessionImage]) {
            guard inlineImagesEnabled else { return }
            guard !images.isEmpty else { return }

            var idx = 0
            while idx < images.count {
                let rowStart = idx
                let rowEnd = min(images.count, idx + thumbColumns)
                let rowImages = Array(images[rowStart..<rowEnd])
                idx = rowEnd

                let row = NSMutableAttributedString()
                let rowAttributes: [NSAttributedString.Key: Any] = [
                    .font: systemRegularFont,
                    .paragraphStyle: thumbParagraph
                ]

                for (col, image) in rowImages.enumerated() {
                    if col > 0 {
                        row.append(NSAttributedString(string: "\t", attributes: rowAttributes))
                    }
                    let attachment = InlineImageAttachment(imageID: image.id, fixedSize: NSSize(width: thumbSize, height: thumbSize))
                    let frag = NSMutableAttributedString(attachment: attachment)
                    frag.addAttribute(Coordinator.inlineImageIDKey, value: image.id, range: NSRange(location: 0, length: frag.length))
                    row.append(frag)
                }

                row.append(NSAttributedString(string: "\n", attributes: rowAttributes))
                row.addAttributes(rowAttributes, range: NSRange(location: 0, length: row.length))
                attr.append(row)
            }
        }

        var previousBlockIndex: Int? = nil

        for (idx, line) in lines.enumerated() {
            let blockIndex = line.blockIndex
            let isFirstLineOfBlock = idx == 0 || previousBlockIndex != blockIndex
            let isNewBlock = idx > 0 && previousBlockIndex != blockIndex
            previousBlockIndex = blockIndex

            let isLastLineOfBlock: Bool = {
                if idx == lines.count - 1 { return true }
                return lines[idx + 1].blockIndex != blockIndex
            }()

            let shouldAppendInlineImages: Bool = {
                guard inlineImagesEnabled else { return false }
                guard line.role == .user else { return false }
                guard isLastLineOfBlock, let blockIndex else { return false }
                return !(inlineImagesByUserBlockIndex[blockIndex]?.isEmpty ?? true)
            }()

            let paragraphStyle: NSParagraphStyle = {
                guard isNewBlock else { return paragraph0 }
                if line.role == .meta { return paragraphMetaGap }
                return paragraphGap
            }()

            let isPreambleUserLine: Bool = {
                guard line.role == .user else { return false }
                guard let blockIndex else { return false }
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

            let needsTrailingNewline = (idx != lines.count - 1) || shouldAppendInlineImages
            let lineString = line.text + (needsTrailingNewline ? "\n" : "")

            let start = attr.length
            let attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: lineSwatch.foreground,
                .paragraphStyle: paragraphStyle
            ]
            attr.append(NSAttributedString(string: lineString, attributes: attributes))

            if shouldAppendInlineImages, let blockIndex, let images = inlineImagesByUserBlockIndex[blockIndex] {
                appendInlineThumbnails(images)
            }

            ranges[line.id] = NSRange(location: start, length: attr.length - start)
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
