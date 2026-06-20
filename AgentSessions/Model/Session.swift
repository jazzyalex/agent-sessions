import Foundation

public enum SessionSurface: String, Codable, Sendable {
    case cli
    case desktop
    case vscode
    case subagent
    case other
    case unknown

    public var displayName: String {
        switch self {
        case .cli: return "CLI"
        case .desktop: return "Desktop"
        case .vscode: return "VS Code"
        case .subagent: return "Subagent"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }
}

public typealias CodexSessionSurface = SessionSurface

public enum SessionRelationshipKind: String, Codable, Sendable {
    case root
    case subagent
    case sideChat
}

public struct Session: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let source: SessionSource
    public let startTime: Date?
    public let endTime: Date?
    public let model: String?
    public let filePath: String
    public let fileSizeBytes: Int?
    public let eventCount: Int
    public let events: [SessionEvent]
    // True when a session is effectively "housekeeping": no assistant output and no meaningful prompt content
    // (for example Codex rollouts that only captured preamble, or Claude local-command-only transcripts).
    public var isHousekeeping: Bool = false
    // Lightweight commands count from DB (when events are not loaded)
    public let lightweightCommands: Int?

    // Lightweight session metadata (when events is empty)
    public let lightweightCwd: String?
    public let lightweightRepoName: String?
    public let lightweightTitle: String?
    public let customTitle: String?
    public let codexInternalSessionIDHint: String?
    public let codexOriginator: String?
    public let codexSource: String?
    public let codexSurface: CodexSessionSurface?
    public let originator: String?
    public let originSource: String?
    public let surface: SessionSurface?
    public let reasoningEffort: String?

    // Subagent hierarchy
    public let parentSessionID: String?   // Raw ID of parent session (UUID for Claude/Codex, ses_ID for OpenCode)
    public let subagentType: String?      // e.g. "Explore", "review", "thread_spawn", "general"
    public let relationshipKind: SessionRelationshipKind?
    public var effectiveRelationshipKind: SessionRelationshipKind {
        relationshipKind ?? ((parentSessionID != nil || subagentType != nil) ? .subagent : .root)
    }
    public var isSubagent: Bool { effectiveRelationshipKind == .subagent }
    public var isSideChat: Bool { effectiveRelationshipKind == .sideChat }

    // Runtime UI state (not persisted in session files)
    public var isFavorite: Bool = false

    // Soft-deletion support (OpenClaw auto-deletes after 30 days)
    public var isDeleted: Bool { deletedAt != nil }
    public let deletedAt: Date?

    // Default initializer for full sessions
    public init(id: String,
                source: SessionSource = .codex,
                startTime: Date?,
                endTime: Date?,
                model: String?,
                filePath: String,
                fileSizeBytes: Int? = nil,
                eventCount: Int,
                events: [SessionEvent],
                isHousekeeping: Bool = false,
                codexInternalSessionIDHint: String? = nil,
                parentSessionID: String? = nil,
                subagentType: String? = nil,
                relationshipKind: SessionRelationshipKind? = nil,
                customTitle: String? = nil,
                codexOriginator: String? = nil,
                codexSource: String? = nil,
                codexSurface: CodexSessionSurface? = nil,
                originator: String? = nil,
                originSource: String? = nil,
                surface: SessionSurface? = nil,
                reasoningEffort: String? = nil,
                deletedAt: Date? = nil) {
        self.id = id
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.model = model
        self.filePath = filePath
        self.fileSizeBytes = fileSizeBytes
        self.eventCount = eventCount
        self.events = events
        self.isHousekeeping = isHousekeeping
        self.lightweightCwd = nil
        self.lightweightRepoName = nil
        self.lightweightTitle = nil
        self.customTitle = customTitle
        self.codexInternalSessionIDHint = codexInternalSessionIDHint
        self.codexOriginator = codexOriginator
        self.codexSource = codexSource
        self.codexSurface = codexSurface
        self.originator = originator ?? codexOriginator
        self.originSource = originSource ?? codexSource
        self.surface = surface ?? codexSurface
        self.reasoningEffort = reasoningEffort
        self.lightweightCommands = nil
        self.parentSessionID = parentSessionID
        self.subagentType = subagentType
        self.relationshipKind = relationshipKind
        self.isFavorite = false
        self.deletedAt = deletedAt
    }

    // Lightweight session initializer
    public init(id: String,
                source: SessionSource = .codex,
                startTime: Date?,
                endTime: Date?,
                model: String?,
                filePath: String,
                fileSizeBytes: Int? = nil,
                eventCount: Int,
                events: [SessionEvent],
                cwd: String?,
                repoName: String?,
                lightweightTitle: String?,
                lightweightCommands: Int? = nil,
                isHousekeeping: Bool = false,
                codexInternalSessionIDHint: String? = nil,
                parentSessionID: String? = nil,
                subagentType: String? = nil,
                relationshipKind: SessionRelationshipKind? = nil,
                customTitle: String? = nil,
                codexOriginator: String? = nil,
                codexSource: String? = nil,
                codexSurface: CodexSessionSurface? = nil,
                originator: String? = nil,
                originSource: String? = nil,
                surface: SessionSurface? = nil,
                reasoningEffort: String? = nil,
                deletedAt: Date? = nil) {
        self.id = id
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.model = model
        self.filePath = filePath
        self.fileSizeBytes = fileSizeBytes
        self.eventCount = eventCount
        self.events = events
        self.isHousekeeping = isHousekeeping
        self.lightweightCwd = cwd
        self.lightweightRepoName = repoName
        self.lightweightTitle = lightweightTitle
        self.customTitle = customTitle
        self.codexInternalSessionIDHint = codexInternalSessionIDHint
        self.codexOriginator = codexOriginator
        self.codexSource = codexSource
        self.codexSurface = codexSurface
        self.originator = originator ?? codexOriginator
        self.originSource = originSource ?? codexSource
        self.surface = surface ?? codexSurface
        self.reasoningEffort = reasoningEffort
        self.lightweightCommands = lightweightCommands
        self.parentSessionID = parentSessionID
        self.subagentType = subagentType
        self.relationshipKind = relationshipKind
        self.isFavorite = false
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case startTime
        case endTime
        case model
        case filePath
        case fileSizeBytes
        case eventCount
        case events
        case lightweightCwd
        case lightweightRepoName
        case lightweightTitle
        case lightweightCommands
        case codexInternalSessionIDHint
        case codexOriginator
        case codexSource
        case codexSurface
        case originator
        case originSource
        case surface
        case reasoningEffort
        case parentSessionID
        case subagentType
        case relationshipKind
        case customTitle
        case deletedAt
        // isFavorite intentionally excluded (runtime only)
        // isHousekeeping intentionally excluded (derived at parse/index time)
        // isDeleted is a computed property (deletedAt != nil)
    }

