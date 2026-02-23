import Foundation

/// High-level role for a line in the terminal-style transcript.
enum TerminalLineRole: Sendable {
    case user          // user prompt
    case assistant     // model narrative
    case toolInput     // tool command invocation
    case toolOutput    // tool stdout / success output
    case error         // tool stderr / failures
    case meta          // timestamps, labels, misc meta
}

enum SemanticKind: Sendable, Hashable {
    case reviewSummary
    case plan
    case code
    case diff
}

/// Line-level representation of the terminal log.
///
/// - `id` is a stable, incremental index (0…N-1) used for scrolling and identity.
/// - `text` is the visible content for this line (no hard-coded CLI prefixes).
/// - `eventIndex` / `blockIndex` are optional back-links into the originating
///   `Session`/`LogicalBlock` structures when available.
struct TerminalLine: Identifiable, Sendable {
    let id: Int
    let text: String
    let role: TerminalLineRole

    let eventIndex: Int?
    let blockIndex: Int?
    let decorationGroupID: Int
    let semanticKind: SemanticKind?
}

/// Coarser-grained grouping of contiguous terminal lines with the same role.
///
/// Useful for navigation and minimap generation.
struct TerminalBlock {
    let role: TerminalLineRole
    let startLine: Int
    let endLine: Int
    let eventIndex: Int?
}

/// Model for a single visual segment in the minimap.
struct MinimapStrip: Identifiable {
    enum StripRole {
        case user
        case assistant
        case tool
        case error
    }

    let id = UUID()
    let role: StripRole
    let startRatio: Double
    let endRatio: Double
}

/// Builder that produces a line-level terminal representation from a `Session`.
struct TerminalBuilder {
    /// Build a flattened list of `TerminalLine` values for a given session.
    ///
    /// The text is intentionally free of CLI prefixes like `[out]`, `[error]`,
    /// or `> `. Those are applied in the view layer.
    static func buildLines(for session: Session,
                           showMeta: Bool = false,
                           enableReviewCards: Bool = true) -> [TerminalLine] {
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: showMeta)
        var lines: [TerminalLine] = []
        lines.reserveCapacity(blocks.count * 2)

        var nextID = 0
        var syntheticBlockIndex = -1

        for (blockIndex, block) in blocks.enumerated() {
            let baseRole: TerminalLineRole = {
                switch block.kind {
                case .user:
                    return .user
                case .assistant:
                    return .assistant
                case .toolCall:
                    return .toolInput
                case .toolOut:
                    // Treat tool output that looks like an error as error lines so
                    // the Errors filter surfaces them correctly.
                    return block.isErrorOutput ? .error : .toolOutput
                case .error:
                    return .error
                case .meta:
                    return .meta
                }
            }()

            var rawText = block.text
            if block.kind == .toolCall || block.kind == .toolOut {
                if let toolBlock = ToolTextBlockNormalizer.normalize(block: block, source: session.source) {
                    rawText = ToolTextBlockNormalizer.displayText(for: toolBlock)
                }
            }
            let segments = lineSegments(for: block,
                                        baseRole: baseRole,
                                        rawText: rawText,
                                        blockIndex: blockIndex,
                                        source: session.source,
                                        enableReviewCards: enableReviewCards,
                                        syntheticIndex: &syntheticBlockIndex)

            for segment in segments {
                var segmentText = segment.text
                if segmentText.isEmpty {
                    // Ensure tools and errors still render a placeholder line
                    if let tool = block.toolName, !tool.isEmpty {
                        segmentText = tool
                    }
                }

                let splitLines = segmentText.split(separator: "\n", omittingEmptySubsequences: false)
                if splitLines.isEmpty {
                    continue
                }

                for fragment in splitLines {
                    let lineText = String(fragment)
                    let line = TerminalLine(
                        id: nextID,
                        text: lineText,
                        role: segment.role,
                        eventIndex: nil,
                        blockIndex: segment.blockIndex,
                        decorationGroupID: segment.decorationGroupID,
                        semanticKind: segment.semanticKind
                    )
                    lines.append(line)
                    nextID += 1
                }
            }
        }

