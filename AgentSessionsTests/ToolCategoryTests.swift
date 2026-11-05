import XCTest
@testable import AgentSessions

/// Task 9: `ToolCategoryMap` maps agent tool names to categories (spec §7.2) and categories to
/// SF Symbols (spec §6.6).
final class ToolCategoryTests: XCTestCase {

    /// Every bold tool name of spec §7.2, with the category of its row.
    private let survey: [(SessionSource, String, ToolCategory)] = [
        // shell
        (.codex, "exec_command", .shell), (.codex, "shell", .shell), (.codex, "local_shell_call", .shell),
        (.codex, "exec", .shell), (.claude, "Bash", .shell), (.antigravity, "run_command", .shell),
        (.opencode, "bash", .shell), (.opencode, "shell", .shell), (.opencode, "execute", .shell),
        (.hermes, "terminal", .shell), (.hermes, "execute_code", .shell), (.copilot, "bash", .shell),
        (.droid, "Execute", .shell), (.openclaw, "bash", .shell), (.openclaw, "exec", .shell),
        (.cursor, "Shell", .shell), (.pi, "bash", .shell), (.kimi, "Bash", .shell),
        (.grok, "run_terminal_command", .shell), (.fx, "shell", .shell), (.cline, "run_commands", .shell),
        (.deepseekHarness, "bash", .shell),
        // read
        (.claude, "Read", .read), (.antigravity, "view_file", .read), (.antigravity, "read_file", .read),
        (.opencode, "read", .read), (.hermes, "read_file", .read), (.copilot, "view", .read),
        (.droid, "Read", .read), (.cursor, "Read", .read), (.kimi, "Read", .read), (.grok, "read_file", .read),
        (.qwen, "read_file", .read), (.cline, "read_files", .read), (.deepseekHarness, "read", .read),
        // list
        (.antigravity, "list_dir", .list), (.opencode, "list", .list), (.opencode, "glob", .list),
        (.droid, "LS", .list), (.droid, "Glob", .list), (.openclaw, "ls", .list), (.grok, "list_dir", .list),
        (.qwen, "list_directory", .list), (.qwen, "glob", .list),
        // edit
        (.codex, "apply_patch", .edit), (.claude, "Edit", .edit), (.antigravity, "replace_file_content", .edit),
        (.opencode, "edit", .edit), (.hermes, "patch", .edit), (.openclaw, "apply_patch", .edit),
        (.cursor, "StrReplace", .edit), (.grok, "search_replace", .edit), (.fx, "edit_file", .edit),
        (.cline, "editor", .edit), (.deepseekHarness, "edit", .edit),
        // write
        (.claude, "Write", .write), (.antigravity, "write_file", .write), (.antigravity, "write_to_file", .write),
        (.opencode, "write", .write), (.hermes, "write_file", .write), (.cursor, "Write", .write),
        (.kimi, "Write", .write), (.grok, "write", .write), (.deepseekHarness, "write", .write),
        // search
        (.claude, "Grep", .search), (.claude, "Glob", .search), (.antigravity, "grep_search", .search),
        (.opencode, "grep", .search), (.hermes, "search_files", .search), (.cursor, "Grep", .search),
        (.cursor, "Glob", .search), (.kimi, "Grep", .search), (.kimi, "Glob", .search), (.grok, "grep", .search),
        (.qwen, "grep_search", .search), (.cline, "search_codebase", .search), (.deepseekHarness, "grep", .search),
        (.deepseekHarness, "glob", .search),
        // web
        (.codex, "web_search_call", .web), (.claude, "WebFetch", .web), (.claude, "WebSearch", .web),
        (.antigravity, "search_web", .web), (.opencode, "webfetch", .web), (.opencode, "websearch", .web),
        (.openclaw, "web_fetch", .web), (.grok, "web_fetch", .web), (.grok, "web_search", .web),
        (.grok, "x_search", .web),
        // plan
        (.codex, "update_plan", .plan), (.claude, "TodoWrite", .plan), (.opencode, "todowrite", .plan),
        (.hermes, "todo", .plan), (.droid, "ExitSpecMode", .plan), (.kimi, "ExitPlanMode", .plan),
        (.grok, "todo_write", .plan), (.deepseekHarness, "todo_write", .plan),
        // subagent
        (.claude, "Task", .subagent), (.opencode, "task", .subagent), (.hermes, "delegate_task", .subagent),
        (.kimi, "Agent", .subagent), (.grok, "spawn_subagent", .subagent),
        (.grok, "get_command_or_subagent_output", .subagent), (.qwen, "agent", .subagent),
        (.deepseekHarness, "subagent", .subagent),
        // ask
        (.opencode, "question", .ask), (.hermes, "clarify", .ask), (.deepseekHarness, "ask_user_question", .ask),
        // structured
        (.cursor, "CallMcpTool", .structured),
    ]