    public static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id &&
            lhs.source == rhs.source &&
            lhs.startTime == rhs.startTime &&
            lhs.endTime == rhs.endTime &&
            lhs.model == rhs.model &&
            lhs.filePath == rhs.filePath &&
            lhs.fileSizeBytes == rhs.fileSizeBytes &&
            lhs.eventCount == rhs.eventCount &&
            lhs.events.count == rhs.events.count &&
            sameEventEdge(lhs.events.first, rhs.events.first) &&
            sameEventEdge(lhs.events.last, rhs.events.last) &&
            lhs.isHousekeeping == rhs.isHousekeeping &&
            lhs.lightweightCommands == rhs.lightweightCommands &&
            lhs.lightweightCwd == rhs.lightweightCwd &&
            lhs.lightweightRepoName == rhs.lightweightRepoName &&
            lhs.lightweightTitle == rhs.lightweightTitle &&
            lhs.customTitle == rhs.customTitle &&
            lhs.codexInternalSessionIDHint == rhs.codexInternalSessionIDHint &&
            lhs.codexOriginator == rhs.codexOriginator &&
            lhs.codexSource == rhs.codexSource &&
            lhs.codexSurface == rhs.codexSurface &&
            lhs.originator == rhs.originator &&
            lhs.originSource == rhs.originSource &&
            lhs.surface == rhs.surface &&
            lhs.reasoningEffort == rhs.reasoningEffort &&
            lhs.parentSessionID == rhs.parentSessionID &&
            lhs.subagentType == rhs.subagentType &&
            lhs.relationshipKind == rhs.relationshipKind &&
            lhs.isFavorite == rhs.isFavorite &&
            lhs.deletedAt == rhs.deletedAt
    }

    private static func sameEventEdge(_ lhs: SessionEvent?, _ rhs: SessionEvent?) -> Bool {
        lhs?.id == rhs?.id &&
            lhs?.timestamp == rhs?.timestamp &&
            lhs?.kind == rhs?.kind &&
            lhs?.role == rhs?.role
    }

    public var shortID: String { String(id.prefix(6)) }

    public var isCodexDesktopSession: Bool {
        guard source == .codex else { return false }
        if (surface ?? codexSurface) == .desktop { return true }

        let normalizedOriginator = (originator ?? codexOriginator)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedOriginator == "codex desktop" ||
            normalizedOriginator?.contains("desktop") == true ||
            normalizedOriginator?.contains("app") == true
    }

    public var isClaudeDesktopSession: Bool {
        guard source == .claude else { return false }
        if surface == .desktop { return true }

        let normalizedOriginator = originator?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedOriginSource = originSource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedOriginator == "claude desktop" { return true }
        if normalizedOriginSource == "local-agent-mode" || normalizedOriginSource == "claude-desktop" { return true }

        let components = URL(fileURLWithPath: filePath).standardizedFileURL.pathComponents
        return components.contains("local-agent-mode-sessions") &&
            components.contains(".claude") &&
            components.contains("projects")
    }

    public var isArchivedCodexDesktopSession: Bool {
        guard source == .codex else { return false }
        guard URL(fileURLWithPath: filePath).standardizedFileURL.pathComponents.contains("archived_sessions") else {
            return false
        }

        return isCodexDesktopSession
    }

    public var firstUserPreview: String? {
        events.first(where: { $0.kind == .user })?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Lightweight title for high-frequency list rendering/sorting paths.
    // Avoids expensive preamble heuristics that are better suited for detail views.
    public var listTitle: String {
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if let light = lightweightTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !light.isEmpty {
            return light
        }
        var sawFirstUser = false
        var firstAssistantIndex: Int?
        var firstToolName: String?
        for index in events.indices {
            switch events[index].kind {
            case .user:
                guard !sawFirstUser else { continue }
                sawFirstUser = true
                if let user = events[index].text?.collapsedWhitespace(), !user.isEmpty {
                    return user
                }
            case .assistant:
                if firstAssistantIndex == nil {
                    firstAssistantIndex = index
                }
            case .tool_call:
                if firstToolName == nil,
                   let toolName = events[index].toolName,
                   !toolName.isEmpty {
                    firstToolName = toolName
                }
            default:
                break
            }
        }
        if let firstAssistantIndex,
           let assistant = events[firstAssistantIndex].text?.collapsedWhitespace(),
           !assistant.isEmpty {
            return assistant
        }
        if let firstToolName { return firstToolName }
        return "No prompt"
    }

    // Derived human-friendly title for the session row.
    // Use improved Codex-style filtering with fallbacks for robustness
    public var title: String {
        // Custom title from /rename takes absolute precedence
        if let custom = customTitle, !custom.isEmpty {
            return custom
        }
        let defaults = UserDefaults.standard
        let skipPreamble = (defaults.object(forKey: "SkipAgentsPreamble") == nil)
            ? true
            : defaults.bool(forKey: "SkipAgentsPreamble")

        // 0) Lightweight session: use extracted title (but avoid preamble-only garbage)
        if events.isEmpty, let lightTitle = lightweightTitle, !lightTitle.isEmpty {
            let trimmed = lightTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if skipPreamble {
                if source == .claude, let tail = Self.claudeLocalCommandPromptTail(from: trimmed) {
                    let collapsed = tail.collapsedWhitespace()
                    if !collapsed.isEmpty { return collapsed }
                }
                if source == .claude, Self.looksLikeClaudeLocalCommandTranscript(trimmed) {
                    return "No prompt"
                }
                if Self.looksLikeAgentsPreamble(trimmed) {
                    return "No prompt"
                }
            }
            return trimmed
        }

        // 1) Use Codex-style filtered title (best quality)
        if let codexTitle = codexPreviewTitle {
            return codexTitle
        }

        // 2) Fallback: first non-empty user line, skipping preamble if pref enabled (default ON)
        for e in events where e.kind == .user {
            guard let raw = e.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            var candidate = raw

            // Claude: the first user event can include a long "Caveat + local command transcript" block.
            // If a real prompt follows that transcript, extract it and use it as the title.
            if skipPreamble, source == .claude, let tail = Self.claudeLocalCommandPromptTail(from: candidate) {
                candidate = tail
            }

            // Claude: sometimes the caveat transcript is split into multiple user events.
            // Skip tag-only / local-command transcript fragments so we don't title sessions as "<local-command-stdout>…".
            if skipPreamble, source == .claude, Self.looksLikeClaudeLocalCommandTranscript(candidate) {
                continue
            }

            if skipPreamble && Self.looksLikeAgentsPreamble(candidate) { continue }

            let collapsed = candidate.collapsedWhitespace()
            if !collapsed.isEmpty { return collapsed }
        }

        // 3) Fallback: first non-empty assistant line (also skip preamble when enabled)
        for e in events where e.kind == .assistant {
            guard let raw = e.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            if skipPreamble && Self.looksLikeAgentsPreamble(raw) { continue }
            let collapsed = raw.collapsedWhitespace()
            if !collapsed.isEmpty { return collapsed }
        }

        // 4) Final fallback: first tool call name
        if let name = events.first(where: { $0.kind == .tool_call && ($0.toolName?.isEmpty == false) })?.toolName {
            return name
        }

        return "No prompt"
    }

    // MARK: - Codex picker parity helpers
    // Title used by Codex's --resume picker: first plain user message found in the
    // head of the file (first 10 records). If none found, the session is not shown.
    public var codexPreviewTitle: String? {
        guard source == .codex else { return nil }
        let head = events.prefix(10)
        // Optional preference to skip agents.md style preambles when deriving a title (default ON)
        let d = UserDefaults.standard
        let skipPreamble = (d.object(forKey: "SkipAgentsPreamble") == nil) ? true : d.bool(forKey: "SkipAgentsPreamble")

        // Find first meaningful user message, filtering out IDE scaffolding
        for event in head where event.kind == .user {
            guard let raw = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            if skipPreamble && Self.looksLikeAgentsPreamble(raw) { continue }
            // Skip if it's very long (likely instructions dump)
            if raw.count > 400 { continue }
            return raw.collapsedWhitespace()
        }

        // Fallback: first shell/tool command in head as a one-liner
        if let call = head.first(where: { event in
            guard event.kind == .tool_call else { return false }
            guard let name = event.toolName?.lowercased() else { return false }
            return name.contains("shell") || name.contains("bash") || name.contains("sh")
        }) {
            if let cmd = Self.firstCommandLine(from: call.toolInput) {
                return cmd
            }
        }
        return nil
    }

    /// Heuristics for detecting an agents.md-style preamble or CLI caveat blocks at the start of a session.
    private static func looksLikeAgentsPreamble(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Codex CLI harness often injects an Agents.md preamble block (AGENTS.md + <INSTRUCTIONS> tags).
        // When present, treat it as scaffolding rather than a real user prompt.
        if lower.hasPrefix("# agents.md instructions for ") { return true }
        if lower.contains("\n# agents.md instructions for ") { return true }
        if lower.contains("<instructions>") || lower.contains("</instructions>") { return true }
        if lower.contains("<environment_context>") || lower.contains("</environment_context>") { return true }
        // Droid / Factory: some logs embed <system-reminder>...</system-reminder> blocks before the first real prompt.
        if lower.contains("<system-reminder") || lower.contains("</system-reminder>") { return true }
        // Codex CLI harness: turn-aborted notices can appear as XML-ish blocks captured under the user role.
        if lower.contains("<turn_aborted") || lower.contains("</turn_aborted>") { return true }
        // Strong anchors commonly seen in agents.md-driven openings
        let anchors = [
            "<user_instructions>",
            "</user_instructions>",
            "# agent sessions agents playbook",
            "## required workflow",
            "## plan mode",
            "commit policy (project‑wide)",
            "docs style policy (strict)",
            "- how to enter plan mode",
            "what's prohibited in plan mode",
            "how to behave in plan mode",
            "recommended output structure"
        ]
        if anchors.contains(where: { lower.contains($0) }) { return true }
        // Generic scaffolding heads
        let heads = [
            "you are an expert",
            "you are a helpful",
            "act as a",
            "your role is",
            "system:",
            "assistant:",
            "# instructions",
            "## instructions",
            "please follow",
            "make sure to"
        ]
        if heads.contains(where: { lower.hasPrefix($0) }) { return true }

        // Claude CLI caveat block frequently repeated at the top of sessions
        if lower.contains("caveat: the messages below were generated by the user while running local commands") {
            return true
        }
        if lower.contains("<command-name>/clear</command-name>") { return true }

        // A long markdown-heavy block with many headings/bullets is likely preamble
        let lines = lower.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count >= 6 {
            let bulletOrHeading = lines.prefix(20).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            if bulletOrHeading.count >= 4 { return true }
        }
        return false
    }

    /// Shared helper for transcript builders / views.
    static func isAgentsPreambleText(_ text: String) -> Bool {
        looksLikeAgentsPreamble(text)
    }

    /// Option B: stable classification for "housekeeping-only" session files.
    /// This should be forward-compatible and independent from user preferences like "Skip preambles".
    static func computeIsHousekeeping(source: SessionSource, events: [SessionEvent]) -> Bool {
        switch source {
        case .codex:
            if events.contains(where: { $0.kind == .assistant }) { return false }
            if events.contains(where: { $0.kind == .tool_call || $0.kind == .tool_result }) { return false }
            let meaningfulUser = events.contains { e in
                guard e.kind == .user else { return false }
                guard let raw = e.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
                return !looksLikeAgentsPreamble(raw)
            }
            return !meaningfulUser
        case .claude:
            if events.contains(where: { $0.kind == .assistant }) { return false }
            if events.contains(where: { $0.kind == .tool_call || $0.kind == .tool_result }) { return false }
            let meaningfulUser = events.contains { e in
                guard e.kind == .user else { return false }
                guard let raw = e.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
                if let tail = claudeLocalCommandPromptTail(from: raw), !tail.isEmpty { return true }
                if looksLikeClaudeLocalCommandTranscript(raw) { return false }
                if looksLikeAgentsPreamble(raw) { return false }
                return true
            }
            return !meaningfulUser
        default:
            return false
        }
    }

    // Extract timestamp and UUID from rollout filename for Codex sort order.
    // rollout-YYYY-MM-DDThh-mm-ss-<uuid>.jsonl
    public var codexFilenameTimestamp: Date? {
        guard source == .codex else { return nil }
        let filename = (filePath as NSString).lastPathComponent

        if let cached = Self.rolloutDateCache.object(forKey: filename as NSString) {
            return cached as Date
        }

        guard let match = Self.rolloutRegex.firstMatch(in: filename) else {
            return nil
        }

        let ts = match.ts
        Self.rolloutDateFormatterLock.lock()
        let parsed = Self.rolloutDateFormatter.date(from: ts)
        Self.rolloutDateFormatterLock.unlock()
        if let parsed {
            Self.rolloutDateCache.setObject(parsed as NSDate, forKey: filename as NSString)
        }
        return parsed
    }

    public var codexFilenameUUID: String? {
        guard source == .codex else { return nil }
        guard let match = Self.rolloutRegex.firstMatch(in: (filePath as NSString).lastPathComponent) else { return nil }
        return match.uuid
    }

    // Prefer the internal session_id embedded in JSONL (more authoritative than filename UUID for some builds)
    public var codexInternalSessionID: String? {
        guard source == .codex else { return nil }
        if let cached = codexInternalSessionIDHint, !cached.isEmpty { return cached }
        return Self.deriveCodexInternalSessionID(from: events)
    }

    static func deriveCodexInternalSessionID(from events: [SessionEvent]) -> String? {
        // Scan a larger head slice to improve hit rate on older logs
        let limit = min(events.count, 2000)
        for e in events.prefix(limit) {
            let raw = e.rawJSON
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let v = obj["session_id"] as? String, !v.isEmpty { return v }
                if let payload = obj["payload"] as? [String: Any] {
                    if let v = payload["session_id"] as? String, !v.isEmpty { return v }
                    // Newer Codex session_meta uses `payload.id` as the session identifier.
                    if let t = obj["type"] as? String, t == "session_meta",
                       let v = payload["id"] as? String, !v.isEmpty { return v }
                }
            }
            // Lightweight regex fallback when JSON parsing fails
            if let r = raw.range(of: #"\"session_id\"\s*:\s*\"([^"]+)\""#, options: .regularExpression) {
                let match = String(raw[r])
                if let idRange = match.range(of: #"\"([^"]+)\""#, options: .regularExpression) {
                    let quoted = String(match[idRange])
                    return String(quoted.dropFirst().dropLast())
                }
            }
        }
        return nil
    }

    // When showing Match Codex view, prefer the preview title, else fall back
    // to our general-purpose title so the table always has text.
    public var codexDisplayTitle: String { codexPreviewTitle ?? title }

    // MARK: - Repo/CWD helpers
    public var cwd: String? {
        // Providers that persist cwd as lightweight metadata should keep using it
        // after full parse as well; transcript event scraping is not authoritative.
        if (source == .gemini || source == .opencode || source == .copilot || source == .openclaw || source == .hermes),
           let lightCwd = lightweightCwd, !lightCwd.isEmpty {
            return lightCwd
        }
        if isSideChat, let lightCwd = lightweightCwd, !lightCwd.isEmpty {
            return lightCwd
        }
        // 0) Claude sessions: use cwd extracted during parsing
        if source == .claude, let lightCwd = lightweightCwd, !lightCwd.isEmpty {
            return lightCwd
        }
        // 0b) Droid sessions: use cwd extracted during parsing
        if source == .droid, let lightCwd = lightweightCwd, !lightCwd.isEmpty {
            return lightCwd
        }

        // 1) Lightweight session: use extracted cwd
        if events.isEmpty, let lightCwd = lightweightCwd, !lightCwd.isEmpty {
            return lightCwd
        }

        // 2) Look for XML-ish environment_context blocks in text (Codex only)
        let pattern = #"<cwd>(.*?)</cwd>"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            for e in events {
                if let t = e.text {
                    let ns = t as NSString
                    let range = NSRange(location: 0, length: ns.length)
                    if let m = re.firstMatch(in: t, range: range), m.numberOfRanges >= 2 {
                        let r = m.range(at: 1)
                        let str = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !str.isEmpty { return str }
                    }
                }
            }
        }
        // 3) Look for JSON field "cwd" in raw JSON (Codex only)
        for e in events {
            if let data = e.rawJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let c = (obj["cwd"] as? String) ?? ((obj["payload"] as? [String: Any])?["cwd"] as? String),
               !c.isEmpty { return c }
        }
        return nil
    }
    public var repoName: String? {
        if let override = CodexDesktopProjectClassifier.projectNameOverride(for: self) {
            return override
        }
        if let override = ClaudeDesktopProjectClassifier.projectNameOverride(for: self) {
            return override
        }
        if let normalized = ProjectPathNormalizer.normalizedProjectName(for: self) {
            return normalized
        }
        if ProjectPathNormalizer.shouldSuppressStoredProjectName(for: self) {
            return nil
        }

        if let stored = lightweightRepoName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }

        return repoNameFromCwd()
    }

    private func repoNameFromCwd() -> String? {
        guard let cwd else { return nil }
        let url = URL(fileURLWithPath: cwd)
        let dirName = url.lastPathComponent

        // Skip generic directory names that aren't useful
        let genericNames = ["Documents", "Desktop", "Downloads", "tmp", "temp", "src", "code", "out", "output", "outputs", "build", "dist", "Repository", "cli", "memories"]
        if !genericNames.contains(dirName) && !dirName.isEmpty && dirName != "." {
            return dirName
        }

        // Final fallback: try parent directory name
        let parent = url.deletingLastPathComponent()
        let parentName = parent.lastPathComponent
        if !genericNames.contains(parentName) && !parentName.isEmpty && parentName != "." {
            return parentName
        }

        return nil
    }

    public var projectWorktreeDisplayName: String? {
        ProjectPathNormalizer.worktreeDisplayName(for: self)
    }

    public var repoDisplay: String {
        repoName ?? (cwd != nil ? "Other" : "—")
    }

    public var rowRepoName: String? {
        if let override = CodexDesktopProjectClassifier.projectNameOverride(for: self) {
            return override
        }
        if let override = ClaudeDesktopProjectClassifier.projectNameOverride(for: self) {
            return override
        }
        if let normalized = ProjectPathNormalizer.normalizedProjectNameWithoutEventMetadata(for: self) {
            return normalized
        }
        if ProjectPathNormalizer.shouldSuppressStoredProjectNameWithoutEventMetadata(for: self) {
            return nil
        }
        if let stored = lightweightRepoName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        return repoNameFromCwd()
    }

    public var rowProjectWorktreeDisplayName: String? {
        ProjectPathNormalizer.worktreeDisplayNameWithoutEventMetadata(for: self)
    }

    public var rowRepoDisplay: String {
        rowRepoName ?? (cwd != nil ? "Other" : "—")
    }
    public var isWorktree: Bool { (cwd.flatMap { Self.gitInfo(from: $0)?.isWorktree }) ?? false }
    public var isSubmodule: Bool { (cwd.flatMap { Self.gitInfo(from: $0)?.isSubmodule }) ?? false }

    public var nonMetaCount: Int {
        var count = 0
        for index in events.indices where events[index].kind != .meta {
            count += 1
        }
        return count
    }

    // Effective message count: use actual nonMetaCount when events loaded, otherwise eventCount estimate.
    // This must be stable: loading events should not cause a previously-visible session to disappear under
    // hide-zero / hide-low filters, so we use the max of estimate and actual.
    public var messageCount: Int {
        let estimate = max(eventCount, 0)
        let actual = nonMetaCount
        if events.isEmpty {
            return estimate
        } else {
            return max(estimate, actual)
        }
    }

    // Sort helper for agent/source column
    public var sourceKey: String { source.rawValue }

    // Sort helper for file size column (treat missing size as 0).
    public var fileSizeSortKey: Int { fileSizeBytes ?? 0 }

    public var modifiedRelative: String {
        // Use modifiedAt which correctly uses filename timestamp
        let ref = modifiedAt
        let r = RelativeDateTimeFormatter()
        r.unitsStyle = .short
        return r.localizedString(for: ref, relativeTo: Date())
    }

    public var modifiedAt: Date {
        // Restored Codex sessions can keep an old rollout filename while receiving fresh
        // state/transcript updates, so sort by the newest known activity timestamp.
        var latest = endTime ?? startTime ?? .distantPast
        if let startTime, startTime > latest {
            latest = startTime
        }
        if source == .codex, let filenameDate = codexFilenameTimestamp, filenameDate > latest {
            latest = filenameDate
        }
        return latest
    }

    // Best-effort git branch detection
    public var gitBranch: String? {
        // 1) explicit metadata in any event json
        for e in events {
            if let branch = extractBranch(fromRawJSON: e.rawJSON) { return branch }
        }
        // 2) regex over tool_result/shell outputs (use text/toolOutput)
        let texts = events.compactMap { $0.toolOutput ?? $0.text }
        for t in texts {
            if let b = extractBranch(fromOutput: t) { return b }
        }
        return nil
    }

    public var gitRepositoryURL: String? {
        for e in events {
            if let repositoryURL = extractRepositoryURL(fromRawJSON: e.rawJSON) {
                return repositoryURL
            }
        }
        return nil
    }

    /// Claude Code: extract a meaningful prompt tail from the "Caveat + local command transcript" block.
    /// Returns `nil` when the text is not a caveat block or when no real prompt content remains.
    internal static func claudeLocalCommandPromptTail(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let anchor = "caveat: the messages below were generated by the user while running local commands"
        guard lower.contains(anchor) else { return nil }

        // 1) Best-effort: take content after the final closing local-command stdout tag.
        if let close = trimmed.range(of: "</local-command-stdout>", options: [.caseInsensitive, .backwards]) {
            let tail = trimmed[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { return String(tail) }
        }

        // 2) Line-based fallback: drop the caveat line and all transcript tag lines, then keep whatever remains.
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var cleaned: [String] = []
        cleaned.reserveCapacity(lines.count / 2)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            let l = t.lowercased()
            if l.hasPrefix("caveat:") { continue }
            if l.contains("<command-name>") || l.contains("<command-message>") || l.contains("<command-args>") { continue }
            if l.contains("<local-command-stdout") { continue }
            if t.hasPrefix("<") { continue }
            cleaned.append(t)
        }
        let out = cleaned.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    private static func looksLikeClaudeLocalCommandTranscript(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("<command-name>") { return true }
        if lower.hasPrefix("<command-message>") { return true }
        if lower.hasPrefix("<command-args>") { return true }
        if lower.hasPrefix("<local-command-stdout") { return true }
        if lower.contains("</local-command-stdout>") && lower.replacingOccurrences(of: " ", with: "").hasPrefix("<local-command-stdout>") {
            return true
        }
        // Common non-prompt stdout fragments (safe to treat as transcript when skip preambles is enabled).
        if lower.hasPrefix("set model to ") { return true }
        return false
    }
}

