import Foundation

/// What a tool action does, independent of the agent (spec §6.3). It picks the L1 icon, the
/// default verb and, from P2 on, the L2 renderer.
enum ToolCategory: String, Sendable, CaseIterable {
    case shell, read, write, edit, search, list, web, plan, subagent, ask, image, structured
}

/// Agent tool name → category (spec §7.2), kept as data. A name is looked up for its agent first.
/// A name that every listing agent maps the same way also maps for agents the survey did not list
/// (so a new agent's `bash` is still shell). Names that agents disagree on (`Glob`, `glob`) map only
/// per agent. MCP tools and unknown names are structured.
enum ToolCategoryMap {
    static func category(source: SessionSource, toolName: String?, namespace: String?) -> ToolCategory {
        if let namespace, !namespace.isEmpty {
            if namespace.hasPrefix("mcp__") { return .structured }
            if subagentNamespaces.contains(namespace) { return .subagent }
        }
        guard let name = toolName, !name.isEmpty else { return .structured }
        if name.hasPrefix("mcp__") { return .structured }
        if let category = bySource[source]?[name] { return category }
        return agreed[name] ?? .structured
    }

    /// SF Symbol per category (spec §6.6). `curlybraces` stays free for the Raw button.
    static func symbolName(_ c: ToolCategory) -> String {
        switch c {
        case .shell: return "terminal"
        case .read: return "doc.text"
        case .write: return "doc.badge.plus"
        case .edit: return "pencil"
        case .search: return "magnifyingglass"
        case .list: return "folder"
        case .web: return "globe"
        case .plan: return "checklist"
        case .subagent: return "person.2"
        case .ask: return "questionmark.bubble"
        case .image: return "photo"
        case .structured: return "puzzlepiece.extension"
        }
    }

    /// The category's verb (spec §6.3). Structured actions have no verb key: their verb is the
    /// tool name. Web search tools use `ToolVerb.searchedWeb` instead of this default.
    static func defaultVerbKey(_ c: ToolCategory) -> String {
        switch c {
        case .shell: return ToolVerb.ran
        case .read: return ToolVerb.read
        case .write: return ToolVerb.created
        case .edit: return ToolVerb.edited
        case .search: return ToolVerb.searched
        case .list: return ToolVerb.listed
        case .web: return ToolVerb.fetched
        case .plan: return ToolVerb.updatedPlan
        case .subagent: return ToolVerb.subagent
        case .ask: return ToolVerb.asked
        case .image: return ToolVerb.screenshot
        case .structured: return ToolVerb.output
        }
    }

    /// Codex multi-agent namespaces (spec §7.4): every tool in them is a subagent call.
    private static let subagentNamespaces: Set<String> = ["collaboration", "multi_agent_v1"]

