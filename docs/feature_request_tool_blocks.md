# Feature request: Content‑first tool call/output blocks in Session transcript

## Why we’re doing this

Tool inputs/outputs are currently displayed in inconsistent, noisy “JSON wrapper” formats that are hard to read in the Session transcript. Different agents (Codex, Claude, Droid, Copilot, OpenCode, etc.) emit tool events with different envelopes and field naming, so the transcript often shows:

- wrapper JSON instead of the meaningful content (command, path, prompt, stdout/stderr)
- inconsistent casing/keys (`Read` vs `read`, `file_path` vs `filePath`, `workdir` vs `cwd`)
- outputs that show empty JSON objects/fields instead of something human (“(no output)”)
- low signal-to-noise that makes scanning a session slower and more mentally taxing

We want the transcript to read like a clean log of **what was executed/requested** and **what came back**, regardless of agent.

## What we’re trying to achieve

### Primary goal
**Significantly improve readability** of tool calls and tool outputs by stripping wrappers and showing the actual content in clean text blocks.

### Secondary goals
- Keep transcript UX simple: **no controls** inside transcript blocks (no Copy/Expand/Raw toggles).
- Preserve (and ideally improve) **global search** so it matches within tool calls and tool outputs exactly as it does now.
- Support multiple agent families without changing underlying storage formats.

### Non‑goals (for this iteration)
- No inline buttons/controls in transcript.
- No “raw JSON” viewer / expand/collapse UI.
- No reformatting of assistant/user text beyond tool blocks.
- No changes to on-disk session formats.

---

## UX spec (text-only blocks)

Transcript remains “normal text divided into blocks.” Tool call and tool output are separate blocks but share the same background style/color.

### Examples (Unicode mockups)

#### Shell command — tool call block (input)
```
┌──────────────────────────────────────────────────────────────────────────────┐
│ bash                                                                          │
│ ls -la && echo '---' && nl -ba onboarding-implementation-plan.md | sed -n '1,60p' │
│ cwd: ~/Repository/Codex-History   timeout: 100000ms                           │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### Shell command — tool output block (stdout)
```
┌──────────────────────────────────────────────────────────────────────────────┐
│ total 24                                                                      │
│ drwxr-xr-x   8 alexm  staff   256 Jan 21 10:12 .                              │
│ -rw-r--r--   1 alexm  staff  1240 Jan 21 10:12 onboarding-implementation-plan.md │
│ ---                                                                           │
│   1  ...                                                                      │
│   2  ...                                                                      │
│ exit: 0                                                                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### Shell command — tool output (stderr-only)
```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ls: /nope: No such file or directory                                          │
│ exit: 1                                                                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### update_plan — tool call (checklist)
```
┌──────────────────────────────────────────────────────────────────────────────┐
│ plan                                                                          │
│ [x] Update onboarding content screens                                         │
│ [x] Rebuild AgentSessions schema                                              │
│ [x] Commit and push change                                                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### File ops — tool call
```
┌──────────────────────────────────────────────────────────────────────────────┐
│ read                                                                          │
│ ~/Repository/Triada/docs/LettaCode - Dec18.md                                 │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### File ops — tool output (listing)
```
┌──────────────────────────────────────────────────────────────────────────────┐
│ backup-script/README.md                                                       │
│ deploy-lib.sh                                                                 │
│ ...                                                                           │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### Empty output (fix wrapper problem)
```
┌──────────────────────────────────────────────────────────────────────────────┐
│ (no output)                                                                   │
│ exit: 0                                                                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Functional requirements

### 1) Normalization into text-only blocks
Introduce a UI-facing normalized representation for tool events:

**ToolTextBlock**
- `id`: stable identifier for diffing
- `kind`: `tool_call` | `tool_output`
- `toolLabel`: short label (`bash`, `read`, `list`, `glob`, `plan`, `task`, `tool`)
- `lines: [String]`: exact lines that will be rendered and indexed
- `groupKey` (optional): key to associate call/output if available (`call_id`, `toolCallId`, `tool_use_id`, `callID`, etc.)
- `agentFamily` (optional): codex/claude/droid/copilot/opencode/other

### 2) Content-first extraction rules
Never render outer JSON envelopes. Render only meaningful content:

#### A) Shell / command execution (calls)
Recognize if args contain `command` or tool name implies shell.  
- `toolLabel = "bash"`
- `lines[0] = command`
- optional meta line: `cwd/workdir`, `timeout_ms`

#### B) Shell outputs
Prefer stdout; if stdout empty use stderr; if both empty show `(no output)`.  
Include `exit: <code>` when known.

#### C) File operations (calls)
Recognize path-ish keys: `file_path`, `filePath`, `directory_path`, `directoryPath`, `dir_path`, `folder`, `patterns`, `path`.
- `toolLabel` among `read/list/glob/grep/file`
- `lines` show compact, readable content lines only (paths/patterns)

#### D) File operation outputs
Render output lines as plain text; if empty show `(no output)`.

#### E) Plans (`update_plan`)
Render checklist from `plan[]`:
- `completed` → `[x]`
- `in_progress` → `[>]`
- `pending` → `[ ]`
- unknown → `-`
Never show the JSON wrapper as the main content.

#### F) Tasks (`Task`/`task`)
Render description + prompt text as readable lines.
- `toolLabel = "task"` (append `(Explore)` etc. in label line if desired)

#### G) Generic fallback
If no category matches:
- `toolLabel = "tool"`
- render short summaries if possible (e.g. `uid: 3_84`), otherwise a compact one-line JSON of the *payload itself* (not the full event envelope).

### 3) Agent format support (parsers)
Support current observed shapes without changing storage formats:

- **Codex**:
  - `type=function_call` with `name` + `arguments` (arguments is JSON string)
  - response_item payload `tool_call` / `tool_result`
- **Claude**:
  - `message.content[]` `tool_use` / `tool_result`
  - `toolUseResult` (stdout/stderr). Prefer `toolUseResult` over `tool_result: "ok"`.
- **Copilot**:
  - `data.toolRequests[]` (call) and `tool.execution_complete` (output). Output comes from `data.result.content`.
- **Droid**:
  - `type=tool_call` / `type=tool_result` where `value` may be **string** or **object**
  - plus Anthropic-like `tool_use` / `tool_result`
- **OpenCode**:
  - JSON `part.type=tool` with `state.input`, `state.output` or `state.error`

### 4) Search must continue to work
Find where the app builds searchable transcript text/index. Ensure tool blocks are indexed using the same textual content you render:
- index includes the rendered lines (tool call label line + content; tool outputs omit the label)
- search must match within:
  - command fragments
  - file paths/patterns
  - stdout/stderr output content
  - task prompts/checklist steps

### 5) Performance
No UI controls implies no dynamic expansion; nevertheless:
- avoid heavy pretty-printing on every render
- store already-normalized `lines` for tool blocks
- keep rendering O(n) over visible blocks

---

## Acceptance criteria (manual)

- Tool call blocks show **commands/paths/prompts/checklists**, not JSON envelopes.
- Tool output blocks show **stdout/stderr content**, not wrapper JSON.
- Empty stdout/stderr shows **`(no output)`**, not `{ "stdout": "" ... }`.
- Tool calls and outputs appear as separate blocks with same styling.
- Global search still finds terms inside tool calls and tool outputs (at least as well as before).
- No noticeable scroll lag on large sessions.

---

## Prompt for Codex to implement

Copy/paste the following into Codex:

```text
You are working in the AgentSessions macOS app. Implement a readability overhaul for tool calls and tool outputs in the Session transcript view.