enum SessionDateSection: Hashable, Identifiable {
    var id: Self { self }
    case today
    case yesterday
    case day(String)
    case older

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .day(let s): return s
        case .older: return "Older"
        }
    }
}

extension Array where Element == Session {
    func groupedBySection(now: Date = Date(), calendar: Calendar = .current) -> [(SessionDateSection, [Session])] {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        var buckets: [SessionDateSection: [Session]] = [:]
        for s in self {
            guard let start = s.startTime else {
                buckets[.older, default: []].append(s)
                continue
            }
            if cal.isDate(start, inSameDayAs: today) {
                buckets[.today, default: []].append(s)
            } else if cal.isDate(start, inSameDayAs: yesterday) {
                buckets[.yesterday, default: []].append(s)
            } else {
                let dayStr = ISO8601DateFormatter.cachedDayString(from: start)
                buckets[.day(dayStr), default: []].append(s)
            }
        }
        // Section order
        var result: [(SessionDateSection, [Session])] = []
        if let v = buckets[.today] { result.append((.today, v)) }
        if let v = buckets[.yesterday] { result.append((.yesterday, v)) }
        // Sort day sections descending
        let daySections = buckets.keys.compactMap { sec -> (String, [Session])? in
            if case let .day(d) = sec { return (d, buckets[sec] ?? []) }
            return nil
        }.sorted { $0.0 > $1.0 }
        for (d, list) in daySections { result.append((.day(d), list)) }
        if let v = buckets[.older] { result.append((.older, v)) }
        return result
    }
}