        return lines
    }

    /// Build both lines and coarse blocks in a single pass.
    ///
    /// This is currently unused by the UI but kept for future navigation
    /// features that may want block-level grouping.
    static func buildLinesAndBlocks(for session: Session,
                                    showMeta: Bool = false,
                                    enableReviewCards: Bool = true) -> ([TerminalLine], [TerminalBlock]) {
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: showMeta)
        var lines: [TerminalLine] = []
        var terminalBlocks: [TerminalBlock] = []
        lines.reserveCapacity(blocks.count * 2)
        terminalBlocks.reserveCapacity(blocks.count)

        var nextID = 0
        var syntheticBlockIndex = -1

        for (blockIndex, block) in blocks.enumerated() {
            let baseRole: TerminalLineRole = {
                switch block.kind {
                case .user:
                    return .user
                case .assistant:
                    return .assistant
                case .toolCall:
                    return .toolInput
                case .toolOut:
                    return block.isErrorOutput ? .error : .toolOutput
                case .error:
                    return .error
                case .meta:
                    return .meta
                }
            }()

            var rawText = block.text
            if block.kind == .toolCall || block.kind == .toolOut {
                if let toolBlock = ToolTextBlockNormalizer.normalize(block: block, source: session.source) {
                    rawText = ToolTextBlockNormalizer.displayText(for: toolBlock)
                }
            }
            let segments = lineSegments(for: block,
                                        baseRole: baseRole,
                                        rawText: rawText,
                                        blockIndex: blockIndex,
                                        source: session.source,
                                        enableReviewCards: enableReviewCards,
                                        syntheticIndex: &syntheticBlockIndex)

            for segment in segments {
                var segmentText = segment.text
                if segmentText.isEmpty {
                    if let tool = block.toolName, !tool.isEmpty {
                        segmentText = tool
                    }
                }

                let splitLines = segmentText.split(separator: "\n", omittingEmptySubsequences: false)
                if splitLines.isEmpty {
                    let line = TerminalLine(
                        id: nextID,
                        text: "",
                        role: segment.role,
                        eventIndex: nil,
                        blockIndex: segment.blockIndex,
                        decorationGroupID: segment.decorationGroupID,
                        semanticKind: segment.semanticKind
                    )
                    lines.append(line)
                    nextID += 1
                    continue
                }

                let startLine = nextID
                for fragment in splitLines {
                    let lineText = String(fragment)
                    let line = TerminalLine(
                        id: nextID,
                        text: lineText,
                        role: segment.role,
                        eventIndex: nil,
                        blockIndex: segment.blockIndex,
                        decorationGroupID: segment.decorationGroupID,
                        semanticKind: segment.semanticKind
                    )
                    lines.append(line)
                    nextID += 1
                }
                let endLine = nextID - 1
                let blockModel = TerminalBlock(role: segment.role, startLine: startLine, endLine: endLine, eventIndex: nil)
                terminalBlocks.append(blockModel)
            }
        }

        return (lines, terminalBlocks)
    }

    private struct LineSegment {
        let role: TerminalLineRole
        let text: String
        let blockIndex: Int?
        let decorationGroupID: Int
        let semanticKind: SemanticKind?
    }

    private struct SegmentSeed {
        let role: TerminalLineRole
        let text: String
        let blockIndex: Int?
        let semanticKind: SemanticKind?
    }

    private static func lineSegments(for block: SessionTranscriptBuilder.LogicalBlock,
                                     baseRole: TerminalLineRole,
                                     rawText: String,
                                     blockIndex: Int,
                                     source: SessionSource,
                                     enableReviewCards: Bool,
                                     syntheticIndex: inout Int) -> [LineSegment] {
        let seeds: [SegmentSeed]
        if enableReviewCards,
           let reviewText = reviewDisplayTextIfNeeded(block: block, source: source) {
            seeds = [SegmentSeed(role: .meta, text: reviewText, blockIndex: blockIndex, semanticKind: .reviewSummary)]
        } else if baseRole == .user, isUserInterruptMarker(rawText) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = trimmed.isEmpty ? rawText : trimmed
            let segment = SegmentSeed(role: .meta, text: text, blockIndex: syntheticIndex, semanticKind: nil)
            syntheticIndex -= 1
            seeds = [segment]
        } else if baseRole == .user,
                  source == .claude,
                  let split = splitClaudeLocalCommandSegments(from: rawText,
                                                              userBlockIndex: blockIndex,
                                                              syntheticIndex: &syntheticIndex) {
            seeds = split
        } else if baseRole == .user,
                  let split = splitSystemReminderSegments(from: rawText,
                                                          userBlockIndex: blockIndex,
                                                          syntheticIndex: &syntheticIndex) {
            seeds = split
        } else if baseRole == .assistant {
            seeds = assistantSemanticSegments(from: rawText,
                                             source: source,
                                             enableReviewCards: enableReviewCards).map {
                SegmentSeed(role: .assistant, text: $0.text, blockIndex: blockIndex, semanticKind: $0.semanticKind)
            }
        } else if baseRole == .toolOutput || baseRole == .error {
            seeds = toolOutputSemanticSegments(from: rawText,
                                               toolName: block.toolName,
                                               source: source).map {
                SegmentSeed(role: baseRole, text: $0.text, blockIndex: blockIndex, semanticKind: $0.semanticKind)
            }
        } else {
            seeds = [SegmentSeed(role: baseRole, text: rawText, blockIndex: blockIndex, semanticKind: nil)]
        }

        return seeds.enumerated().map { idx, seed in
            let effectiveBlockIndex = seed.blockIndex ?? blockIndex
            return LineSegment(role: seed.role,
                               text: seed.text,
                               blockIndex: seed.blockIndex,
                               decorationGroupID: decorationGroupID(blockIndex: effectiveBlockIndex, segmentOrdinal: idx),
                               semanticKind: seed.semanticKind)
        }
    }

    private struct SemanticTextSegment {
        let text: String
        let semanticKind: SemanticKind?
    }

    private static func assistantSemanticSegments(from text: String,
                                                  source: SessionSource,
                                                  enableReviewCards: Bool) -> [SemanticTextSegment] {
        semanticSegments(from: text,
                         source: source,
                         enableReviewCards: enableReviewCards,
                         includePlanBlocks: true,
                         includeReviewCards: true)
    }

    private static func toolOutputSemanticSegments(from text: String,
                                                   toolName: String?,
                                                   source: SessionSource) -> [SemanticTextSegment] {
        let parsed = semanticSegments(from: text,
                                      source: source,
                                      enableReviewCards: false,
                                      includePlanBlocks: false,
                                      includeReviewCards: false).map { segment -> SemanticTextSegment in
            switch segment.semanticKind {
            case .code, .diff, nil:
                return segment
            case .reviewSummary, .plan:
                return SemanticTextSegment(text: segment.text, semanticKind: nil)
            }
        }
        if parsed.contains(where: { $0.semanticKind == .code || $0.semanticKind == .diff }) {
            return parsed
        }
        if shouldTreatToolOutputAsCode(toolName: toolName, text: text) {
            return [SemanticTextSegment(text: text, semanticKind: .code)]
        }
        return parsed
    }

    private static func semanticSegments(from text: String,
                                         source: SessionSource,
                                         enableReviewCards: Bool,
                                         includePlanBlocks: Bool,
                                         includeReviewCards: Bool) -> [SemanticTextSegment] {
        if includeReviewCards, enableReviewCards,
           let review = InternalPayloadFormatter.parseReviewCard(rawText: text, source: source) {
            return [SemanticTextSegment(text: review.summaryText, semanticKind: .reviewSummary)]
        }

        var segments: [SemanticTextSegment] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let planMatch = includePlanBlocks ? nextPlanBlockRange(in: text, from: cursor) : nil
            let fenceMatch = CodeFenceParser.firstFence(in: text, from: cursor)

            let nextMatchStart: String.Index? = {
                switch (planMatch?.fullRange.lowerBound, fenceMatch?.range.lowerBound) {
                case let (p?, f?):
                    return min(p, f)
                case let (p?, nil):
                    return p
                case let (nil, f?):
                    return f
                case (nil, nil):
                    return nil
                }
            }()

            guard let start = nextMatchStart else {
                let remainder = String(text[cursor..<text.endIndex])
                if !remainder.isEmpty {
                    segments.append(.init(text: remainder, semanticKind: nil))
                }
                break
            }

            if cursor < start {
                let leading = String(text[cursor..<start])
                if !leading.isEmpty {
                    segments.append(.init(text: leading, semanticKind: nil))
                }
            }

            if let planMatch, planMatch.fullRange.lowerBound == start {
                let formatted = formattedPlanText(innerText: planMatch.innerText)
                segments.append(.init(text: formatted, semanticKind: .plan))
                cursor = planMatch.fullRange.upperBound
                continue
            }

            if let fenceMatch, fenceMatch.range.lowerBound == start {
                let isDiffFence = fenceMatch.model.language == "diff"
                if isDiffFence {
                    segments.append(.init(text: formattedDiffText(rawText: fenceMatch.model.body), semanticKind: .diff))
                } else {
                    segments.append(.init(text: formattedCodeText(block: fenceMatch.model), semanticKind: .code))
                }
                cursor = fenceMatch.range.upperBound
                continue
            }
        }

        if segments.isEmpty {
            return [SemanticTextSegment(text: text, semanticKind: nil)]
        }

        return segments.map {
            guard $0.semanticKind == nil, UnifiedDiffParser.looksLikeUnifiedDiff($0.text) else { return $0 }
            return SemanticTextSegment(text: formattedDiffText(rawText: $0.text), semanticKind: .diff)
        }
    }

    private static func shouldTreatToolOutputAsCode(toolName: String?, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "(no output)" else { return false }
        guard !UnifiedDiffParser.looksLikeUnifiedDiff(trimmed) else { return false }
        if looksLikeLineNumberedSourceDump(trimmed) {
            return true
        }
        guard isReadLikeToolName(toolName) else { return false }
        return trimmed.contains("\n")
    }

    private static func isReadLikeToolName(_ toolName: String?) -> Bool {
        guard let toolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !toolName.isEmpty else { return false }
        if toolName == "cat" { return true }

        let patterns = [
            "read",
            "read_file",
            "fileread",
            "get_file",
            "open_file",
            "view_file"
        ]
        return patterns.contains(where: { toolName.contains($0) })
    }

    private static func looksLikeLineNumberedSourceDump(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var matches = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.range(of: "^\\d+\\s*(\\u{2192}|\\||:)\\s", options: .regularExpression) != nil {
                matches += 1
                if matches >= 2 { return true }
            }
        }
        return false
    }

    private static func formattedPlanText(innerText: String) -> String {
        let wrapped = "<proposed_plan>\n\(innerText)\n</proposed_plan>"
        guard let parsed = PlanParser.parse(from: wrapped) else { return innerText }
        return parsed.body
    }

    private static func formattedCodeText(block: CodeFenceParser.CodeBlockModel) -> String {
        let header: String
        if let language = block.language, !language.isEmpty {
            header = "Code (\(language))"
        } else {
            header = "Code"
        }
        let trimmedBody = block.body.trimmingCharacters(in: .newlines)
        if trimmedBody.isEmpty {
            return header
        }
        return header + "\n" + trimmedBody
    }

    private static func formattedDiffText(rawText: String) -> String {
        guard let parsed = UnifiedDiffParser.parse(rawText) else { return rawText }
        if parsed.files.isEmpty {
            return parsed.rawText
        }
        return "Diff\n" + parsed.rawText
    }

    private static func nextPlanBlockRange(in text: String,
                                           from start: String.Index) -> (fullRange: Range<String.Index>, innerText: String)? {
        guard let open = text.range(of: "<proposed_plan>", range: start..<text.endIndex),
              let close = text.range(of: "</proposed_plan>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        let inner = String(text[open.upperBound..<close.lowerBound])
        return (fullRange: open.lowerBound..<close.upperBound, innerText: inner)
    }

    private static func decorationGroupID(blockIndex: Int, segmentOrdinal: Int) -> Int {
        (blockIndex &* 1000) &+ segmentOrdinal
    }

    private static func reviewDisplayTextIfNeeded(block: SessionTranscriptBuilder.LogicalBlock,
                                                  source: SessionSource) -> String? {
        guard source == .codex, block.kind == .user else { return nil }
        let text = block.text
        guard text.contains("<user_action>"),
              text.contains("<action>review</action>") else { return nil }
        let results = extractTag("results", from: text) ?? ""
        let trimmed = results.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Review"
        }
        return "Review\n" + trimmed
    }

    private static func splitSystemReminderSegments(from text: String,
                                                    userBlockIndex: Int,
                                                    syntheticIndex: inout Int) -> [SegmentSeed]? {
        guard text.contains("<system-reminder>") else { return nil }
        var segments: [SegmentSeed] = []
        var remainder: Substring = text[...]
        var found = false

        while let start = remainder.range(of: "<system-reminder>") {
            found = true
            let before = String(remainder[..<start.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(SegmentSeed(role: .user, text: before, blockIndex: userBlockIndex, semanticKind: nil))
            }
            let afterStart = start.upperBound
            guard let end = remainder.range(of: "</system-reminder>", range: afterStart..<remainder.endIndex) else {
                let rest = String(remainder)
                if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(SegmentSeed(role: .user, text: rest, blockIndex: userBlockIndex, semanticKind: nil))
                }
                remainder = remainder[remainder.endIndex...]
                break
            }
            let inner = String(remainder[afterStart..<end.lowerBound])
            let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let metaText = "System Reminder\n" + trimmed
                segments.append(SegmentSeed(role: .meta, text: metaText, blockIndex: syntheticIndex, semanticKind: nil))
                syntheticIndex -= 1
            }
            remainder = remainder[end.upperBound...]
        }

        let tail = String(remainder)
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(SegmentSeed(role: .user, text: tail, blockIndex: userBlockIndex, semanticKind: nil))
        }

        return found ? segments : nil
    }

    static func isUserInterruptMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let stripped = lower.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let normalized = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        guard !normalized.isEmpty else { return false }

        let markers: Set<String> = [
            "request interrupted by user",
            "request interrupted by user for tool use",
            "request interrupted by user for tool-use",
            "interrupted by user",
            "interrupted by user for tool use",
            "interrupted by user for tool-use",
            "request cancelled by user",
            "request cancelled by user for tool use",
            "request cancelled by user for tool-use",
            "request canceled by user",
            "request canceled by user for tool use",
            "request canceled by user for tool-use"
        ]
        return markers.contains(normalized)
    }

    private static func isClaudeLocalCommandTagLine(_ trimmed: String) -> Bool {
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<command-name>") { return true }
        if lower.hasPrefix("<command-message>") { return true }
        if lower.hasPrefix("<command-args>") { return true }
        if lower.hasPrefix("<local-command-") { return true }
        if lower.hasPrefix("</local-command-") { return true }
        return false
    }

    private static func splitClaudeLocalCommandSegments(from text: String,
                                                        userBlockIndex: Int,
                                                        syntheticIndex: inout Int) -> [SegmentSeed]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstNonEmpty = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        let firstLine = lines[firstNonEmpty].trimmingCharacters(in: .whitespacesAndNewlines)
        let isCaveat = firstLine.hasPrefix("Caveat:")
        let isTagStart = isClaudeLocalCommandTagLine(firstLine)
        guard isCaveat || isTagStart else { return nil }

        var endIndex = firstNonEmpty
        var idx = firstNonEmpty + 1
        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                endIndex = idx
                idx += 1
                continue
            }
            if isCaveat {
                if trimmed.hasPrefix("<") {
                    endIndex = idx
                    idx += 1
                    continue
                }
            } else if isClaudeLocalCommandTagLine(trimmed) {
                endIndex = idx
                idx += 1
                continue
            }
            break
        }

        var segments: [SegmentSeed] = []
        let leading = lines[..<firstNonEmpty].joined(separator: "\n")
        if !leading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(SegmentSeed(role: .user, text: leading, blockIndex: userBlockIndex, semanticKind: nil))
        }

        let preamble = lines[firstNonEmpty...endIndex].joined(separator: "\n")
        let trimmedPreamble = preamble.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreamble.isEmpty {
            let metaText = "Local Command\n" + trimmedPreamble
            segments.append(SegmentSeed(role: .meta, text: metaText, blockIndex: syntheticIndex, semanticKind: nil))
            syntheticIndex -= 1
        }

        if endIndex + 1 < lines.count {
            let tail = lines[(endIndex + 1)...].joined(separator: "\n")
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(SegmentSeed(role: .user, text: tail, blockIndex: userBlockIndex, semanticKind: nil))
            }
        }

        return segments.isEmpty ? nil : segments
    }

    private static func extractTag(_ name: String, from text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"),
              let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }
}