    /// Spec §7.2, one row per agent. Bold and non-bold survey names, plus the §7.4 Codex and
    /// Claude families (polls, multi-agent tools, `request_user_input`, `Monitor`, the parser's
    /// `web_search` name for `web_search_call`).
    private static let bySource: [SessionSource: [String: ToolCategory]] = [
        .codex: [
            "exec_command": .shell, "shell": .shell, "local_shell_call": .shell, "exec": .shell,
            "write_stdin": .shell, "wait": .shell,
            "apply_patch": .edit,
            "web_search_call": .web, "web_search": .web,
            "update_plan": .plan,
            "spawn_agent": .subagent, "wait_agent": .subagent, "list_agents": .subagent, "followup_task": .subagent,
            "send_message": .subagent,
            "request_user_input": .ask,
            "view_image": .image,
        ],
        .claude: [
            "Bash": .shell, "BashOutput": .shell, "Monitor": .shell,
            "Read": .read,
            "Edit": .edit, "MultiEdit": .edit,
            "Write": .write,
            "Grep": .search, "Glob": .search,
            "WebFetch": .web, "WebSearch": .web,
            "TodoWrite": .plan, "ExitPlanMode": .plan,
            "Task": .subagent, "Agent": .subagent,
            "AskUserQuestion": .ask,
        ],
        .antigravity: [
            "run_command": .shell,
            "view_file": .read, "read_file": .read,
            "list_dir": .list,
            "replace_file_content": .edit,
            "write_file": .write, "write_to_file": .write,
            "grep_search": .search,
            "search_web": .web,
        ],
        .opencode: [
            "bash": .shell, "shell": .shell, "execute": .shell,
            "read": .read,
            "list": .list, "glob": .list,
            "edit": .edit,
            "write": .write,
            "grep": .search, "codesearch": .search,
            "webfetch": .web, "websearch": .web,
            "todowrite": .plan,
            "task": .subagent, "subagent": .subagent,
            "question": .ask,
        ],
        .hermes: [
            "terminal": .shell, "execute_code": .shell, "process": .shell,
            "read_file": .read, "skill_view": .read,
            "patch": .edit,
            "write_file": .write,
            "search_files": .search, "session_search": .search,
            "web_search": .web, "browser_navigate": .web,
            "todo": .plan,
            "delegate_task": .subagent,
            "clarify": .ask,
        ],
        .copilot: [
            "bash": .shell, "shell": .shell,
            "view": .read,
        ],
        .droid: [
            "Execute": .shell,
            "Read": .read,
            "LS": .list, "Glob": .list,
            "ExitSpecMode": .plan,
        ],
        .openclaw: [
            "bash": .shell, "exec": .shell,
            "ls": .list,
            "apply_patch": .edit,
            "web_fetch": .web,
            "memory_search": .search,
        ],
        .cursor: [
            "Shell": .shell,
            "Read": .read,
            "StrReplace": .edit, "ApplyPatch": .edit,
            "Write": .write,
            "Grep": .search, "Glob": .search,
            "CallMcpTool": .structured,
        ],
        .pi: [
            "bash": .shell, "bashExecution": .shell,
        ],
        .kimi: [
            "Bash": .shell,
            "Read": .read,
            "Write": .write,
            "Grep": .search, "Glob": .search,
            "ExitPlanMode": .plan, "TodoList": .plan,
            "Agent": .subagent, "AgentSwarm": .subagent,
            "AskUserQuestion": .ask,
            "ReadMediaFile": .image,
        ],
        .grok: [
            "run_terminal_command": .shell,
            "read_file": .read,
            "list_dir": .list,
            "search_replace": .edit,
            "write": .write,
            "grep": .search,
            "web_fetch": .web, "web_search": .web, "x_search": .web,
            "todo_write": .plan,
            "spawn_subagent": .subagent, "get_command_or_subagent_output": .subagent,
        ],
        .qwen: [
            "run_shell_command": .shell,
            "read_file": .read,
            "list_directory": .list, "glob": .list,
            "grep_search": .search,
            "agent": .subagent,
        ],
        .devin: [
            "read_file": .read,
        ],
        .fx: [
            "shell": .shell, "run_command": .shell,
            "list_files": .list, "glob_files": .list,
            "edit_file": .edit,
        ],
        .cline: [
            "run_commands": .shell,
            "read_files": .read,
            "search_codebase": .search,
            "editor": .edit,
        ],
        .deepseekHarness: [
            "bash": .shell, "job_output": .shell,
            "read": .read,
            "edit": .edit,
            "write": .write,
            "grep": .search, "glob": .search,
            "todo_write": .plan,
            "subagent": .subagent, "send_message": .subagent, "list_agents": .subagent,
            "ask_user_question": .ask,
        ],
    ]

    /// Names whose every listing agent agrees on one category.
    private static let agreed: [String: ToolCategory] = {
        var seen: [String: ToolCategory?] = [:]
        for table in bySource.values {
            for (name, category) in table {
                if let existing = seen[name] {
                    if existing != category { seen[name] = .some(nil) }
                } else {
                    seen[name] = category
                }
            }
        }
        return seen.compactMapValues { $0 }
    }()
}