extension ISO8601DateFormatter {
    private final class LockedFormatter: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter: ISO8601DateFormatter

        init(formatOptions: ISO8601DateFormatter.Options) {
            let f = ISO8601DateFormatter()
            f.formatOptions = formatOptions
            formatter = f
        }

        func string(from date: Date) -> String {
            lock.lock()
            let result = formatter.string(from: date)
            lock.unlock()
            return result
        }
    }

    private static let cachedDayFormatter = LockedFormatter(formatOptions: [.withYear, .withMonth, .withDay])

    static func cachedDayString(from date: Date) -> String {
        cachedDayFormatter.string(from: date)
    }
}

// MARK: - Git branch helpers

private extension String {
    func collapsedWhitespace() -> String {
        let parts = self.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }
    var trimmedEmpty: Bool { self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

final class CodexDesktopProjectlessThreadStore: @unchecked Sendable {
    static let shared = CodexDesktopProjectlessThreadStore()

    private struct Cache {
        let mtime: Date?
        let projectlessThreadIDs: Set<String>
    }

    private let lock = NSLock()
    private var cache: Cache?
    private var stateURLOverrideForTesting: URL?

    func isProjectlessThread(id: String) -> Bool {
        projectlessThreadIDs().contains(id)
    }

    func setStateURLOverrideForTesting(_ url: URL?) {
        lock.lock()
        stateURLOverrideForTesting = url
        cache = nil
        lock.unlock()
    }

    private func projectlessThreadIDs() -> Set<String> {
        let url = stateURL()
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil

        lock.lock()
        if let cache, cache.mtime == mtime {
            let ids = cache.projectlessThreadIDs
            lock.unlock()
            return ids
        }
        lock.unlock()

        let ids = Self.loadProjectlessThreadIDs(from: url)

        lock.lock()
        cache = Cache(mtime: mtime, projectlessThreadIDs: ids)
        lock.unlock()
        return ids
    }

    private func stateURL() -> URL {
        lock.lock()
        let override = stateURLOverrideForTesting
        lock.unlock()
        if let override { return override }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
    }

    private static func loadProjectlessThreadIDs(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = root["projectless-thread-ids"] as? [String] else {
            return []
        }
        return Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}

enum CodexDesktopProjectClassifier {
    static let chatsProjectName = "Codex Desktop Chats"

    static func projectNameOverride(
        for session: Session,
        projectlessStore: CodexDesktopProjectlessThreadStore = .shared
    ) -> String? {
        guard session.isCodexDesktopSession else { return nil }
        if let internalID = session.codexInternalSessionID,
           !internalID.isEmpty,
           projectlessStore.isProjectlessThread(id: internalID) {
            return chatsProjectName
        }

        guard isGeneratedDesktopChatWorkspace(session.cwd) else { return nil }
        return chatsProjectName
    }

    private static func isGeneratedDesktopChatWorkspace(_ cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        let components = URL(fileURLWithPath: cwd).standardizedFileURL.pathComponents
        guard components.count >= 5 else { return false }

        let suffix = Array(components.suffix(4))
        return suffix[0] == "Documents" &&
            suffix[1] == "Codex" &&
            isISODateComponent(suffix[2]) &&
            !suffix[3].isEmpty
    }

    private static func isISODateComponent(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        return true
    }
}

enum ClaudeDesktopProjectClassifier {
    static let chatsProjectName = "Claude Desktop Chats"

    static func projectNameOverride(for session: Session) -> String? {
        guard session.isClaudeDesktopSession else { return nil }
        guard isGeneratedDesktopChatWorkspace(session.cwd) else { return nil }
        return chatsProjectName
    }

    private static func isGeneratedDesktopChatWorkspace(_ cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        let components = URL(fileURLWithPath: cwd).standardizedFileURL.pathComponents
        return components.count == 3 &&
            components[0] == "/" &&
            components[1] == "sessions" &&
            !components[2].isEmpty
    }
}

enum ProjectPathNormalizer {
    private final class CachedWorktreeBase {
        let value: String?

        init(_ value: String?) {
            self.value = value
        }
    }

    private static let gitWorktreeBaseCache = NSCache<NSString, CachedWorktreeBase>()
    private static let gitOriginBaseCache = NSCache<NSString, CachedWorktreeBase>()

    private enum Resolution {
        case name(String, worktree: String?)
        case suppress
    }

    static func normalizedProjectName(for session: Session) -> String? {
        guard case let .name(name, _) = resolve(for: session) else { return nil }
        return name
    }

    static func worktreeDisplayName(for session: Session) -> String? {
        guard case let .name(_, worktree) = resolve(for: session) else { return nil }
        return worktree
    }

    static func normalizedProjectNameWithoutEventMetadata(for session: Session) -> String? {
        guard case let .name(name, _) = resolveWithoutEventMetadata(for: session) else { return nil }
        return name
    }

    static func worktreeDisplayNameWithoutEventMetadata(for session: Session) -> String? {
        guard case let .name(_, worktree) = resolveWithoutEventMetadata(for: session) else { return nil }
        return worktree
    }

    static func shouldSuppressStoredProjectName(for session: Session) -> Bool {
        guard case .suppress = resolve(for: session) else { return false }
        return true
    }

    static func shouldSuppressStoredProjectNameWithoutEventMetadata(for session: Session) -> Bool {
        guard case .suppress = resolveWithoutEventMetadata(for: session) else { return false }
        return true
    }

    private static func resolve(for session: Session) -> Resolution? {
        resolve(
            cwd: session.cwd,
            usesDesktopWorktreeHeuristics: session.isCodexDesktopSession || session.isClaudeDesktopSession,
            storedProjectName: session.lightweightRepoName,
            gitRepositoryURL: session.gitRepositoryURL,
            gitBranch: session.gitBranch
        )
    }

    private static func resolveWithoutEventMetadata(for session: Session) -> Resolution? {
        resolve(
            cwd: session.cwd,
            usesDesktopWorktreeHeuristics: session.isCodexDesktopSession || session.isClaudeDesktopSession,
            storedProjectName: session.lightweightRepoName,
            gitRepositoryURL: nil,
            gitBranch: nil
        )
    }

    private static func resolve(
        cwd: String?,
        usesDesktopWorktreeHeuristics: Bool = false,
        storedProjectName: String? = nil,
        gitRepositoryURL: String? = nil,
        gitBranch: String? = nil
    ) -> Resolution? {
        guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let components = URL(fileURLWithPath: cwd).standardizedFileURL.pathComponents
        guard let last = components.last, !last.isEmpty else { return .suppress }
        if cwd == "/" { return .suppress }

        if let resolution = projectNameBeforeMarker(in: components, marker: ".worktrees") {
            return resolution
        }
        if let resolution = projectNameBeforeToolWorktrees(in: components) {
            return resolution
        }
        if let resolution = projectNameBeforeHiddenClone(in: components) {
            return resolution
        }
        if let resolution = numberedSiblingWorktreeName(in: components) {
            return resolution
        }
        if usesDesktopWorktreeHeuristics,
           let resolution = storedDesktopWorktreeName(in: components, storedProjectName: storedProjectName) {
            return resolution
        }
        if usesDesktopWorktreeHeuristics,
           let resolution = desktopSiblingWorktreeName(
            in: components,
            cwd: cwd,
            gitRepositoryURL: gitRepositoryURL,
            gitBranch: gitBranch
           ) {
            return resolution
        }
        if let name = repositoryProjectName(in: components) {
            return .name(name, worktree: nil)
        }
        if isGenericNonProjectName(last) {
            return .suppress
        }

        return nil
    }

    private static func projectNameBeforeMarker(in components: [String], marker: String) -> Resolution? {
        guard let index = components.lastIndex(of: marker),
              index > 0,
              index + 1 < components.count else {
            return nil
        }
        let candidate = components[index - 1]
        guard let project = normalizedProjectComponent(candidate) else { return nil }
        return .name(project, worktree: normalizedWorktreeComponent(components[index + 1]))
    }

    private static func projectNameBeforeToolWorktrees(in components: [String]) -> Resolution? {
        guard let index = components.lastIndex(of: "worktrees"),
              index > 1,
              index + 1 < components.count else {
            return nil
        }
        let toolDirectory = components[index - 1]
        guard toolDirectory == ".claude" || toolDirectory == ".codex" else { return nil }
        guard let project = normalizedProjectComponent(components[index - 2]) else { return nil }
        return .name(project, worktree: normalizedWorktreeComponent(components[index + 1]))
    }

    private static func projectNameBeforeHiddenClone(in components: [String]) -> Resolution? {
        let hiddenCloneNames = [".tennisgroup_repo", ".tennisgroup_repo_fresh"]
        guard let index = components.lastIndex(where: { hiddenCloneNames.contains($0) }),
              index > 0 else {
            return nil
        }
        guard let project = normalizedProjectComponent(components[index - 1]) else { return nil }
        return .name(project, worktree: nil)
    }

    private static func numberedSiblingWorktreeName(in components: [String]) -> Resolution? {
        guard let repositoryIndex = components.lastIndex(of: "Repository"),
              repositoryIndex + 1 < components.count else {
            return nil
        }
        let isNestedScriptsProject = components[repositoryIndex + 1] == "Scripts"
        let projectIndex = isNestedScriptsProject && repositoryIndex + 2 < components.count
            ? repositoryIndex + 2
            : repositoryIndex + 1
        let last = components[projectIndex]
        let pattern = #"^(.+)-[0-9]{2}$"#
        guard let match = last.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(last[match])
        guard let hyphen = matched.lastIndex(of: "-") else { return nil }
        let base = String(matched[..<hyphen])
        let worktree = normalizedWorktreeComponent(last)
        if isNestedScriptsProject {
            guard let project = normalizedProjectComponent(base) else { return nil }
            return .name(project, worktree: worktree)
        }
        guard let project = displayName(fromGeneratedWorktreeBase: base) else { return nil }
        return .name(project, worktree: worktree)
    }

    static func codexDesktopProjectNameFromGitMetadata(cwd: String?, gitRepositoryURL: String?, gitBranch: String?) -> String? {
        guard let cwd,
              let gitRepositoryURL,
              normalizedGitOriginURL(gitRepositoryURL) != nil,
              gitBranch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let components = URL(fileURLWithPath: cwd).standardizedFileURL.pathComponents
        guard let repositoryRoot = repositoryRoot(in: components) else { return nil }
        guard let baseProject = originMatchedBaseProjectName(
            cwd: cwd,
            components: components,
            repositoryRoot: repositoryRoot,
            gitRepositoryURL: gitRepositoryURL,
            gitBranch: gitBranch
        ) else {
            return nil
        }
        return normalizedProjectComponent(baseProject)
    }

    private static func storedDesktopWorktreeName(in components: [String], storedProjectName: String?) -> Resolution? {
        guard let storedProject = normalizedProjectComponent(
            storedProjectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ),
              let repositoryRoot = repositoryRoot(in: components),
              storedProject != components.last,
              let worktreeName = normalizedWorktreeComponent(components[repositoryRoot.projectIndex]),
              worktreeName != storedProject else {
            return nil
        }
        return .name(storedProject, worktree: worktreeName)
    }

    private static func desktopSiblingWorktreeName(
        in components: [String],
        cwd: String,
        gitRepositoryURL: String?,
        gitBranch: String?
    ) -> Resolution? {
        guard let repositoryRoot = repositoryRoot(in: components) else { return nil }
        let projectIndex = repositoryRoot.projectIndex
        let worktree = components[projectIndex]
        let baseProject = gitWorktreeBaseProjectName(in: components, cwd: cwd, worktreeIndex: projectIndex)
            ?? originMatchedBaseProjectName(
                cwd: cwd,
                components: components,
                repositoryRoot: repositoryRoot,
                gitRepositoryURL: gitRepositoryURL,
                gitBranch: gitBranch
            )
        guard let baseProject,
              let project = normalizedProjectComponent(baseProject),
              let worktreeName = normalizedWorktreeComponent(worktree),
              worktreeName != project else {
            return nil
        }
        return .name(project, worktree: worktreeName)
    }

    private struct RepositoryRoot {
        let parentURL: URL
        let projectIndex: Int
    }

    private static func repositoryRoot(in components: [String]) -> RepositoryRoot? {
        guard let repositoryIndex = components.lastIndex(of: "Repository"),
              repositoryIndex + 1 < components.count else {
            return nil
        }
        let isNestedScriptsProject = components[repositoryIndex + 1] == "Scripts"
        let projectIndex = isNestedScriptsProject && repositoryIndex + 2 < components.count
            ? repositoryIndex + 2
            : repositoryIndex + 1
        guard projectIndex < components.count else { return nil }

        var parentComponents = Array(components.prefix(projectIndex))
        if parentComponents.isEmpty {
            parentComponents = ["/"]
        }
        let parentPath = NSString.path(withComponents: parentComponents)
        return RepositoryRoot(parentURL: URL(fileURLWithPath: parentPath, isDirectory: true), projectIndex: projectIndex)
    }

    private static func repositoryProjectName(in components: [String]) -> String? {
        guard let repositoryIndex = components.lastIndex(of: "Repository"),
              repositoryIndex + 1 < components.count else {
            return nil
        }

        let first = components[repositoryIndex + 1]
        if first == "Scripts", repositoryIndex + 2 < components.count {
            return normalizedProjectComponent(components[repositoryIndex + 2])
        }
        return normalizedProjectComponent(first)
    }

    private static func normalizedProjectComponent(_ component: String) -> String? {
        guard !component.isEmpty,
              component != ".",
              component != "/",
              !isGenericNonProjectName(component) else {
            return nil
        }
        return component
    }

    private static func normalizedWorktreeComponent(_ component: String?) -> String? {
        guard let component,
              !component.isEmpty,
              component != ".",
              component != "/",
              !isGenericNonProjectName(component) else {
            return nil
        }
        return component
    }

    private static func isGenericNonProjectName(_ name: String) -> Bool {
        let generic = [
            "Documents", "Desktop", "Downloads", "tmp", "temp", "src", "code",
            "out", "output", "outputs", "build", "dist", "Repository", "cli", "memories"
        ]
        return generic.contains(name)
    }

    private static func gitWorktreeBaseProjectName(in components: [String], cwd: String, worktreeIndex: Int) -> String? {
        var worktreeURL = URL(fileURLWithPath: cwd).standardizedFileURL
        let trailingComponentCount = max(components.count - worktreeIndex - 1, 0)
        for _ in 0..<trailingComponentCount {
            worktreeURL.deleteLastPathComponent()
        }

        let cacheKey = worktreeURL.standardizedFileURL.path as NSString
        if let cached = gitWorktreeBaseCache.object(forKey: cacheKey) {
            return cached.value
        }

        let project = readGitWorktreeBaseProjectName(from: worktreeURL)
        gitWorktreeBaseCache.setObject(CachedWorktreeBase(project), forKey: cacheKey)
        return project
    }

    private static func originMatchedBaseProjectName(
        cwd: String,
        components: [String],
        repositoryRoot: RepositoryRoot,
        gitRepositoryURL: String?,
        gitBranch: String? = nil
    ) -> String? {
        guard let normalizedTarget = normalizedGitOriginURL(gitRepositoryURL),
              gitBranch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              repositoryRoot.projectIndex < components.count else {
            return nil
        }
        let currentRoot = worktreeRootURL(cwd: cwd, components: components, worktreeIndex: repositoryRoot.projectIndex)
            .standardizedFileURL.path
        let cacheKey = "\(repositoryRoot.parentURL.standardizedFileURL.path)|\(currentRoot)|\(normalizedTarget)" as NSString
        if let cached = gitOriginBaseCache.object(forKey: cacheKey) {
            return cached.value
        }

        let project = readOriginMatchedBaseProjectName(
            parentURL: repositoryRoot.parentURL,
            currentRoot: currentRoot,
            normalizedTarget: normalizedTarget
        )
        gitOriginBaseCache.setObject(CachedWorktreeBase(project), forKey: cacheKey)
        return project
    }

    private static func worktreeRootURL(cwd: String, components: [String], worktreeIndex: Int) -> URL {
        var worktreeURL = URL(fileURLWithPath: cwd).standardizedFileURL
        let trailingComponentCount = max(components.count - worktreeIndex - 1, 0)
        for _ in 0..<trailingComponentCount {
            worktreeURL.deleteLastPathComponent()
        }
        return worktreeURL
    }

    private static func readGitWorktreeBaseProjectName(from worktreeURL: URL) -> String? {
        let gitFileURL = worktreeURL.appendingPathComponent(".git", isDirectory: false)
        guard let gitFile = try? String(contentsOf: gitFileURL, encoding: .utf8) else {
            return nil
        }
        let gitdirPrefix = "gitdir:"
        guard let line = gitFile
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(gitdirPrefix) }) else {
            return nil
        }
        let gitdir = line.trimmingCharacters(in: .whitespaces)
            .dropFirst(gitdirPrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gitdirURL = URL(fileURLWithPath: gitdir)
        let gitComponents = gitdirURL.standardizedFileURL.pathComponents
        guard let gitIndex = gitComponents.lastIndex(of: ".git"), gitIndex > 0 else {
            return nil
        }
        return normalizedProjectComponent(gitComponents[gitIndex - 1])
    }

    private static func readOriginMatchedBaseProjectName(
        parentURL: URL,
        currentRoot: String,
        normalizedTarget: String
    ) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard entry.standardizedFileURL.path != currentRoot,
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  normalizedProjectComponent(entry.lastPathComponent) != nil,
                  normalizedGitOriginURL(readGitOriginURL(from: entry, allowWorktreeGitFile: false)) == normalizedTarget else {
                continue
            }
            return entry.lastPathComponent
        }
        return nil
    }

