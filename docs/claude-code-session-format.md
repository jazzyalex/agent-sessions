# Claude Code Session Format Analysis

## Overview
Claude Code stores sessions as JSONL files in `~/.claude/` with a different structure than Codex CLI.

## Storage Locations

### Discovered paths:
```
~/.claude/history.jsonl                                          # Global history
~/.claude/projects/-Users-alexm-Repository-<project>/UUID.jsonl  # Project-specific sessions
```

## Session File Structure

### File naming:
- **Codex**: `rollout-YYYY-MM-DDThh-mm-ss-UUID.jsonl`
- **Claude Code**: `UUID.jsonl` (stored in project-specific directories)

### JSONL Event Format

Each line is a JSON object representing an event. Key event types:

#### 1. Summary Event
```json
{
  "type": "summary",
  "summary": "Customizing Terminal Prompt with Time Display",
  "leafUuid": "a510239b-8ab6-4a8f-a448-2f8519a7dfc9"
}
```

#### 2. User Message
```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": "switch to branch Claude-support..."
  },
  "timestamp": "2025-10-02T20:15:32.885Z",
  "cwd": "/Users/alexm/Repository/Codex-History",
  "sessionId": "06cc67e8-9cc6-4537-83a9-ce36374a4c31",
  "version": "2.0.5",
  "gitBranch": "main",
  "uuid": "21cc4e82-7e8e-4867-9b6d-ce103e7ca818",
  "parentUuid": null,
  "isSidechain": false,
  "userType": "external",
  "isMeta": true
}
```

**Important:** User message text is nested in `message.content`, not at top level like Codex!

#### 3. System Event
```json
{
  "type": "system",
  "subtype": "local_command",
  "content": "<command-name>/model</command-name>...",
  "level": "info",
  "timestamp": "2025-10-02T20:16:48.196Z",
  "uuid": "c9159e63-104b-4249-bce1-eba1047a2e7f",
  "isMeta": false
}
```

#### 4. File History Snapshot
```json
{
  "type": "file-history-snapshot",
  "messageId": "cb3a8555-28bd-473f-b75f-06ff9e55a905",
  "snapshot": {
    "messageId": "...",
    "trackedFileBackups": {},
    "timestamp": "2025-10-02T20:15:32.887Z"
  },
  "isSnapshotUpdate": false
}
```

## Key Field Mapping

### Session-level Fields

| Field | Codex | Claude Code | Notes |
|-------|-------|-------------|-------|
| Session ID | Extracted from filename | `sessionId` field | UUID format in both |
| Timestamp | ISO string at top level | `timestamp` field | ISO 8601 format |
| Working Dir | `cwd` or `<cwd>` tags | `cwd` field | Present in most events |
| Git Branch | `git_branch` or heuristics | `gitBranch` field | Top-level field |
| Model | `model` field | **Not present** | Claude Code doesn't store per-event |
| Version | Not stored | `version` field | e.g., "2.0.5" |

### Event-level Fields

| Field | Codex | Claude Code |
|-------|-------|-------------|
| Event Type | `role` / `type` | `type` (required) |
| User Content | `text`, `content`, or `message` | `message.content` (nested!) |
| System Content | `text` or `content` | `content` |
| Metadata Flag | Various | `isMeta` boolean |
| Event ID | Generated | `uuid` field |
| Parent Event | Not tracked | `parentUuid` field |

### Content Structure

**Codex format:**
```json
{
  "role": "user",
  "text": "The actual message text"
}
```

**Claude Code format:**
```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": "The actual message text"
  }
}
```

**Multimodal content (images):**
```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": [
      {"type": "text", "text": "Text content"},
      {"type": "image", "source": {...}}
    ]
  }
}
```

## Discovery Statistics (from test run)

```
📊 Claude Code Sessions Found: 31
  - With cwd: 28 (90%)
  - With title: 23 (74%)
  - With model: 0 (0%)
  - With git branch: Most (extracted from gitBranch field)
```

## Differences from Codex

### 1. Message Nesting
- **Codex**: Content at top level (`text`, `content`)
- **Claude**: Nested in `message.content` object

### 2. Event Threading
- **Codex**: Flat list of events
- **Claude**: Tree structure via `uuid`/`parentUuid`

### 3. Model Information
- **Codex**: Per-event `model` field
- **Claude**: Not stored (likely inferred from session version)

### 4. File Organization
- **Codex**: Date-based hierarchy (`YYYY/MM/DD/rollout-*.jsonl`)
- **Claude**: Project-based hierarchy (`projects/<encoded-path>/UUID.jsonl`)

### 5. Meta Events
- **Codex**: Various type markers
- **Claude**: Explicit `isMeta` boolean + special types (`summary`, `file-history-snapshot`)

## Implementation Notes for Agent Sessions App

### Required Parser Changes

1. **Title Extraction:**
   - Check `event.type == "user"` (not `role`)
   - Extract from `event.message.content` (nested)
   - Handle list content (multimodal)
   - Skip events where `isMeta == true`

2. **Session ID:**
   - Use `sessionId` field
   - Fallback to filename UUID

3. **Working Directory:**
   - Use `cwd` field (top-level, not nested)

4. **Git Branch:**
   - Use `gitBranch` field (top-level)

5. **Model Display:**
   - Show version instead? (e.g., "Claude Code 2.0.5")
   - Or mark as "—" / unknown

### Reusable Components

- ✅ **JSONLReader**: Works as-is
- ✅ **Date parsing**: ISO timestamps work
- ✅ **File enumeration**: Standard filesystem scan
- ⚠️ **SessionEvent parser**: Needs Claude-specific branch
- ⚠️ **Title extraction**: Different logic needed

## Next Steps for Integration

1. Create `SessionSource` enum (`.codex`, `.claude`)
2. Add source-aware parsing in `SessionIndexer`
3. Handle different file discovery patterns
4. Map Claude events to unified `SessionEvent` model
5. Update UI to show source badge/column
6. Test with real sessions (31 available!)

## Sample Titles Extracted

```
switch to branch Claude-support - we s..
analyze code.we work now on Highlight ..
Configure my statusLine from my shell ..
design a basic apple calendar integrat..
Task: Fix Vertical Calendar Layout Spa..
im trying to find why my script using ..
show list of recent commits
```

## Test Script

Location: `/Users/alexm/Repository/Codex-History/tools/list-claude-sessions.py`

Run: `python3 tools/list-claude-sessions.py`
