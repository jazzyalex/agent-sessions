# Analytics Metrics Feasibility Matrix

Generated: 2025-10-16

This document maps discovered session data fields to your 4 analytics scopes and identifies which metrics are possible with current data.

## Summary

Based on analysis of:
- **Codex**: 20 sessions, 73 unique fields
- **Claude Code**: 20 sessions, 16 unique fields
- **Gemini**: 3 sessions, 21 unique fields

## Key Findings

### Data Availability Legend
- ✅ **Available**: Data exists and is consistent across sessions
- ⚠️ **Partial**: Data exists but incomplete, inconsistent, or CLI-specific
- ❌ **Missing**: No data available, requires new tracking
- 🔧 **Derived**: Can be calculated from existing data

---

## Scope 1: Total Analytics

**Goal**: Aggregate metrics for specific agent or all agents, by date range or all-time

| Metric | Status | Data Source | Notes |
|--------|--------|-------------|-------|
| **Session Counts** |
| Total sessions | ✅ | File count | Count session files |
| Sessions by date range | ✅ | `timestamp`, `payload.timestamp` | Filter by timestamp |
| Sessions by agent | ✅ | File location + format | Codex/Claude/Gemini identifiable by path/format |
| Sessions by model | ⚠️ | `payload.model`, `model` | Present in some sessions, missing in others |
| **Time Metrics** |
| Total active time | ✅ | `timestamp` (first→last in session) | Calculate duration from session events |
| Average session duration | ✅ | Derived from timestamps | Mean of all session durations |
| Time range (first→last session) | ✅ | `timestamp` | Min/max across all sessions |
| Peak activity hours/days | ✅ | `timestamp` | Extract hour/day from timestamps |
| **Message Metrics** |
| Total messages | ✅ | Event count | Count events with `type: message` |
| Total user messages | ✅ | `payload.role: user` | Filter by role |
| Total assistant messages | ✅ | `payload.role: assistant` | Filter by role |
| Average messages per session | 🔧 | Derived | Total messages / sessions |
| Total transcript lines | ✅ | Event count with text | Count non-empty text fields |
| **Token Metrics** (Codex primarily) |
| Total tokens (input/output) | ✅ | `payload.info.last_token_usage` | Sum from `token_count` events |
| Total cached tokens | ✅ | `payload.info.last_token_usage.cached_input_tokens` | Codex only |
| Total reasoning tokens | ✅ | `payload.info.last_token_usage.reasoning_output_tokens` | Codex only |
| Average tokens per session | 🔧 | Derived | Total tokens / sessions |
| Context window usage | ⚠️ | `payload.info.model_context_window` | Available in some Codex sessions |
| **Tool Usage** |
| Total tool calls | ✅ | `type: function_call` events | Count tool execution events |
| Tool calls by type | ✅ | `payload.name` in function_call | Bash, file ops, etc. |
| Tool execution time | ⚠️ | `payload.metadata.duration_seconds` | Available in Codex |
| Tool success/failure rate | ⚠️ | `payload.metadata.exit_code` | Exit codes available in Codex |
| **Rate Limits** (Codex primarily) |
| Rate limit events | ✅ | `payload.type: token_count` → `rate_limits` | Track `used_percent` |
| Times hit 5h limit | 🔧 | `payload.rate_limits.primary.used_percent` | When >= 100% |
| Times hit weekly limit | 🔧 | `payload.rate_limits.secondary.used_percent` | When >= 100% |
| **Cost Metrics** |
| Estimated cost | ❌ | Not tracked | Would need token prices by model |

### Scope 1 Recommendation
**Immediate**: Session counts, time metrics, message counts, token totals (Codex)
**Needs Work**: Cost estimation (add pricing table), model consistency

---

## Scope 2: By-Project Analytics

**Goal**: All metrics specific to a project, cross-agent