    private static func readGitOriginURL(from repositoryURL: URL, allowWorktreeGitFile: Bool = true) -> String? {
        let gitURL = repositoryURL.appendingPathComponent(".git")
        let configURL: URL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            configURL = gitURL.appendingPathComponent("config")
        } else if allowWorktreeGitFile,
                  let gitFile = try? String(contentsOf: gitURL, encoding: .utf8),
                  let gitdir = gitFile
                    .split(whereSeparator: \.isNewline)
                    .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("gitdir:") })?
                    .trimmingCharacters(in: .whitespaces)
                    .dropFirst("gitdir:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines) {
            configURL = URL(fileURLWithPath: gitdir).appendingPathComponent("config")
        } else {
            return nil
        }
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        var inOrigin = false
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == #"[remote "origin"]"#
                continue
            }
            guard inOrigin, line.hasPrefix("url") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, !parts[1].isEmpty {
                return parts[1]
            }
        }
        return nil
    }

    private static func normalizedGitOriginURL(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        return value.lowercased()
    }

    private static func displayName(fromGeneratedWorktreeBase base: String) -> String? {
        guard !base.isEmpty, !isGenericNonProjectName(base) else { return nil }
        let separators = CharacterSet(charactersIn: "-_")
        let scalars = base.unicodeScalars
        var result = ""
        var shouldCapitalize = true
        for scalar in scalars {
            let text = String(scalar)
            if separators.contains(scalar) {
                result.append(text)
                shouldCapitalize = true
            } else if shouldCapitalize {
                result.append(text.uppercased())
                shouldCapitalize = false
            } else {
                result.append(text)
            }
        }
        return result
    }
}

