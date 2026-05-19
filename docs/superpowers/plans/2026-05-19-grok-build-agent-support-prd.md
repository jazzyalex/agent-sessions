# Grok Build CLI Support PRD

Date: 2026-05-19
Repository: `/Users/alexm/Repository/Codex-History`
Work type: new provider support planning
Status: PRD only. Do not claim Grok Build support until real local sessions are captured, redacted, fixture-backed, and tested.

## Decision

Prepare for tier-2 Grok Build CLI support in Agent Sessions, subject to the hard evidence gates below.

Acceptable first shipped scope, if gates pass:
- Discover local Grok Build sessions from verified on-disk storage.
- Browse and search Grok transcripts in Unified Sessions.
- Show Grok provider labels, colors, filters, onboarding, and Preferences controls.
- Support resume/copy-resume command construction only if the verified CLI behavior maps cleanly to persisted session IDs.
- Add weekly schema monitoring after fixtures and a real discovery contract exist.

Do not ship or market:
- Agent Cockpit/live active-session support.
- Usage or credit tracking.
- Analytics parity.
- Subagent hierarchy.
- Cloud/share history support.
- "Full Grok support" language.

Those surfaces require separate evidence and tests.

## Current Evidence

Official xAI Build docs establish the product shape:
- `https://docs.x.ai/build/overview`: Grok Build is an interactive TUI, headless CLI, and ACP agent. Install command is `curl -fsSL https://x.ai/cli/install.sh | bash`; interactive use is `cd your-project && grok`; non-browser use can set `XAI_API_KEY`; headless commands include `grok -p "Explain this codebase"` and `--output-format streaming-json`.
- `https://docs.x.ai/build/cli/headless-scripting`: headless flags include `-p/--single`, `-m/--model`, `-s/--session-id`, `-r/--resume`, `-c/--continue`, `--cwd`, `--output-format`, and `--always-approve`. Output formats are `plain`, `json`, and `streaming-json`. ACP runs as `grok agent stdio`.
- `https://docs.x.ai/build/modes-and-commands`: TUI supports `/new`, `/resume`, `/sessions`, `/fork`, `/rename`, `/session-info`, `/context`, `/usage`, `/logout`, `/plan`, `/btw`, `/rewind`, `/hooks`, `/plugins`, `/skills`, and `/mcps`. Plan mode blocks write tools except the session plan file. Permission behavior belongs in user-level `~/.grok/config.toml`.
- `https://docs.x.ai/build/features/skills-plugins-marketplaces`: Grok discovers project and user `.grok` skills/plugins/hooks, supports subagents, reads Claude Code instructions/plugins/skills, reads `AGENTS.md`, and hook environments include `GROK_SESSION_ID` and `GROK_WORKSPACE_ROOT`.
- `https://x.ai/cli`: Grok Build Beta is described as early beta for SuperGrok Heavy subscribers and highlights skills, plan mode, plugins, Q&A, and subagents.

Local facts from this machine:
- `command -v grok` produced no path.
- `~/.grok` does not exist.
- `https://x.ai/cli/stable` returned `0.1.212`.
- The official installer script links the binary into `~/.grok/bin/grok` and `~/.grok/bin/agent`, writes completions under `~/.grok/completions`, persists installer metadata in `~/.grok/config.toml`, may read `~/.grok/auth.json`, and may modify the user's shell config to add `~/.grok/bin` to PATH.

Unknown until local capture:
- The durable transcript/session storage format.
- Whether storage is JSONL, JSON, SQLite, multiple files, or cloud-only.
- Whether headless `streaming-json` events are also persisted locally.
- Whether persisted session IDs match `--session-id`, `--resume`, `/session-info`, ACP `sessionId`, or another internal ID.
- Whether subagents create separate files, in-file parent/child records, or only live TUI state.

## Product Goals

1. Let Agent Sessions users browse and search local Grok Build coding sessions with the same quality bar as Pi, Hermes, OpenClaw, OpenCode, Copilot, Gemini, Claude, and Codex.
2. Keep Grok Build integration honest: only expose surfaces backed by real local files and tests.
3. Avoid irreversible or noisy machine changes during provider validation.
4. Capture fixtures that preserve real schema, event names, timestamps, IDs, model fields, tool records, and resume fields while removing secrets and private content.
5. Make future Grok version checks possible through `scripts/agent_watch.py` once a baseline exists.

## Non-Goals