Key product decisions (must follow)
- Transcript remains “normal text divided into blocks”. No inline controls, no buttons, no expand/raw toggles.
- Tool CALL and Tool OUTPUT are rendered as separate blocks (same background color style).
- Main goal: improve readability by stripping JSON wrappers and showing the actual content.
- Global search must keep working exactly as it does now across tool call and tool output text.

Do not change storage formats. Only change parsing/normalization and rendering, and ensure search indexing sees the same (or better) textual content.

Deliverables
1) A new normalizer that converts raw tool events (multiple agent formats) into display-ready ToolTextBlock records.
2) Update Session transcript renderer to render ToolTextBlock as plain text “blocks”.
3) Ensure search indexing uses the SAME “display text” for tool blocks so searching for command/path/output works.
4) Add unit tests for normalization to lock the textual output.

Normalized model (UI-facing)
Create a lightweight struct used by the transcript view and by indexing:

ToolTextBlock:
- id: stable
- kind: "tool_call" | "tool_output"
- toolLabel: short label string (e.g. "bash", "read", "list", "glob", "plan", "task", "tool")
- lines: [String]   // EXACT lines to render and index
- groupKey (optional): tool call/output pairing id when available (call_id/toolCallId/tool_use_id/callID)
- agentFamily (optional): codex/claude/droid/copilot/opencode/other

Rendering rules (no controls)
Render each ToolTextBlock as:
- First line: toolLabel for tool calls; tool outputs omit the label line
- Then the lines[] content (already formatted)
- No buttons, no raw/json shown, no expand; rely on normal scrolling.

Global rule: “content-first”
NEVER render the outer JSON wrapper. Only render semantically meaningful fields:
- commands, file paths, patterns, task prompts, plan checklists, stdout/stderr content, exit codes.