private func extractBranch(fromRawJSON raw: String) -> String? {
    if let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let b = obj["git_branch"] as? String { return b }
        if let payload = obj["payload"] as? [String: Any],
           let git = payload["git"] as? [String: Any],
           let b = git["branch"] as? String,
           !b.isEmpty { return b }
        if let repo = obj["repo"] as? [String: Any], let b = repo["branch"] as? String { return b }
        if let b = obj["branch"] as? String { return b }
    }
    return nil
}

private func extractRepositoryURL(fromRawJSON raw: String) -> String? {
    if let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let value = firstRepositoryURL(in: obj) { return value }
        if let payload = obj["payload"] as? [String: Any],
           let value = firstRepositoryURL(in: payload) {
            return value
        }
        if let git = obj["git"] as? [String: Any],
           let value = firstRepositoryURL(in: git) {
            return value
        }
        if let payload = obj["payload"] as? [String: Any],
           let git = payload["git"] as? [String: Any],
           let value = firstRepositoryURL(in: git) {
            return value
        }
    }
    return nil
}

private func firstRepositoryURL(in dict: [String: Any]) -> String? {
    for key in ["git_origin_url", "repository_url", "origin_url", "remote_url", "url"] {
        if let value = dict[key] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
    }
    return nil
}

private func extractBranch(fromOutput s: String) -> String? {
    let patterns = [
        "(?m)^On\\s+branch\\s+([A-Za-z0-9._/-]+)",
        "(?m)^\\*\\s+([A-Za-z0-9._/-]+)$",
        "(?m)^(?:heads/)?([A-Za-z0-9._/-]+)$"
    ]
    for p in patterns {
        if let re = try? NSRegularExpression(pattern: p) {
            let range = NSRange(location: 0, length: (s as NSString).length)
            if let m = re.firstMatch(in: s, options: [], range: range), m.numberOfRanges >= 2 {
                let r = m.range(at: 1)
                if let swiftRange = Range(r, in: s) { return String(s[swiftRange]) }
            }
        }
    }
    return nil
}