    private func category(_ source: SessionSource, _ name: String?, namespace: String? = nil) -> ToolCategory {
        ToolCategoryMap.category(source: source, toolName: name, namespace: namespace)
    }

    func testCategoryMapCoversSurveyNames() {
        for (source, name, expected) in survey {
            XCTAssertEqual(category(source, name), expected, "\(source.rawValue) \(name)")
        }
        // The Codex parser stores web_search_call under the name web_search.
        XCTAssertEqual(category(.codex, "web_search"), .web)
        // Every MCP tool is structured: Claude `mcp__server__tool`, Codex namespace `mcp__server__`.
        XCTAssertEqual(category(.claude, "mcp__github__create_pull_request"), .structured)
        XCTAssertEqual(category(.codex, "js", namespace: "mcp__node_repl__"), .structured)
        // A Codex MCP tool named like a built-in stays structured.
        XCTAssertEqual(category(.codex, "exec", namespace: "mcp__cua_repl__"), .structured)
        // Codex multi-agent namespaces are subagent calls (spec §7.4).
        XCTAssertEqual(category(.codex, "send_message", namespace: "collaboration"), .subagent)
        XCTAssertEqual(category(.codex, "spawn_agent", namespace: "multi_agent_v1"), .subagent)
        XCTAssertEqual(category(.codex, "wait_agent"), .subagent)
        // Codex process polls render as shell rows.
        XCTAssertEqual(category(.codex, "write_stdin"), .shell)
        XCTAssertEqual(category(.codex, "wait"), .shell)
    }

    func testUnknownNameIsStructured() {
        XCTAssertEqual(category(.claude, "SomethingNew"), .structured)
        XCTAssertEqual(category(.codex, nil), .structured)
        XCTAssertEqual(category(.codex, ""), .structured)
        // A name is per agent: Glob is list for Droid but search for Claude; glob is list for
        // OpenCode but search for DSH.
        XCTAssertEqual(category(.droid, "Glob"), .list)
        XCTAssertEqual(category(.claude, "Glob"), .search)
        XCTAssertEqual(category(.opencode, "glob"), .list)
        XCTAssertEqual(category(.deepseekHarness, "glob"), .search)
        // A name that every listing agent agrees on maps for an agent the survey did not list.
        XCTAssertEqual(category(.devin, "bash"), .shell)
        XCTAssertEqual(category(.devin, "read_file"), .read)
    }

    func testSymbolsComeFromTheSpecList() {
        let specSymbols: Set<String> = ["terminal", "doc.text", "pencil", "doc.badge.plus", "magnifyingglass",
                                        "folder", "globe", "checklist", "person.2", "puzzlepiece.extension",
                                        "photo", "questionmark.bubble", "curlybraces"]
        let symbols = ToolCategory.allCases.map(ToolCategoryMap.symbolName)
        XCTAssertEqual(Set(symbols).count, ToolCategory.allCases.count, "one symbol per category")
        for symbol in symbols { XCTAssertTrue(specSymbols.contains(symbol), symbol) }
        XCTAssertEqual(ToolCategoryMap.symbolName(.shell), "terminal")
        XCTAssertEqual(ToolCategoryMap.symbolName(.read), "doc.text")
        XCTAssertEqual(ToolCategoryMap.symbolName(.edit), "pencil")
        XCTAssertEqual(ToolCategoryMap.symbolName(.write), "doc.badge.plus")
        XCTAssertEqual(ToolCategoryMap.symbolName(.structured), "puzzlepiece.extension")
    }

    func testDefaultVerbs() {
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.shell), "tool.verb.ran")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.read), "tool.verb.read")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.write), "tool.verb.created")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.edit), "tool.verb.edited")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.search), "tool.verb.searched")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.list), "tool.verb.listed")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.web), "tool.verb.fetched")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.plan), "tool.verb.updatedPlan")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.subagent), "tool.verb.subagent")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.ask), "tool.verb.asked")
        XCTAssertEqual(ToolCategoryMap.defaultVerbKey(.image), "tool.verb.screenshot")
        // The catalog resolves each key (en test host).
        XCTAssertEqual(ToolVerb.text(ToolVerb.ran), "Ran")
        XCTAssertEqual(ToolVerb.text(ToolVerb.polled), "Polled")
        XCTAssertEqual(ToolVerb.text(ToolVerb.sentInput), "Sent input")
        XCTAssertEqual(ToolVerb.text(ToolVerb.ranScript), "Ran script")
        XCTAssertEqual(ToolVerb.text(ToolVerb.searchedWeb), "Searched the web")
        XCTAssertEqual(ToolVerb.text(ToolVerb.output), "Output")
        // A structured action's verb is its tool name, shown as is.
        XCTAssertEqual(ToolVerb.text("github › create_pull_request"), "github › create_pull_request")
    }
}