Normalization: category-based extraction
Map each raw event into a ToolTextBlock category:

A) Shell / command execution (tool call)
Recognize if args contain "command" OR tool name implies shell: {shell_command, Bash, Execute, Shell, bash}
Tool CALL block:
- toolLabel: "bash"
- lines:
  1) <command string>
  2) meta line (optional): "cwd: <...>   timeout: <...>ms" (include only if present)

B) Shell outputs (tool output)
From outputs containing stdout/stderr/exitCode, or copilot content, or droid value.
Tool OUTPUT block:
- toolLabel: "bash"
- lines:
  - If stdout non-empty: stdout lines (split by \n, preserve order)
  - Else if stderr non-empty: stderr lines
  - Else: "(no output)"
  - Add final line if exitCode present: "exit: <code>"
Important: If stdout+stderr both empty, DO NOT print a JSON object; print "(no output)".

C) File operations (Read/List/Glob/Grep/etc) (tool call)
Recognize if args contain any path-ish key:
file_path, filePath, directory_path, directoryPath, dir_path, folder, patterns, path
Tool CALL block:
- toolLabel: normalized among {"read","list","glob","grep","file"}
- lines: compact content-only lines:
  - Read: just the path line
  - List: just the directory path line
  - Glob: "folder: <...>" and "patterns: <...>"

D) File op outputs (tool output)
If output is file content / listing / grep results:
- toolLabel: same as the call where possible ("read"/"list"/"glob"/"grep")
- lines: output text lines (split by \n), plus "(no output)" if empty

E) Plan updates (update_plan) (tool call)
Recognize args.plan[] with {step,status}
Tool CALL block:
- toolLabel: "plan"
- lines: checklist derived from plan[] (no JSON):
  completed => "[x] <step>"
  in_progress => "[>] <step>"
  pending => "[ ] <step>"
  unknown => "- <step>"

F) Task / subagent prompts (Task/task) (tool call)
Recognize args has prompt and/or description
Tool CALL block:
- toolLabel: "task" (optionally include subagent_type in label line, e.g. "task (Explore)")
- lines:
  1) <description> (or first line of prompt)
  2..) prompt text lines (split by \n)

G) Generic JSON fallback (tool call/output)
When none matches:
- toolLabel: "tool"
- lines: try to extract a one-line summary:
  - if args has uid => "uid: <...>"
  - else if args has path => "<path>"
  - else if object small => one compact JSON line (single line, no outer envelope fields)
For outputs: similarly summarize, else "(no output)".

Agent format support (parsing sources)
Support the existing observed shapes:
- Codex:
  - jsonl:type=function_call with name + arguments (arguments is JSON string)
  - jsonl:response_item payload.type=tool_call/tool_result
- Claude:
  - message.content[].type=tool_use/tool_result
  - toolUseResult (stdout/stderr)
  Output rule: prefer toolUseResult stdout/stderr over tool_result "ok"/empty content.
- Copilot:
  - data.toolRequests[] (call), tool.execution_complete (output)
  Output rule: use data.result.content as text lines (not {"content":...}).
- Droid:
  - type=tool_call/tool_result (value can be string OR object with stdout)
  - plus Anthropic-like tool_use/tool_result
- OpenCode:
  - json part.type=tool with state.input/state.output/state.error

Search compatibility (must preserve and improve)
- Find where AgentSessions builds the searchable transcript text / index.
- Ensure it indexes ToolTextBlock.label + ToolTextBlock.lines joined with "\n".
- If you previously indexed raw JSON, replace/augment with the new human text so search for command fragments, filenames/paths, and stdout/stderr still works (ideally better).

Testing (required)
Add unit tests for the normalization function that assert exact lines[] output for fixtures:
1) Codex shell_command call (command + cwd/workdir)
2) Codex response_item tool_result with stdout/stderr/exitCode
3) Claude tool_use + toolUseResult stdout preference over "ok"
4) Droid tool_result where value is a STRING (error)
5) Copilot execution_complete content -> lines
6) update_plan -> checklist lines
7) empty output envelope -> "(no output)" line (no JSON)
8) Read/List/Glob call formatting

Acceptance criteria (manual)
- In transcript, tool calls show a small label line; tool outputs do not repeat the label.
- JSON wrappers are not shown.
- Empty outputs show "(no output)" rather than "{}" or {"stdout":""...}.
- Global search finds matches inside command lines, file paths, and stdout/stderr text (at least as well as before).
- No noticeable performance regression on large sessions.

Now implement:
- locate current transcript/tool rendering,
- implement ToolTextBlock normalization for all agent formats,
- update rendering and search indexing to use ToolTextBlock.lines,
- add tests.
```