- No global install, login, or paid account use inside this PRD.
- No implementation until a real local Grok session capture exists.
- No parsing from docs or synthetic output alone.
- No support for unofficial community `grok-cli` packages.
- No use of hook-created logs as the primary transcript source unless no first-party local transcript exists and the support decision explicitly accepts a reduced capture contract.

## Hard Gates

| Gate | Required result | Current status |
| --- | --- | --- |
| Region and plan availability | A maintainer can use Grok Build from the United States with SuperGrok Heavy or an existing xAI API key. | Not verified locally. |
| English usability | Docs, CLI output, and auth flow are usable in English. | Docs verified in English; CLI not installed. |
| Install is reversible | Installer effects, binary path, auth path, PATH edits, and cleanup path are recorded before install. | Installer script inspected; no install run. |
| Real local data exists | At least one normal session, one continued/resumed session, and one tool-use session produce durable local state. | Blocked until install/auth/test. |
| Format is maintainable | Session storage has stable fields for ID, time, cwd, role/content, model, tool calls/results, and enough metadata for search. | Unknown. |
| Fixture is safe | Redacted fixture can preserve schema without secrets, tokens, account IDs, private prompts, or absolute user paths. | Unknown. |
| Resume is grounded | `grok --resume`, `--session-id`, `--continue`, `/resume`, or ACP IDs can be mapped to persisted sessions. | Unknown. |
| Marketing language is bounded | Public wording names only verified surfaces. | Must remain tier-2 until proven otherwise. |

## User Stories

- As a user, I can enable Grok in Preferences and point Agent Sessions at a custom Grok state/session root if my app environment cannot inherit shell state.
- As a user, I can see Grok sessions in Unified Sessions with a clear provider label and stable color.
- As a user, I can search Grok prompts, assistant text, tool calls, and tool results from local transcript files.
- As a user, I can open a Grok transcript and see readable user, assistant, tool, tool-result, error, and metadata events.
- As a maintainer, I can rerun fixture tests and weekly schema checks without using private local history.
- As a maintainer, I can avoid support claims for live status, usage, analytics, or subagents until those are separately validated.

## Controlled Local Test Plan

Do this in a dedicated validation pass, not as part of this PRD.

Pre-install inventory:
```bash
date -u +"%Y-%m-%dT%H:%M:%SZ"
command -v grok || true
command -v agent || true
test -d "$HOME/.grok" && find "$HOME/.grok" -maxdepth 4 -print | sort | sed -n '1,200p'
test -f "$HOME/.zshrc" && rg -nF "grok installer" "$HOME/.zshrc" || true
curl -fsSL --max-time 20 https://x.ai/cli/stable
```

Install options:
```bash
# Preferred for contained validation if xAI installer respects GROK_BIN_DIR.
curl -fsSL https://x.ai/cli/install.sh | \
  GROK_BIN_DIR=/tmp/as-agent-lab/grok-bin bash

# Official default install, only after approval.
curl -fsSL https://x.ai/cli/install.sh | bash
```

Post-install probes:
```bash
command -v grok
grok --version
grok --help
grok inspect
find "$HOME/.grok" -maxdepth 5 -type f -print | sort
```

Disposable project:
```bash
rm -rf /tmp/as-agent-lab/grok-build-project
mkdir -p /tmp/as-agent-lab/grok-build-project
cd /tmp/as-agent-lab/grok-build-project
git init
cat > hello.py <<'PY'
def greet(name: str) -> str:
    return f"hello {name}"

if __name__ == "__main__":
    print(greet("fixture"))
PY
```

Required safe test sessions:
```bash
# Normal read-only headless session.
grok -p "Explain hello.py in one short paragraph. Do not edit files." \
  --cwd /tmp/as-agent-lab/grok-build-project \
  --output-format streaming-json

# Named session or resumable session, depending on observed help output.
grok -s as-fixture-readonly \
  -p "Remember that this fixture project contains hello.py. Do not edit files." \
  --cwd /tmp/as-agent-lab/grok-build-project \
  --output-format json

grok -r as-fixture-readonly \
  -p "What file did I ask about earlier? Do not edit files." \
  --cwd /tmp/as-agent-lab/grok-build-project \
  --output-format json

# Tool-use session in a disposable directory.
grok -p "List the files in this directory, read hello.py, and report the function name. Do not edit files." \
  --cwd /tmp/as-agent-lab/grok-build-project \
  --always-approve \
  --output-format streaming-json
```