| Metric | Status | Data Source | Notes |
|--------|--------|-------------|-------|
| **Project Identification** |
| Project name/path | ✅ | `payload.cwd` (Codex), `cwd`/`project` (Claude), `projectHash` (Gemini) | Normalize paths to repo root |
| Git repository | ⚠️ | `payload.git.repository_url` (Codex) | Only in Codex session_meta |
| Git branch | ⚠️ | `payload.git.branch` (Codex) | Only in Codex session_meta |
| Git commit | ⚠️ | `payload.git.commit_hash` (Codex) | Only in Codex session_meta |
| **Per-Project Metrics** |
| Sessions per project | ✅ | Group by `cwd` | Requires path normalization |
| Time spent per project | ✅ | Sum session durations by project | |
| Tokens used per project | ✅ | Sum tokens by project | Codex only |
| Agents used per project | ✅ | Count unique agents by project | Shows which agents work on which projects |
| Messages per project | ✅ | Sum message counts by project | |
| Tool calls per project | ✅ | Sum tool calls by project | |
| **Project Characteristics** |
| Language/framework | 🔧 | Derive from tool calls (file extensions) | Analyze file operations |
| Most edited files | 🔧 | Parse tool call arguments for file paths | Requires deep parsing |
| Test runs per project | 🔧 | Detect test commands in tool calls | Pattern matching needed |
| Build frequency | 🔧 | Detect build commands in tool calls | Pattern matching needed |

### Scope 2 Recommendation
**Immediate**: Session/time/token counts per project (with path normalization)
**Enhancement**: Git metadata unification (extend Claude/Gemini), file operation analysis

---

## Scope 3: Inter-Agent Comparison

**Goal**: Compare agent performance metrics

| Metric | Status | Data Source | Notes |
|--------|--------|-------------|-------|
| **Session Characteristics** |
| Sessions per agent | ✅ | File count by agent | |
| Avg session duration by agent | ✅ | Mean duration per agent | |
| Avg messages per session | ✅ | Messages / sessions per agent | |
| **Response Performance** |
| Response time | 🔧 | Assistant timestamp - User timestamp | Calculate from message pairs |
| First response time | 🔧 | First assistant msg - first user msg | Latency indicator |
| **Token Efficiency** |
| Tokens per session | ✅ | Mean tokens by agent | Codex vs Claude |
| Output/input ratio | 🔧 | output_tokens / input_tokens | Verbosity metric |
| Cached token usage | ⚠️ | Codex only | Shows context reuse |
| Reasoning token usage | ⚠️ | Codex only | Shows thinking overhead |
| **Tool Usage Patterns** |
| Tool calls per session | ✅ | Mean tool calls by agent | |
| Preferred tools | ✅ | Most common tools per agent | bash vs file ops vs search |
| Tool execution time | ⚠️ | Codex only | Performance comparison |
| Tool success rate | ⚠️ | exit_code == 0 | Codex only |
| **Quality Indicators** |
| Error rate | 🔧 | Count error events / total events | |
| Session completion rate | 🔧 | Sessions with end_time / total | Proxy for success |
| Rework frequency | ❌ | Not tracked | Would need: same file edited multiple times |
| **Rate Limit Behavior** |
| Rate limit hit frequency | ⚠️ | Codex only | How often each agent maxes out |
| Time to rate limit | 🔧 | When used_percent → 100% | Usage intensity |

### Scope 3 Recommendation
**Immediate**: Session counts, duration, message counts, tool usage patterns
**Important**: Response time calculation (parsing message sequences)
**Future**: Success/quality indicators (needs definition of "success")

---

## Scope 4: Human Developer Performance

**Goal**: Analyze your coding/prompting effectiveness

| Metric | Status | Data Source | Notes |
|--------|--------|-------------|-------|
| **Prompting Patterns** |
| Prompt length | ✅ | Character count of user messages | Quality proxy: longer = more context? |
| Prompts per session | ✅ | Count user messages | |
| Avg words per prompt | 🔧 | Word count user messages | Specificity indicator |
| Prompt specificity score | 🔧 | Heuristics: contains code? file paths? specific commands? | Needs scoring algorithm |
| **Decision Speed** |
| Thinking time | 🔧 | Next user message - assistant response | How long to respond to agent |
| Session initiation frequency | ✅ | Sessions per day/week | Activity patterns |
| Time between sessions | 🔧 | Gap between session end → next start | |
| **Session Outcomes** |
| Completion rate | 🔧 | Sessions with end_time / total | % sessions you finish vs abandon |
| Session abandonment | 🔧 | Short sessions or no end_time | Early quits = bad prompts? |
| Long sessions | 🔧 | Duration > threshold | Complex tasks or stuck? |
| **Productivity Patterns** |
| Peak productivity hours | ✅ | Sessions by hour of day | When you code most |
| Peak productivity days | ✅ | Sessions by day of week | |
| Session duration trend | 🔧 | Duration over time | Getting faster? |
| Messages per session trend | 🔧 | Messages over time | More efficient prompting? |
| **Learning Curve** |
| Token efficiency over time | 🔧 | Tokens per session over time | Less back-and-forth? |
| Success rate over time | 🔧 | Completion rate over time | Improving? |
| Error rate over time | 🔧 | Error events over time | Fewer mistakes? |
| **Agent Selection** |
| Agent switching frequency | 🔧 | Same project, different agents | Trying to find best fit? |
| Agent preference by project | ✅ | Most-used agent per project | Which agent for which work? |
| Agent selection accuracy | ❌ | Not trackable | Would need: retrospective "was this the right choice?" |
| **Context Management** |
| Context window usage | ⚠️ | Codex only | How full your context gets |
| Cached token ratio | ⚠️ | Codex only | How well you reuse context |
| File references per session | 🔧 | Parse tool calls for files | How much code you include |
| **Rework Patterns** |
| Same-file edits | ❌ | Not tracked | Would need: track file paths across time |
| Same-project revisits | 🔧 | Multiple sessions same project | Unfinished work? |
| Tool call retries | 🔧 | Same tool, same args, repeated | Debugging indicator |

