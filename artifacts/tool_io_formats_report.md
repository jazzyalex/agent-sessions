# Tool IO Formats Report
Generated: 2026-02-24T00:50:25Z

## Scan Summary
- claude: 3 files from /Users/alexm/Repository/Codex-History/Resources/Fixtures/stage0/agents/claude
- codex: 10 files from /Users/alexm/Repository/Codex-History/Resources/Fixtures, /Users/alexm/Repository/Codex-History/Resources/Fixtures/stage0/agents/codex
- copilot: 3 files from /Users/alexm/Repository/Codex-History/Resources/Fixtures/stage0/agents/copilot
- droid: 6 files from /Users/alexm/Repository/Codex-History/Resources/Fixtures/stage0/agents/droid
- openclaw: 3 files from /Users/alexm/Repository/Codex-History/Resources/Fixtures/stage0/agents/openclaw

## Shape Summary
| Shape Signature | Count | Agents | Directions |
| --- | --- | --- | --- |
| jsonl:data.toolRequests[] | 3 | copilot | input=3 |
| jsonl:message.content[].type=tool_result | 4 | claude, droid | output=4 |
| jsonl:message.content[].type=tool_use | 4 | claude, droid | input=4 |
| jsonl:message.role=assistant:toolCall | 4 | openclaw | input=4 |
| jsonl:message.role=toolResult | 4 | openclaw | output=4 |
| jsonl:response_item:payload.type=tool_call | 2 | codex | input=2 |
| jsonl:response_item:payload.type=tool_result | 2 | codex | output=2 |
| jsonl:toolUseResult | 2 | claude | output=2 |
| jsonl:type=function_call | 1 | codex | input=1 |
| jsonl:type=function_result | 1 | codex | output=1 |
| jsonl:type=tool.execution_complete | 4 | copilot | output=4 |
| jsonl:type=tool_call | 5 | codex, droid | input=5 |
| jsonl:type=tool_result | 5 | codex, droid | output=5 |

## Shape: jsonl:data.toolRequests[]
- Count: 3
- Agents: copilot
- Directions: input=3

Examples:
1. Raw event:
```json
{"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"call_1","name":"bash","arguments":{"command":"echo hi"}}]},"id":"e4","timestamp":"2025-12-18T22:00:03.000Z","parentId":"e3"}
```
Raw payload:
```json
{"command": "echo hi"}
```
Parsed payload:
```json
{
  "command": "echo hi"
}
```

2. Raw event:
```json
{"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"call_1","name":"bash","arguments":{"command":"printf 'line1\\nline2\\nline3\\n'"}}]},"id":"e7","timestamp":"2025-12-18T23:00:06.000Z","parentId":"e6"}
```
Raw payload:
```json
{"command": "printf 'line1\\nline2\\nline3\\n'"}
```
Parsed payload:
```json
{
  "command": "printf 'line1\\nline2\\nline3\\n'"
}
```

3. Raw event:
```json
{"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"call_1","name":"bash","arguments":{"command":"ls"}}]},"id":"e5","timestamp":"2025-12-18T21:32:08.000Z","parentId":"e4"}
```
Raw payload:
```json
{"command": "ls"}
```
Parsed payload:
```json
{
  "command": "ls"
}
```

## Shape: jsonl:message.content[].type=tool_result
- Count: 4
- Agents: claude, droid
- Directions: output=4

Examples:
1. Raw event:
```json
{"type":"message","id":"m4","timestamp":"2025-12-26T00:10:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"line1\nline2\nline3\n"}]}}
```
Raw payload:
```text
line1
line2
line3

```

2. Raw event:
```json
{"type":"message","id":"m3","timestamp":"2025-12-26T23:50:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"Error: Command failed (exit code: 1)\nls: /nope: No such file or directory"}]}}
```
Raw payload:
```text
Error: Command failed (exit code: 1)
ls: /nope: No such file or directory
```

3. Raw event:
```json
{"parentUuid":"a1","isSidechain":false,"userType":"external","cwd":"/tmp/large","sessionId":"ses_stage0_large","version":"2.1.19","gitBranch":"main","type":"user","toolUseResult":{"stdout":"line1\nline2\nline3\n","stderr":"","is_error":false},"message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"uuid":"u2","timestamp":"2025-12-16T02:00:02.000Z","slug":"u2","isMeta":true,"sourceToolAssistantUUID":"a1"}
```
Raw payload:
```text
ok
```

## Shape: jsonl:message.content[].type=tool_use
- Count: 4
- Agents: claude, droid
- Directions: input=4

