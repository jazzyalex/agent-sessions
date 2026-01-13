# Tool IO Formats Report
Generated: 2026-01-13T20:27:20Z

## Scan Summary
- claude: 50 files from /Users/alexm/.claude/projects/-Users-alexm-Library-Application-Support-AgentSessions-ClaudeProbeProject, /Users/alexm/.claude/projects/-Users-alexm-Repository-Scripts-tennis-scraper, /Users/alexm/.claude/projects/-Users-alexm-Repository-Scripts-tennis-scraper/b4f868f3-0faf-4fe1-823b-3a78afcadb7a/subagents, ... (+1 more)
- codex: 50 files from /Users/alexm/.codex/sessions/2026/01/05, /Users/alexm/.codex/sessions/2026/01/06, /Users/alexm/.codex/sessions/2026/01/07, ... (+5 more)
- copilot: 4 files from /Users/alexm/.copilot/session-state, /Users/alexm/Repository/Codex-History/Resources/Fixtures/stage0/agents/copilot
- droid: 8 files from /Users/alexm/.factory/sessions/-Users-alexm-Repository-Codex-History, /Users/alexm/.factory/sessions/-Users-alexm-Repository-Triada, /Users/alexm/Repository/Codex-History/Resources/Fixtures/stage0/agents/droid
- gemini: 18 files from /Users/alexm/.gemini/tmp/205016864bd110904e9ad8314192344ab398d043e779da15bedbb9ee9be00da2/chats, /Users/alexm/.gemini/tmp/3d333da47869377b0d17226bcb6ebfca7cffeafe3d810959c7eab1b11ecaef82/chats, /Users/alexm/.gemini/tmp/6ac59b89f2b60533dc79adfac844a7e7327132a85843313b412e1dbd6a91497d/chats
- opencode: 68 files from /Users/alexm/.local/share/opencode/storage/session/122f9b9a5a2395ff21189f1e5fe874e61955d6ac, /Users/alexm/.local/share/opencode/storage/session/global, /Users/alexm/.local/share/opencode/storage/part/msg_b9fa5776b0010bUakPBINe8R0G, ... (+13 more)

## Shape Summary
| Shape Signature | Count | Agents | Directions |
| --- | --- | --- | --- |
| json:part.type=tool | 21 | opencode | input=13, output=8 |
| jsonl:data.toolRequests[] | 7 | copilot | input=7 |
| jsonl:message.content[].type=tool_result | 106 | claude, droid | output=106 |
| jsonl:message.content[].type=tool_use | 106 | claude, droid | input=106 |
| jsonl:response_item:payload.type=tool_call | 2 | codex | input=2 |
| jsonl:response_item:payload.type=tool_result | 2 | codex | output=2 |
| jsonl:toolUseResult | 72 | claude | output=72 |
| jsonl:type=function_call | 3388 | codex | input=3388 |
| jsonl:type=tool.execution_complete | 8 | copilot | output=8 |
| jsonl:type=tool_call | 3 | droid | input=3 |
| jsonl:type=tool_result | 3 | droid | output=3 |
| text:line-prefix+json_block | 1 | claude | unknown=1 |

## Shape: json:part.type=tool
- Count: 21
- Agents: opencode
- Directions: input=13, output=8

Examples:
1. Raw event:
```json
{
  "id": "prt_b9fa5b51c001zmyM3D7vlByckQ",
  "sessionID": "ses_46603d717ffe0DvOjJUqhEghez",
  "messageID": "msg_b9fa5a509001w0p5ZTfYCh2W5x",
  "type": "tool",
  "callID": "toolu_01DTKpQCuguRGKdnscpiBtJT",
  "tool": "write",
  "state": {
    "status": "error",
    "input": {},
    "error": "Tool execution aborted",
    "time": {
      "start": 1767910047697,
      "end": 1767910047697
    }
  }
}
```
Raw payload:
```json
{}
```
Parsed payload:
```json
{}
```