Optional TUI probes, only after headless capture works:
- Start `grok` in the disposable project.
- Run `/session-info`, `/rename as-fixture-tui`, `/usage`, `/plan`, `/sessions`, `/resume`, and `/fork`.
- Trigger a small subagent if the account plan allows it.
- Run `/flush` before checking local storage.

Format discovery after each command:
```bash
find "$HOME/.grok" -maxdepth 7 -type f -print0 \
  | xargs -0 ls -lT \
  | sort

find "$HOME/.grok" -maxdepth 7 -type f \( -name '*.json' -o -name '*.jsonl' -o -name '*.db' -o -name '*.sqlite' -o -name '*.toml' \) -print
```

Do not scan all of `$HOME`. If files are not under `~/.grok`, use the CLI's own `inspect`, `/session-info`, and docs before widening scope.

## Format Questions To Answer

For every candidate session file or database, record:
- Root layout and filename pattern.
- Whether auth files and transcript files are separated.
- Session ID fields and whether they match CLI resume IDs.
- Cwd/project fields and whether they are absolute, relative, hashed, or absent.
- Timestamp format and timezone.
- Event families for user, assistant, reasoning/thought, tool call, tool result, file edit, command execution, error, compaction, summary, fork, rename, subagent spawn, and usage.
- Content shape for text, file references, code blocks, images, and attachments.
- Model fields and custom model fields.
- Token/usage records, if local and non-sensitive.
- Whether headless `streaming-json` is equivalent to persisted transcript events.
- Whether ACP `session/update` chunks are persisted or only streamed.
- Whether hook environment IDs match persisted session IDs.

## Fixture Requirements

Raw captures must stay private under:
```text
scripts/agent_captures/<timestamp>/grok/
```

Checked-in redacted fixtures should live under:
```text
Resources/Fixtures/stage0/agents/grok/
```

Minimum fixture set if format allows:
- `small` fixture: one user prompt, one assistant answer, cwd/model/session metadata.
- `tool` fixture: command/read/list events plus tool results.
- `resume` fixture: named or resumed session evidence.
- `schema_drift` fixture: unknown-but-valid event family preserved as metadata.
- `subagent` fixture: only if real Grok subagent records exist locally.

Redaction rules:
- Remove tokens, cookies, auth headers, account IDs, emails, share URLs, machine-specific usernames, and private prompt content.
- Replace absolute user paths with fixture paths while preserving path field names and path-shape semantics.
- Preserve event names, nesting, timestamp shapes, field names, ordering, and representative IDs.

Secret/path scan:
```bash
rg -n "xai-|Bearer|token|cookie|auth|/Users/alexm|@|https://grok.com/share|https://x.com" Resources/Fixtures/stage0/agents/grok scripts/agent_captures/<timestamp>/grok
```

## Functional Requirements

### Provider Metadata

Add `SessionSource.grok` with:
- Display name: `Grok`
- Feature description: `Browse your Grok Build sessions`
- Version introduced: next release version
- Icon: choose an existing SF Symbol that does not imply unsupported live status
- Brand color: distinct from Codex, Claude, Gemini, OpenCode, Hermes, Copilot, Droid, OpenClaw, Cursor, and Pi

Touch points:
- `AgentSessions/Model/SessionSource.swift`
- `AgentSessions/Services/TranscriptColorSystem.swift`
- `AgentSessions/Analytics/Utilities/AnalyticsColors.swift`
- `AgentSessions/Views/SessionTerminalView.swift`
- `AgentSessions/Views/CockpitView.swift` only for labels if needed, not live support

### Settings And CLI Probe

Add `GrokSettings` and `GrokCLIEnvironment` if local capture confirms a CLI binary is useful for resume or Preferences.

Settings must include:
- Binary path override.
- Session/state root override.
- Preferred terminal setting only if resume support is accepted.
- Fallback working directory policy mirroring Pi/Hermes patterns if persisted sessions can omit cwd.

Probe should verify:
- Binary path.
- `grok --version`.
- Accepted auth environment names from help or ACP initialization.
- Default state root existence.

Do not store API keys in Agent Sessions.

Touch points:
- `AgentSessions/Grok/GrokSettings.swift`
- `AgentSessions/Grok/GrokCLIEnvironment.swift`
- `AgentSessions/Views/Preferences/PreferencesView+Grok.swift`
- `AgentSessions/Views/PreferencesView.swift`
- `AgentSessions/Views/Preferences/PreferencesConstants.swift`
- `AgentSessions/Services/AgentEnablement.swift`

### Discovery

Add `GrokSessionDiscovery` only after real root layout is known.