Examples:
1. Raw event:
```json
{"type":"message","id":"m3","timestamp":"2025-12-26T00:10:02.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Execute","input":{"command":"printf 'line1\\nline2\\nline3\\n'"}}]}}
```
Raw payload:
```json
{"command": "printf 'line1\\nline2\\nline3\\n'"}
```
Parsed payload:
```json
{
  "command": "printf 'line1\\nline2\\nline3\\n'"
}
```

2. Raw event:
```json
{"type":"message","id":"m2","timestamp":"2025-12-26T23:50:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Execute","input":{"command":"ls /nope"}}]}}
```
Raw payload:
```json
{"command": "ls /nope"}
```
Parsed payload:
```json
{
  "command": "ls /nope"
}
```

3. Raw event:
```json
{"parentUuid":"u1","isSidechain":false,"userType":"external","cwd":"/tmp/large","sessionId":"ses_stage0_large","version":"2.1.19","gitBranch":"main","type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Plan\n1) Do thing\n2) Verify\n"},{"type":"text","text":"Ok, running."},{"type":"tool_use","name":"bash","input":{"command":"printf 'line1\\nline2\\nline3\\n'"}}]},"requestId":"req_stage0","uuid":"a1","timestamp":"2025-12-16T02:00:01.000Z","slug":"a1"}
```
Raw payload:
```json
{"command": "printf 'line1\\nline2\\nline3\\n'"}
```
Parsed payload:
```json
{
  "command": "printf 'line1\\nline2\\nline3\\n'"
}
```

## Shape: jsonl:message.role=assistant:toolCall
- Count: 4
- Agents: openclaw
- Directions: input=4

Examples:
1. Raw event:
```json
{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-02-24T11:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"I am running diagnostics."},{"type":"toolCall","id":"tc-diagnose","name":"diagnostic_tool","arguments":{"check":"health"}}]}}
```
Raw payload:
```json
{"check": "health"}
```
Parsed payload:
```json
{
  "check": "health"
}
```

2. Raw event:
```json
{"type":"message","id":"m2","timestamp":"2026-02-24T10:00:04Z","message":{"role":"assistant","model":"openclaw-large","content":[{"type":"text","text":"Gathering files and git status."},{"type":"toolCall","id":"tc-status","name":"run_terminal","arguments":{"command":"git status --short","cwd":"/tmp/large"}}]}}
```
Raw payload:
```json
{"command": "git status --short", "cwd": "/tmp/large"}
```
Parsed payload:
```json
{
  "command": "git status --short",
  "cwd": "/tmp/large"
}
```

3. Raw event:
```json
{"type":"message","id":"m5","timestamp":"2026-02-24T10:00:07Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"tc-write","name":"edit_file","arguments":{"path":"/tmp/large/notes.md","content":"note"}}]}}
```
Raw payload:
```json
{"content": "note", "path": "/tmp/large/notes.md"}
```
Parsed payload:
```json
{
  "content": "note",
  "path": "/tmp/large/notes.md"
}
```

## Shape: jsonl:message.role=toolResult
- Count: 4
- Agents: openclaw
- Directions: output=4

Examples:
1. Raw event:
```json
{"type":"message","id":"m3","parentId":"tc-diagnose","timestamp":"2026-02-24T11:00:03Z","message":{"toolCallId":"tc-diagnose","toolName":"diagnostic_tool","role":"toolResult","content":"PASS\n","isError":false}}
```
Raw payload:
```text
PASS

```

2. Raw event:
```json
{"type":"message","id":"m3","timestamp":"2026-02-24T10:00:05Z","message":{"role":"toolResult","toolCallId":"tc-status","toolName":"run_terminal","content":"M file1\nM file2","isError":false}}
```
Raw payload:
```text
M file1
M file2
```

3. Raw event:
```json
{"type":"message","id":"m6","timestamp":"2026-02-24T10:00:08Z","message":{"role":"toolResult","toolCallId":"tc-write","toolName":"edit_file","content":"file written","isError":false}}
```
Raw payload:
```text
file written
```

## Shape: jsonl:response_item:payload.type=tool_call
- Count: 2
- Agents: codex
- Directions: input=2

Examples:
1. Raw event:
```json
{"timestamp":"2025-12-18T10:00:03.000Z","type":"response_item","payload":{"type":"tool_call","function":{"name":"run_shell_command"},"arguments":{"command":"printf 'line1\\nline2\\nline3\\n'","cwd":"/tmp/large"}}}
```
Raw payload:
```json
{"command": "printf 'line1\\nline2\\nline3\\n'", "cwd": "/tmp/large"}
```
Parsed payload:
```json
{
  "command": "printf 'line1\\nline2\\nline3\\n'",
  "cwd": "/tmp/large"
}
```