2. Raw event:
```json
{
  "id": "prt_b9fa5b51c001zmyM3D7vlByckQ",
  "sessionID": "ses_46603d717ffe0DvOjJUqhEghez",
  "messageID": "msg_b9fa5a509001w0p5ZTfYCh2W5x",
  "type": "tool",
  "callID": "toolu_01DTKpQCuguRGKdnscpiBtJT",
  "tool": "write",
  "state": {
    "status": "error",
    "input": {},
    "error": "Tool execution aborted",
    "time": {
      "start": 1767910047697,
      "end": 1767910047697
    }
  }
}
```
Raw payload:
```json
{"error": "Tool execution aborted", "output": null}
```
Parsed payload:
```json
{
  "error": "Tool execution aborted",
  "output": null
}
```

## Shape: jsonl:data.toolRequests[]
- Count: 7
- Agents: copilot
- Directions: input=7

Examples:
1. Raw event:
```json
{"type":"assistant.message","data":{"messageId":"14c2937a-e6c1-4c1a-9685-1488456f87b8","content":"","toolRequests":[{"toolCallId":"call_5OAMmXkGd8rHYdaCcbcGO9DG","name":"report_intent","arguments":{"intent":"Listing files"}}]},"id":"776522bd-238e-4782-8cc8-3dcc5a34f8ff","timestamp":"2025-12-18T21:35:24.795Z","parentId":"5dabb283-8295-4faa-bc10-ac022c999a65"}
```
Raw payload:
```json
{"intent": "Listing files"}
```
Parsed payload:
```json
{
  "intent": "Listing files"
}
```

2. Raw event:
```json
{"type":"assistant.message","data":{"messageId":"53707888-75e7-4f54-bb55-84e4de52da2b","content":"","toolRequests":[{"toolCallId":"call_ombKsNixv0YM9S8d2ilSwcrt","name":"bash","arguments":{"command":"find . -mindepth 1 -not -path '*/.*' -not -path '*/tmp/*' -not -name 'tmp' -print | sed 's#^./##' | sort","description":"List files recursively excluding hidden and tmp directories","mode":"sync","initial_wait":30}}]},"id":"269a2662-f084-4d7c-9daf-c73086a00f5e","timestamp":"2025-12-18T21:35:24.796Z","parentId":"4e544a21-c2a1-4aa0-8001-9ce2166543b8"}
```
Raw payload:
```json
{"command": "find . -mindepth 1 -not -path '*/.*' -not -path '*/tmp/*' -not -name 'tmp' -print | sed 's#^./##' | sort", "description": "List files recursively excluding hidden and tmp directories", "initial_wait": 30, "mode": "sync"}
```
Parsed payload:
```json
{
  "command": "find . -mindepth 1 -not -path '*/.*' -not -path '*/tmp/*' -not -name 'tmp' -print | sed 's#^./##' | sort",
  "description": "List files recursively excluding hidden and tmp directories",
  "initial_wait": 30,
  "mode": "sync"
}
```

3. Raw event:
```json
{"type":"assistant.message","data":{"messageId":"6ae2f112-bc31-4bb9-8dc8-bb2323df2072","content":"","toolRequests":[{"toolCallId":"call_tSoXp0GTb019WrGyRj1H9q4u","name":"report_intent","arguments":{"intent":"Listing commits"}}]},"id":"404e5146-7605-4185-ba05-ee52f6664a74","timestamp":"2025-12-18T21:36:35.798Z","parentId":"7b5e5eef-89e7-4517-8838-9dffeb857eb4"}
```
Raw payload:
```json
{"intent": "Listing commits"}
```
Parsed payload:
```json
{
  "intent": "Listing commits"
}
```

## Shape: jsonl:message.content[].type=tool_result
- Count: 106
- Agents: claude, droid
- Directions: output=106