Discovery must:
- Start from `~/.grok` or the verified root, not `$HOME`.
- Skip auth/config/cache/download/completion files.
- Bound recursion and avoid package/plugin marketplaces unless they contain verified session state.
- Use two signals for candidate files if possible: path contract plus schema marker.
- Sort by modification time descending.
- Support custom root override.

Touch points:
- `AgentSessions/Services/GrokSessionDiscovery.swift`
- `AgentSessions/Services/GrokSessionIndexer.swift`
- `AgentSessions/Services/UnifiedSessionIndexer.swift`
- `AgentSessions/Search/SearchCoordinator.swift`

### Parser

Add `GrokSessionParser`.

Parser must:
- Provide lightweight preview parsing and full parsing.
- Preserve unknown valid event families as `.meta` with raw JSON.
- Reject malformed middle records.
- Tolerate only an unterminated trailing JSONL record if Grok writes live JSONL files.
- Build stable `Session.id` values from provider IDs, not file paths, unless real format lacks stable IDs.
- Extract `cwd`, repo name, model, title, start/end timestamps, event count, and tool count.
- Redact or suppress internal system/developer noise only after verifying user-facing transcript expectations.

Event mapping:
- User prompt -> `.user`
- Assistant answer or message chunk aggregate -> `.assistant`
- Shell/file/tool call -> `.tool`
- Tool result/output -> `.toolResult`
- Error/failure -> `.error`
- Rename/fork/usage/plan/subagent metadata -> `.meta`, unless a stronger local pattern exists

Touch points:
- `AgentSessions/Services/GrokSessionParser.swift`
- `AgentSessions/Services/SessionTranscriptBuilder.swift` only if existing transcript rendering cannot represent Grok events
- Provider-specific transcript view only if Grok requires richer rendering than the generic terminal view

### Resume And Copy Command

Implement only after mapping persisted session ID to CLI resume behavior.

Candidate command behavior from docs:
- `grok -r <ID>` resumes an existing session.
- `grok -s <ID>` creates or resumes a named headless session.
- `grok -c` continues the most recent session in the current directory.
- `grok --cwd <PATH>` sets working directory.

Possible accepted first scope:
- Copy command: `cd <cwd> && grok -r <session-id>`
- Fallback: `cd <cwd> && grok -c`
- Terminal launch only if binary probe passes.

Touch points:
- `AgentSessions/GrokResume/GrokResumeTypes.swift`
- `AgentSessions/GrokResume/GrokResumeCommandBuilder.swift`
- `AgentSessions/GrokResume/GrokResumeCoordinator.swift`
- `AgentSessions/GrokResume/GrokTerminalLauncher.swift`
- `AgentSessions/Views/UnifiedSessionsView.swift`

### Search And Unified Sessions

Grok should participate in:
- Provider filter toggles.
- Unified indexing.
- Search include flags.
- Source labels.
- Deleted/missing session handling if provider removes files.
- Onboarding/new-provider discoverability.

Touch points:
- `AgentSessions/Services/UnifiedSessionIndexer.swift`
- `AgentSessions/Search/SearchCoordinator.swift`
- `AgentSessions/Views/UnifiedSessionsView.swift`
- `AgentSessions/Onboarding/Views/OnboardingSheetView.swift`
- `AgentSessionsTests/NewProviderDiscoverabilityTests.swift`

### Monitoring

After implementation lands:
- Add Grok to `docs/agent-support/agent-support-matrix.yml`.
- Add Grok to `docs/agent-support/agent-support-ledger.yml`.
- Add Grok to `docs/agent-json-tracking.md`.
- Add a `grok` entry to `docs/agent-support/agent-watch-config.json`.
- Add a prebump driver in `scripts/agent_watch_prebump_drivers.py` only if headless fixture generation can run safely without paid/interactive blockers.

Monitoring must not use `--always-approve` outside a disposable project.

## Non-Functional Requirements

- Indexing must be bounded and cancellable.
- Large transcript parsing must follow existing preview/full-parse patterns.
- Live-written files must not cause parser crashes.
- No secrets from `~/.grok/auth.json`, config files, managed config, plugins, or marketplaces may enter fixtures or app display.
- Global installer side effects must be documented in the support plan before any install.
- Swift/project changes require Debug build before presenting results.
- If project.pbxproj is modified directly, resolve package dependencies before building.

## Implementation Milestones

### Milestone 0: Evidence Capture