2. Raw event:
```json
{"timestamp":"2025-12-17T23:27:51.000Z","type":"response_item","payload":{"type":"tool_call","function":{"name":"run_shell_command"},"arguments":{"command":"ls","cwd":"/tmp/repo"}}}
```
Raw payload:
```json
{"command": "ls", "cwd": "/tmp/repo"}
```
Parsed payload:
```json
{
  "command": "ls",
  "cwd": "/tmp/repo"
}
```

## Shape: jsonl:response_item:payload.type=tool_result
- Count: 2
- Agents: codex
- Directions: output=2

Examples:
1. Raw event:
```json
{"timestamp":"2025-12-18T10:00:04.000Z","type":"response_item","payload":{"type":"tool_result","name":"run_shell_command","result":{"stdout":"line1\nline2\nline3\n","stderr":"","exitCode":0}}}
```
Raw payload:
```json
{"exitCode": 0, "stderr": "", "stdout": "line1\nline2\nline3\n"}
```
Parsed payload:
```json
{
  "exitCode": 0,
  "stderr": "",
  "stdout": "line1\nline2\nline3\n"
}
```

2. Raw event:
```json
{"timestamp":"2025-12-17T23:27:52.000Z","type":"response_item","payload":{"type":"tool_result","name":"run_shell_command","result":{"stdout":"a.txt\nb.txt\n","stderr":"","exitCode":0}}}
```
Raw payload:
```json
{"exitCode": 0, "stderr": "", "stdout": "a.txt\nb.txt\n"}
```
Parsed payload:
```json
{
  "exitCode": 0,
  "stderr": "",
  "stdout": "a.txt\nb.txt\n"
}
```

## Shape: jsonl:toolUseResult
- Count: 2
- Agents: claude
- Directions: output=2

Examples:
1. Raw event:
```json
{"parentUuid":"a1","isSidechain":false,"userType":"external","cwd":"/tmp/large","sessionId":"ses_stage0_large","version":"2.1.19","gitBranch":"main","type":"user","toolUseResult":{"stdout":"line1\nline2\nline3\n","stderr":"","is_error":false},"message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"uuid":"u2","timestamp":"2025-12-16T02:00:02.000Z","slug":"u2","isMeta":true,"sourceToolAssistantUUID":"a1"}
```
Raw payload:
```json
{"is_error": false, "stderr": "", "stdout": "line1\nline2\nline3\n"}
```
Parsed payload:
```json
{
  "is_error": false,
  "stderr": "",
  "stdout": "line1\nline2\nline3\n"
}
```

2. Raw event:
```json
{"parentUuid":"a1","isSidechain":true,"userType":"external","cwd":"/tmp","sessionId":"ses_stage0_small","version":"2.1.19","gitBranch":"main","type":"user","toolUseResult":{"stdout":"file1\nfile2\n","stderr":"","is_error":false},"message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"uuid":"u2","timestamp":"2025-12-16T00:00:03.000Z","slug":"u2","isMeta":true,"sourceToolAssistantUUID":"a1","permissionMode":"ask","imagePasteIds":[]}
```
Raw payload:
```json
{"is_error": false, "stderr": "", "stdout": "file1\nfile2\n"}
```
Parsed payload:
```json
{
  "is_error": false,
  "stderr": "",
  "stdout": "file1\nfile2\n"
}
```

## Shape: jsonl:type=function_call
- Count: 1
- Agents: codex
- Directions: input=1

Examples:
1. Raw event:
```json
{"created_at":"2025-09-10T12:00:01Z","type":"function_call","function":{"name":"translate"},"arguments":{"text":"hello","to":"es"}}
```
Raw payload:
```json
{"text": "hello", "to": "es"}
```
Parsed payload:
```json
{
  "text": "hello",
  "to": "es"
}
```

## Shape: jsonl:type=function_result
- Count: 1
- Agents: codex
- Directions: output=1

Examples:
1. Raw event:
```json
{"created_at":"2025-09-10T12:00:01Z","type":"function_result","name":"translate","result":"hola"}
```
Raw payload:
```text
hola
```

## Shape: jsonl:type=tool.execution_complete
- Count: 4
- Agents: copilot
- Directions: output=4

Examples:
1. Raw event:
```json
{"type":"tool.execution_complete","data":{"toolCallId":"call_1","success":true,"result":{"content":"hi\n"}},"id":"e5","timestamp":"2025-12-18T22:00:04.000Z","parentId":"e4"}
```
Raw payload:
```json
{"content": "hi\n"}
```
Parsed payload:
```json
{
  "content": "hi\n"
}
```