Examples:
1. Raw event:
```json
{"parentUuid":"371e5438-4348-4ba1-9c45-bc4adcc80aa0","isSidechain":false,"userType":"external","cwd":"/Users/alexm/Repository/Scripts/tennis-scraper","sessionId":"b4f868f3-0faf-4fe1-823b-3a78afcadb7a","version":"2.1.5","gitBranch":"master","slug":"unified-stargazing-starfish","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01PGf9uz1GQLomdtz38mij68","type":"tool_result","content":"","is_error":false}]},"uuid":"e0854d5d-bc13-423c-8180-b4e09e913be7","timestamp":"2026-01-13T00:53:46.307Z","toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false},"sourceToolAssistantUUID":"371e5438-4348-4ba1-9c45-bc4adcc80aa0"}
```
Raw payload:
```text

```

2. Raw event:
```json
{"parentUuid":"5006aa37-43ad-4728-9bf7-b8b422cd1908","isSidechain":false,"userType":"external","cwd":"/Users/alexm/Repository/Scripts/tennis-scraper","sessionId":"b4f868f3-0faf-4fe1-823b-3a78afcadb7a","version":"2.1.5","gitBranch":"master","slug":"unified-stargazing-starfish","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_015JgSSG2SF7uUMFgvaudzVy","type":"tool_result","content":"","is_error":false}]},"uuid":"06d3acd5-5879-439d-a87a-4e1454164039","timestamp":"2026-01-13T00:54:00.630Z","toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false},"sourceToolAssistantUUID":"5006aa37-43ad-4728-9bf7-b8b422cd1908"}
```
Raw payload:
```text

```

3. Raw event:
```json
{"parentUuid":"8c4b7da2-fb3a-459c-832f-bc13fa88b0b8","isSidechain":false,"userType":"external","cwd":"/Users/alexm/Repository/Scripts/tennis-scraper","sessionId":"b4f868f3-0faf-4fe1-823b-3a78afcadb7a","version":"2.1.5","gitBranch":"master","slug":"unified-stargazing-starfish","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01JiQiQGEJJjdZdsQzH1GQ7E","type":"tool_result","content":"","is_error":false}]},"uuid":"9e61f658-e84b-41b1-b21c-bb731c230224","timestamp":"2026-01-13T20:17:38.174Z","toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false},"sourceToolAssistantUUID":"8c4b7da2-fb3a-459c-832f-bc13fa88b0b8"}
```
Raw payload:
```text

```

## Shape: jsonl:message.content[].type=tool_use
- Count: 106
- Agents: claude, droid
- Directions: input=106

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

## Shape: jsonl:response_item:payload.type=tool_call
- Count: 2
- Agents: codex
- Directions: input=2

Examples:
1. Raw event:
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

2. Raw event:
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

## Shape: jsonl:response_item:payload.type=tool_result
- Count: 2
- Agents: codex
- Directions: output=2

Examples:
1. Raw event:
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

2. Raw event:
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

## Shape: jsonl:toolUseResult
- Count: 72
- Agents: claude
- Directions: output=72

Examples:
1. Raw event:
```json
{"parentUuid":"371e5438-4348-4ba1-9c45-bc4adcc80aa0","isSidechain":false,"userType":"external","cwd":"/Users/alexm/Repository/Scripts/tennis-scraper","sessionId":"b4f868f3-0faf-4fe1-823b-3a78afcadb7a","version":"2.1.5","gitBranch":"master","slug":"unified-stargazing-starfish","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01PGf9uz1GQLomdtz38mij68","type":"tool_result","content":"","is_error":false}]},"uuid":"e0854d5d-bc13-423c-8180-b4e09e913be7","timestamp":"2026-01-13T00:53:46.307Z","toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false},"sourceToolAssistantUUID":"371e5438-4348-4ba1-9c45-bc4adcc80aa0"}
```
Raw payload:
```json
{"interrupted": false, "isImage": false, "stderr": "", "stdout": ""}
```
Parsed payload:
```json
{
  "interrupted": false,
  "isImage": false,
  "stderr": "",
  "stdout": ""
}
```