// MARK: - Rollout filename regex helpers
private struct RolloutMatch { let ts: String; let uuid: String }
private struct RolloutRegex {
    private let regex: NSRegularExpression?

    init() {
        let pattern = "^rollout-([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2})-([0-9a-fA-F-]+)\\.jsonl$"
        regex = try? NSRegularExpression(pattern: pattern)
    }

    func firstMatch(in name: String) -> RolloutMatch? {
        guard let regex else { return nil }
        let range = NSRange(location: 0, length: (name as NSString).length)
        guard let m = regex.firstMatch(in: name, range: range), m.numberOfRanges >= 3 else { return nil }
        let ns = name as NSString
        return RolloutMatch(ts: ns.substring(with: m.range(at: 1)), uuid: ns.substring(with: m.range(at: 2)))
    }
}

private final class RolloutDateCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSDate>()

    func object(forKey key: NSString) -> NSDate? {
        cache.object(forKey: key)
    }

    func setObject(_ obj: NSDate, forKey key: NSString) {
        cache.setObject(obj, forKey: key)
    }
}

private extension Session {
    static let rolloutRegex = RolloutRegex()
    static let rolloutDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.timeZone = TimeZone.current  // Use local timezone, not UTC
        return f
    }()
    static let rolloutDateFormatterLock = NSLock()
    static let rolloutDateCache = RolloutDateCache()
    static func firstCommandLine(from raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Try to parse JSON object
        if let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // common keys
            if let v = (obj["command"] ?? obj["cmd"] ?? obj["script"] ?? obj["args"]) {
                if let str = v as? String { s = str }
                else if let arr = v as? [Any] { s = arr.map { String(describing: $0) }.joined(separator: " ") }
            }
        }
        // If multi-line, take first non-empty line
        for line in s.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return s
    }

    // Try to find a Git repository root by walking up from cwd.
    struct GitInfo { let root: String; let isWorktree: Bool; let isSubmodule: Bool }
    private final class GitInfoCacheBox: NSObject {
        let root: String?
        let isWorktree: Bool
        let isSubmodule: Bool

        init(_ info: GitInfo?) {
            self.root = info?.root
            self.isWorktree = info?.isWorktree ?? false
            self.isSubmodule = info?.isSubmodule ?? false
        }

        var info: GitInfo? {
            guard let root else { return nil }
            return GitInfo(root: root, isWorktree: isWorktree, isSubmodule: isSubmodule)
        }
    }
    private static let gitInfoCache: NSCache<NSString, GitInfoCacheBox> = {
        let cache = NSCache<NSString, GitInfoCacheBox>()
        cache.countLimit = 2048
        return cache
    }()

    private static func gitInfo(from start: String, maxLevels: Int = 6) -> GitInfo? {
        let normalizedStart = URL(fileURLWithPath: start).standardizedFileURL.path
        let cacheKey = "\(normalizedStart)|\(maxLevels)" as NSString
        if let cached = gitInfoCache.object(forKey: cacheKey) {
            return cached.info
        }

        var url = URL(fileURLWithPath: normalizedStart)
        let fm = FileManager.default
        var resolved: GitInfo?
        for _ in 0..<maxLevels {
            let dotGitDir = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGitDir.path, isDirectory: &isDir), isDir.boolValue {
                // Regular repo root
                resolved = GitInfo(root: url.path, isWorktree: false, isSubmodule: false)
                break
            }
            // .git file pointing to gitdir
            if fm.fileExists(atPath: dotGitDir.path) {
                if let data = try? String(contentsOf: dotGitDir, encoding: .utf8),
                   let range = data.range(of: "gitdir:") {
                    let path = data[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    let lower = path.lowercased()
                    let worktree = lower.contains(".git/worktrees/")
                    let submodule = lower.contains(".git/modules/")
                    resolved = GitInfo(root: url.path, isWorktree: worktree, isSubmodule: submodule)
                    break
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        gitInfoCache.setObject(GitInfoCacheBox(resolved), forKey: cacheKey)
        return resolved
    }

}