2. Raw event:
```json
{"type":"tool.execution_complete","data":{"toolCallId":"call_2","success":false,"result":{"content":"exit code: 1\n"}},"id":"e6","timestamp":"2025-12-18T22:00:05.000Z","parentId":"e5"}
```
Raw payload:
```json
{"content": "exit code: 1\n"}
```
Parsed payload:
```json
{
  "content": "exit code: 1\n"
}
```

3. Raw event:
```json
{"type":"tool.execution_complete","data":{"toolCallId":"call_1","success":true,"result":{"content":"line1\nline2\nline3\n"}},"id":"e8","timestamp":"2025-12-18T23:00:07.000Z","parentId":"e7"}
```
Raw payload:
```json
{"content": "line1\nline2\nline3\n"}
```
Parsed payload:
```json
{
  "content": "line1\nline2\nline3\n"
}
```

## Shape: jsonl:type=tool_call
- Count: 5
- Agents: codex, droid
- Directions: input=5

Examples:
1. Raw event:
```json
{"timestamp":"2025-09-10T12:00:01Z","type":"tool_call","function":{"name":"git"},"arguments":"status"}
```
Raw payload:
```text
status
```

2. Raw event:
```json
{"timestamp":"2025-09-10T12:00:01Z","type":"tool_call","function":{"name":"translate"},"arguments":"{\"text\":\"hello\",\"to\":\"es\"}"}
```
Raw payload:
```json
{"text":"hello","to":"es"}
```
Parsed payload:
```json
{
  "text": "hello",
  "to": "es"
}
```

3. Raw event:
```json
{"type":"tool_call","session_id":"sid_stage0_large","timestamp":"2025-12-26T02:00:03.000Z","toolCallId":"c1","toolName":"Shell","parameters":{"command":"printf 'line1\\nline2\\nline3\\n'"},"id":"tc1"}
```
Raw payload:
```json
{"command": "printf 'line1\\nline2\\nline3\\n'"}
```
Parsed payload:
```json
{
  "command": "printf 'line1\\nline2\\nline3\\n'"
}
```

## Shape: jsonl:type=tool_result
- Count: 5
- Agents: codex, droid
- Directions: output=5

Examples:
1. Raw event:
```json
{"timestamp":"2025-09-10T12:00:01Z","type":"tool_result","name":"git","result":"On branch main\nYour branch is up to date with 'origin/main'.\n"}
```
Raw payload:
```text
On branch main
Your branch is up to date with 'origin/main'.

```

2. Raw event:
```json
{"timestamp":"2025-09-10T12:00:01Z","type":"tool_result","name":"translate","result":"hola"}
```
Raw payload:
```text
hola
```

3. Raw event:
```json
{"type":"tool_result","session_id":"sid_stage0_large","timestamp":"2025-12-26T02:00:04.000Z","toolCallId":"c1","value":{"stdout":"line1\nline2\nline3\n","exitCode":0},"id":"tr1"}
```
Raw payload:
```json
{"exitCode": 0, "stdout": "line1\nline2\nline3\n"}
```
Parsed payload:
```json
{
  "exitCode": 0,
  "stdout": "line1\nline2\nline3\n"
}
```

## Proposed ToolEventNormalized Schema
```json
{
  "agent_family": "codex|claude|copilot|droid|opencode|gemini|openclaw|other",
  "direction": "input|output|unknown",
  "id": "string",
  "io": {
    "exit_code": "number|null",
    "input": "object|string|null",
    "is_error": "bool|null",
    "output": "object|string|null",
    "stderr": "string|null",
    "stdout": "string|null"
  },
  "raw": {
    "event": "string",
    "field_path": "string|null",
    "payload": "string|null",
    "shape_signature": "string"
  },
  "session_id": "string",
  "source": {
    "event_index": "number|null",
    "file_path": "string"
  },
  "timestamp": "string|number|null",
  "tool": {
    "call_id": "string|null",
    "name": "string|null",
    "name_normalized": "string"
  }
}
```

## UI Formatting Recommendations
- Render tool calls/results as distinct blocks keyed by shape signature and direction.
- When outputs include stdout/stderr or exit codes, show labeled sections and preserve line breaks.
- For text-line tool call patterns, promote JSON payloads into structured UI chips with a fallback raw view.
- Keep raw JSONL lines accessible via a disclosure toggle for schema-drift cases.
- For OpenCode part-tool events, group call/result pairs by tool name and call id when available.
- For Claude toolUseResult outputs, render stdout/stderr separately and surface is_error in badges.

