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
    static func buildLines(for session: Session, showMeta: Bool = false) -> [TerminalLine] {
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: showMeta)
        var lines: [TerminalLine] = []
        lines.reserveCapacity(blocks.count * 2)

        var nextID = 0

        for (blockIndex, block) in blocks.enumerated() {
            let role: TerminalLineRole = {
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

            // Use the block text directly; do not inject CLI prefixes here.
            var rawText = block.text
            if block.kind == .toolCall {
                rawText = toolCallDisplayText(block: block)
            }
            if rawText.isEmpty {
                // Ensure tools and errors still render a placeholder line
                if let tool = block.toolName, !tool.isEmpty {
                    rawText = tool
                }
            }

            let splitLines = rawText.split(separator: "\n", omittingEmptySubsequences: false)
            if splitLines.isEmpty {
                continue
            }

            for fragment in splitLines {
                let lineText = String(fragment)
                let line = TerminalLine(
                    id: nextID,
                    text: lineText,
                    role: role,
                    eventIndex: nil,
                    blockIndex: blockIndex
                )
                lines.append(line)
                nextID += 1
            }
        }

        return lines
    }

    /// Build both lines and coarse blocks in a single pass.
    ///
    /// This is currently unused by the UI but kept for future navigation
    /// features that may want block-level grouping.
    static func buildLinesAndBlocks(for session: Session, showMeta: Bool = false) -> ([TerminalLine], [TerminalBlock]) {
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: showMeta)
        var lines: [TerminalLine] = []
        var terminalBlocks: [TerminalBlock] = []
        lines.reserveCapacity(blocks.count * 2)
        terminalBlocks.reserveCapacity(blocks.count)

        var nextID = 0

        for (blockIndex, block) in blocks.enumerated() {
            let role: TerminalLineRole = {
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
            if block.kind == .toolCall {
                rawText = toolCallDisplayText(block: block)
            }
            let splitLines = rawText.split(separator: "\n", omittingEmptySubsequences: false)
            if splitLines.isEmpty {
                let line = TerminalLine(
                    id: nextID,
                    text: "",
                    role: role,
                    eventIndex: nil,
                    blockIndex: blockIndex
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
                    role: role,
                    eventIndex: nil,
                    blockIndex: blockIndex
                )
                lines.append(line)
                nextID += 1
            }
            let endLine = nextID - 1
            let blockModel = TerminalBlock(role: role, startLine: startLine, endLine: endLine, eventIndex: nil)
            terminalBlocks.append(blockModel)
        }

        return (lines, terminalBlocks)
    }

    private static func toolCallDisplayText(block: SessionTranscriptBuilder.LogicalBlock) -> String {
        guard let input = block.toolInput, !input.isEmpty else {
            return block.text
        }
        var pieces: [String] = []
        if let name = block.toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            pieces.append(name)
        }
        pieces.append(input)
        return pieces.joined(separator: " ")
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