2. Raw event:
```json
{"parentUuid":"5006aa37-43ad-4728-9bf7-b8b422cd1908","isSidechain":false,"userType":"external","cwd":"/Users/alexm/Repository/Scripts/tennis-scraper","sessionId":"b4f868f3-0faf-4fe1-823b-3a78afcadb7a","version":"2.1.5","gitBranch":"master","slug":"unified-stargazing-starfish","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_015JgSSG2SF7uUMFgvaudzVy","type":"tool_result","content":"","is_error":false}]},"uuid":"06d3acd5-5879-439d-a87a-4e1454164039","timestamp":"2026-01-13T00:54:00.630Z","toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false},"sourceToolAssistantUUID":"5006aa37-43ad-4728-9bf7-b8b422cd1908"}
```
Raw payload:
```json
{"interrupted": false, "isImage": false, "stderr": "", "stdout": ""}
```
Parsed payload:
```json
{
  "interrupted": false,
  "isImage": false,
  "stderr": "",
  "stdout": ""
}
```

3. Raw event:
```json
{"parentUuid":"8c4b7da2-fb3a-459c-832f-bc13fa88b0b8","isSidechain":false,"userType":"external","cwd":"/Users/alexm/Repository/Scripts/tennis-scraper","sessionId":"b4f868f3-0faf-4fe1-823b-3a78afcadb7a","version":"2.1.5","gitBranch":"master","slug":"unified-stargazing-starfish","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01JiQiQGEJJjdZdsQzH1GQ7E","type":"tool_result","content":"","is_error":false}]},"uuid":"9e61f658-e84b-41b1-b21c-bb731c230224","timestamp":"2026-01-13T20:17:38.174Z","toolUseResult":{"stdout":"","stderr":"","interrupted":false,"isImage":false},"sourceToolAssistantUUID":"8c4b7da2-fb3a-459c-832f-bc13fa88b0b8"}
```
Raw payload:
```json
{"interrupted": false, "isImage": false, "stderr": "", "stdout": ""}
```
Parsed payload:
```json
{
  "interrupted": false,
  "isImage": false,
  "stderr": "",
  "stdout": ""
}
```

## Shape: jsonl:type=function_call
- Count: 3388
- Agents: codex
- Directions: input=3388

Examples:
1. Raw event:
```json
{"timestamp":"2026-01-13T20:09:06.916Z","type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"{\"command\":\"ls\",\"workdir\":\"/Users/alexm/Repository/Codex-History\"}","call_id":"call_fNOi78ulEiGq7EXpJIDarDDd"}}
```
Raw payload:
```json
{"command":"ls","workdir":"/Users/alexm/Repository/Codex-History"}
```
Parsed payload:
```json
{
  "command": "ls",
  "workdir": "/Users/alexm/Repository/Codex-History"
}
```

2. Raw event:
```json
{"timestamp":"2026-01-13T20:09:09.241Z","type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"{\"command\":\"cat AGENTS.md\",\"workdir\":\"/Users/alexm/Repository/Codex-History\"}","call_id":"call_jdBFwIKfi3Jz6LpDmYFhwxV1"}}
```
Raw payload:
```json
{"command":"cat AGENTS.md","workdir":"/Users/alexm/Repository/Codex-History"}
```
Parsed payload:
```json
{
  "command": "cat AGENTS.md",
  "workdir": "/Users/alexm/Repository/Codex-History"
}
```

3. Raw event:
```json
{"timestamp":"2026-01-13T20:09:14.429Z","type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"{\"command\":\"rg --files -g '*.jsonl'\",\"workdir\":\"/Users/alexm/Repository/Codex-History\"}","call_id":"call_4nXwCt1jD8zAVlhWvsp8yF8T"}}
```
Raw payload:
```json
{"command":"rg --files -g '*.jsonl'","workdir":"/Users/alexm/Repository/Codex-History"}
```
Parsed payload:
```json
{
  "command": "rg --files -g '*.jsonl'",
  "workdir": "/Users/alexm/Repository/Codex-History"
}
```

## Shape: jsonl:type=tool.execution_complete
- Count: 8
- Agents: copilot
- Directions: output=8