Deliverables:
- Completed support-plan doc with command output and local paths.
- Raw capture under `scripts/agent_captures/<timestamp>/grok/`.
- Redacted fixture draft under `Resources/Fixtures/stage0/agents/grok/`.
- Schema notes answering the format questions above.

Exit criteria:
- Maintainer can point to real local Grok files that contain user/assistant content and session IDs.
- Fixture scan is clean.
- Unsupported surfaces are explicitly listed.

### Milestone 1: Parser And Discovery

Deliverables:
- `GrokSessionParser`
- `GrokSessionDiscovery`
- Parser and discovery tests.

Exit criteria:
- Small/tool/resume fixtures parse.
- Malformed middle records are rejected.
- Unknown valid events are preserved as metadata.
- Discovery does not pick up auth/config/cache files.

### Milestone 2: Unified Sessions And Search

Deliverables:
- `GrokSessionIndexer`
- `UnifiedSessionIndexer` wiring.
- `SearchCoordinator` include flag.
- Provider filter, labels, colors, and onboarding.

Exit criteria:
- Grok sessions appear only when enabled.
- Search returns Grok transcript hits.
- Existing provider tests remain green.

### Milestone 3: Preferences And Resume

Deliverables:
- Preferences controls for binary/root override.
- CLI probe.
- Resume/copy command builder if verified.

Exit criteria:
- Probe handles missing binary and custom path cleanly.
- Resume command tests cover cwd quoting and fallback behavior.
- No API keys are stored.

### Milestone 4: Records, Monitoring, And PR

Deliverables:
- Support matrix, ledger, JSON tracking, changelog, monthly summary.
- Optional `agent_watch` config and prebump driver.
- PR body with verified evidence and unsupported surfaces.

Exit criteria:
- `git diff --check` passes.
- Focused tests pass.
- `./scripts/xcode_test_stable.sh` passes if Swift touched.
- Debug build passes.
- Review loop has no unresolved actionable findings.

## Test Matrix

Focused tests to add:
- `GrokSessionParserTests`
- `GrokSessionDiscoveryTests`
- `GrokCLIEnvironmentTests`
- `GrokResumeCommandBuilderTests`, if resume accepted
- `NewProviderDiscoverabilityTests` updates
- Search/indexer integration tests matching the current provider harness

Validation commands after implementation:
```bash
git diff --check
xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/AgentSessionsGrokFocusedTests -only-testing:AgentSessionsTests/GrokSessionParserTests -only-testing:AgentSessionsTests/GrokSessionDiscoveryTests -only-testing:AgentSessionsTests/GrokCLIEnvironmentTests -only-testing:AgentSessionsTests/NewProviderDiscoverabilityTests
./scripts/xcode_test_stable.sh
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

## PR Positioning

Working PR title:
```text
feat: add tier-2 Grok Build session support
```

Verified wording template:
```text
Adds tier-2 Grok Build support for local session discovery, transcript browsing, search, provider filters, Preferences configuration, and verified resume command construction.
```

Unsupported wording to include:
```text
Agent Cockpit/live status, usage/credit tracking, analytics parity, and subagent hierarchy are not included in this PR.
```

Do not use:
- "full support"
- "all Grok sessions"
- "live Grok monitoring"
- "Grok usage tracking"
- "subagent hierarchy support"
- "cloud history import"

## Open Questions

1. Does Grok persist every TUI/headless session locally, or only enough state for `/resume`?
2. Where are sessions stored: `~/.grok`, project `.grok`, a SQLite database, JSONL files, or another app data root?
3. Are `--session-id`, `--resume`, `/session-info`, and ACP `sessionId` the same stable identifier?
4. Does `streaming-json` contain the same event families as persisted files?
5. Are tool calls/results persisted with command output, redacted summaries, or separate artifacts?
6. Does `/usage` write local usage data, and is it safe/non-sensitive?
7. Do subagents produce child session records that can be linked to a parent session?
8. Can validation run on an xAI API key without a SuperGrok Heavy web subscription?
9. Can a disposable `GROK_BIN_DIR` install avoid modifying `~/.zshrc`, or does the installer always modify shell config?
10. Is there a supported environment variable for state/session root override, or only `~/.grok/config.toml`?

## Recommendation

Proceed with an evidence-capture branch before implementation. The docs show Grok Build is a real, official xAI coding agent with install, headless, resume, ACP, skills, plugins, hooks, and subagent surfaces. The blocker is not product legitimacy; it is the missing local transcript contract. The next session should install/auth only with explicit approval, generate disposable Grok sessions, locate the durable local format, and then decide whether tier-2 support is maintainable.