### Scope 4 Recommendation
**Immediate**: Prompt length, thinking time, productivity patterns, completion rate
**High Value**: Trends over time (requires time-series analysis)
**Future**: Rework detection (needs file tracking across sessions)

---

## Data Quality Issues

### Path Normalization
- **Issue**: `cwd` formats differ across CLIs
  - Codex: `/Users/alexm/Repository/Codex-History`
  - Claude: May include symlinks, relative paths
  - Gemini: Hashed project paths need resolver
- **Solution**: Normalize to git repo root when possible

### Timestamp Consistency
- **Issue**: Different field names across CLIs
  - Codex: `timestamp` (ISO8601 with Z)
  - Claude: `timestamp`, `time`, `created_at`
  - Gemini: `timestamp`, `ts`
- **Solution**: Unified timestamp extraction

### Token Tracking
- **Issue**: Only Codex has detailed token tracking
- **Impact**: Can't compare token efficiency across agents
- **Solution**: Parse Claude history.jsonl for usage data, extend Gemini tracking

### Model Identification
- **Issue**: Model names inconsistent or missing
  - Codex: Sometimes `gpt-5-codex`, `gpt-5-thinking`, `o3-mini`
  - Claude: Implicit (claude-sonnet-4-5?)
  - Gemini: Model field exists but not always populated
- **Solution**: Infer from CLI version + timestamp ranges

---

## Recommended Implementation Phases

### Phase 1: Foundation Metrics (Week 1)
**Scope 1**: Session counts, time metrics, message counts
**Scope 2**: Sessions/time per project
**Scope 3**: Basic comparison (session counts, durations)
**Scope 4**: Productivity patterns (hours, days, completion rate)

### Phase 2: Token & Tool Analytics (Week 2)
**Scope 1**: Token totals, tool usage
**Scope 2**: Tokens/tools per project
**Scope 3**: Token efficiency, tool preferences
**Scope 4**: Prompt length analysis

### Phase 3: Advanced Metrics (Week 3)
**Scope 3**: Response time calculation
**Scope 4**: Thinking time, trends over time
**Enhancement**: File operation tracking, language detection

### Phase 4: Quality Indicators (Week 4+)
**All Scopes**: Error tracking, success indicators
**Scope 4**: Learning curves, agent selection patterns
**Future**: Rework detection (requires schema extension)

---

## Data Gaps & Recommendations

### Critical Gaps
1. **Cost Tracking**: No pricing data → can't estimate costs
   - **Fix**: Add token price table, calculate retroactively
2. **Success Indicators**: No clear "success" vs "failure" metric
   - **Fix**: Define heuristics (session completion, error rate, user satisfaction proxy)
3. **File Tracking**: No comprehensive file edit history
   - **Fix**: Parse tool call arguments more deeply, track file paths

### Enhancement Opportunities
1. **Unified Git Metadata**: Extend Claude & Gemini to capture git info
2. **Model Consistency**: Standardize model identification
3. **Token Parity**: Parse Claude usage data, add to Gemini
4. **Session Outcomes**: Add explicit "success" flag to sessions

---

## Next Steps

1. **Review this matrix** with user to prioritize metrics
2. **Build Phase 1 metrics** into Agent Sessions UI
3. **Iterate** based on user feedback and real-world usage
4. **Extend tracking** to fill critical gaps (git, tokens, success indicators)