Examples:
1. Raw event:
```json
{"type":"tool.execution_complete","data":{"toolCallId":"call_5OAMmXkGd8rHYdaCcbcGO9DG","success":true,"result":{"content":"Intent logged"},"toolTelemetry":{}},"id":"637ab614-79de-437e-8165-0e4e1e86dd87","timestamp":"2025-12-18T21:35:24.809Z","parentId":"6de1fdec-68d9-4e2f-b606-083cce230562"}
```
Raw payload:
```json
{"content": "Intent logged"}
```
Parsed payload:
```json
{
  "content": "Intent logged"
}
```

2. Raw event:
```json
{"type":"tool.execution_complete","data":{"toolCallId":"call_tSoXp0GTb019WrGyRj1H9q4u","success":true,"result":{"content":"Intent logged"},"toolTelemetry":{}},"id":"c8fe4aa9-c325-4162-a3ef-71894850a471","timestamp":"2025-12-18T21:36:35.801Z","parentId":"bc6f8c1a-e7ba-46e3-96ff-249b1e183896"}
```
Raw payload:
```json
{"content": "Intent logged"}
```
Parsed payload:
```json
{
  "content": "Intent logged"
}
```

3. Raw event:
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

## Shape: jsonl:type=tool_call
- Count: 3
- Agents: droid
- Directions: input=3

Examples:
1. Raw event:
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

2. Raw event:
```json
{"type":"tool_call","sessionId":"sid_stage0_drift","timestamp":1767812642000,"id":"call_1","messageId":"m1","toolId":"Execute","toolName":"Execute","parameters":{"command":"ls -la","riskLevel":"low","riskLevelReason":"Read-only directory listing."}}
```
Raw payload:
```json
{"command": "ls -la", "riskLevel": "low", "riskLevelReason": "Read-only directory listing."}
```
Parsed payload:
```json
{
  "command": "ls -la",
  "riskLevel": "low",
  "riskLevelReason": "Read-only directory listing."
}
```

3. Raw event:
```json
{"type":"tool_call","session_id":"sid_stage0_small","timestamp":"2025-12-26T00:00:01.000Z","toolCallId":"c1","toolName":"Shell","parameters":{"command":"echo hi"}}
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

## Shape: jsonl:type=tool_result
- Count: 3
- Agents: droid
- Directions: output=3

Examples:
1. Raw event:
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

2. Raw event:
```json
{"type":"tool_result","sessionId":"sid_stage0_drift","timestamp":1767812643000,"id":"call_1","messageId":"m1","toolId":"Execute","isError":true,"value":"ls: /non-existent-directory: No such file or directory"}
```
Raw payload:
```text
ls: /non-existent-directory: No such file or directory
```

3. Raw event:
```json
{"type":"tool_result","session_id":"sid_stage0_small","timestamp":"2025-12-26T00:00:02.000Z","toolCallId":"c1","value":{"stdout":"hi\n","exitCode":0}}
```
Raw payload:
```json
{"exitCode": 0, "stdout": "hi\n"}
```
Parsed payload:
```json
{
  "exitCode": 0,
  "stdout": "hi\n"
}
```

## Shape: text:line-prefix+json_block
- Count: 1
- Agents: claude
- Directions: unknown=1

Examples:
1. Raw event:
```text
--bg: #f5f5f5;
--blue: #4472C4;
--chip-flight: #5d6677;
--chip-local: #1f7a4d;
--chip-road: #8a6d1a;
--dark: #2c3e50;
--muted: #7f8c8d;
--row-alt: #D9E2F3;
:root {
}
<head>
<html>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width
<style>
<title>USTA G12 Tournaments - NorCal and National</title>
awk: trying to access out of range field -1
 input record number 18, file /Users/alexm/Repository/Scripts/tennis-scraper/2025-usta-norcal-national.html
 source line number 1
```
Raw payload:
```json
{
}
```
Parsed payload:
```json
{}
```

## Proposed ToolEventNormalized Schema
```json
{
  "agent_family": "codex|claude|copilot|droid|opencode|gemini|other",
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