/// Builder that creates minimap strips from terminal lines.
struct TerminalMinimapBuilder {
    static func buildStrips(from lines: [TerminalLine]) -> [MinimapStrip] {
        guard !lines.isEmpty else {
            return []
        }

        let total = max(lines.count, 1)
        var strips: [MinimapStrip] = []

        var currentRole: MinimapStrip.StripRole?
        var currentStart: Int?

        func mappedRole(for role: TerminalLineRole) -> MinimapStrip.StripRole? {
            switch role {
            case .user:
                return .user
            case .assistant:
                return .assistant
            case .toolInput, .toolOutput:
                return .tool
            case .error:
                return .error
            case .meta:
                return nil
            }
        }

        func closeStrip(at index: Int) {
            guard let start = currentStart, let role = currentRole else { return }
            let endIndex = max(start, index)
            let startRatio = Double(start) / Double(total)
            let endRatio = Double(endIndex + 1) / Double(total)
            strips.append(MinimapStrip(role: role, startRatio: startRatio, endRatio: endRatio))
        }

        for (idx, line) in lines.enumerated() {
            guard let role = mappedRole(for: line.role) else {
                // Meta lines do not start or end strips; they effectively
                // belong to the surrounding segments.
                continue
            }
            if let activeRole = currentRole, let start = currentStart {
                if activeRole == role {
                    // Continue current strip.
                    continue
                } else {
                    // Close previous strip before starting a new one.
                    let endIndex = idx - 1
                    let startRatio = Double(start) / Double(total)
                    let endRatio = Double(endIndex + 1) / Double(total)
                    strips.append(MinimapStrip(role: activeRole, startRatio: startRatio, endRatio: endRatio))
                    currentRole = role
                    currentStart = idx
                }
            } else {
                currentRole = role
                currentStart = idx
            }
        }

        // Close trailing strip, if any.
        if currentRole != nil, let start = currentStart {
            let endIndex = lines.count - 1
            let startRatio = Double(start) / Double(total)
            let endRatio = Double(endIndex + 1) / Double(total)
            strips.append(MinimapStrip(role: currentRole!, startRatio: startRatio, endRatio: endRatio))
        }

        // Optional pass: merge adjacent strips of the same role to reduce noise.
        if strips.count <= 1 {
            return strips
        }

        var merged: [MinimapStrip] = []
        var last = strips[0]
        for strip in strips.dropFirst() {
            if strip.role == last.role {
                // Extend last strip.
                last = MinimapStrip(role: last.role, startRatio: last.startRatio, endRatio: strip.endRatio)
            } else {
                merged.append(last)
                last = strip
            }
        }
        merged.append(last)

        return merged
    }
}
