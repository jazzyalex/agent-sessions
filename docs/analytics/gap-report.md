# Analytics Data Gap Analysis & Recommendations

Generated: 2025-10-16
Based on: 20 Codex, 20 Claude Code, 3 Gemini sessions

## Executive Summary

**Good News**: Current session data supports **60-70% of desired analytics** across all 4 scopes with minimal preprocessing. Key metrics like session counts, time tracking, message counts, and basic token usage (Codex) are readily available.

**Key Gaps**: Cost estimation, cross-agent token parity, explicit success indicators, and file-level rework detection require either new tracking or significant data enrichment.

**Recommendation**: Proceed with Phase 1 implementation (foundation metrics) immediately while planning targeted enhancements for Phase 2+.

---

## Gap Categories

### 🟢 Available Now (No Work Needed)
Fields exist consistently across sessions, ready for immediate use.

### 🟡 Needs Enrichment (Data Cleanup/Normalization)
Data exists but requires preprocessing: path normalization, timestamp parsing, field name unification.

### 🟠 Partial Availability (Agent-Specific)
Data exists for some CLIs but not others. Cross-agent metrics limited.

### 🔴 Missing (Requires New Tracking)
No data available. Needs CLI changes or external data sources.

---

## Detailed Gap Analysis by Scope

## Scope 1: Total Analytics

| Metric Category | Status | Gap | Recommendation |
|-----------------|--------|-----|----------------|
| **Session Counts** | 🟢 | None | Immediate implementation |
| **Time Metrics** | 🟢 | None | Timestamp extraction working |
| **Message Counts** | 🟢 | None | Event counting reliable |
| **Token Metrics** | 🟠 | Claude/Gemini missing detailed tracking | **Priority**: Parse Claude `history.jsonl` and `usage-cache.json` for token data |
| **Tool Usage** | 🟢 | Exit codes only in Codex | Tool call counts work, success rate Codex-only |
| **Rate Limits** | 🟠 | Only Codex tracks rate_limits | Document Codex-exclusive metric |
| **Cost Estimation** | 🔴 | No pricing data | **Action**: Create token pricing table by model/date |

### Scope 1 Gaps Detail

#### Token Metrics (🟠 Partial)
**Problem**:
- Codex: Full token breakdown (input, cached, output, reasoning)
- Claude: Likely in `usage-cache.json` but not parsed yet
- Gemini: Unknown, needs investigation

**Impact**: Can't show total tokens across all agents

**Fix**:
1. Parse `~/.claude/usage-cache.json` structure
2. Check if Gemini logs usage anywhere
3. Create unified token extraction layer

**Effort**: Medium (2-4 hours)

#### Cost Estimation (🔴 Missing)
**Problem**: No cost-per-token data stored

**Impact**: Can't answer "How much did I spend this month?"

**Fix**:
1. Create pricing table:
   ```json
   {
     "gpt-5-codex": {"input": 0.01, "output": 0.03, "effective_date": "2025-01-01"},
     "claude-sonnet-4-5": {"input": 0.003, "output": 0.015, "effective_date": "2025-01-01"}
   }
   ```
2. Map model names to pricing
3. Calculate retroactively from token_count events

**Effort**: Medium (requires maintaining pricing table)

---

## Scope 2: By-Project Analytics

| Metric Category | Status | Gap | Recommendation |
|-----------------|--------|-----|----------------|
| **Project Identification** | 🟡 | Path normalization needed | **Priority**: Normalize cwd to git repo root |
| **Git Metadata** | 🟠 | Only Codex tracks git info | Extend Claude/Gemini session metadata |
| **Per-Project Metrics** | 🟢 | None (after path normalization) | Immediate once normalization done |
| **Language/Framework** | 🟡 | Needs derivation from file ops | Parse tool calls for file extensions |

### Scope 2 Gaps Detail

#### Path Normalization (🟡 Needs Enrichment)
**Problem**:
- Codex: `/Users/alexm/Repository/Codex-History`
- Claude: May include subdirs, symlinks
- Gemini: Hashed paths (`205016864bd110904...`)

**Impact**: Same project counted multiple times

**Fix**:
1. Detect git repo root for each `cwd`
2. Store mapping: `hash → resolved path` (for Gemini)
3. Normalize all sessions to repo root
4. Group sessions by normalized path

**Effort**: Medium (already partially implemented in GeminiHashResolver)

#### Git Metadata (🟠 Partial)
**Problem**:
- Codex: Has `git.repository_url`, `git.branch`, `git.commit_hash`
- Claude: Has `cwd` but no git fields
- Gemini: Has `projectHash` but no git fields

**Impact**: Can't track branch-specific work for Claude/Gemini

**Fix** (Options):
1. **Retroactive**: Query git repo from file system (if repo still exists)
2. **Prospective**: Update Claude/Gemini CLIs to capture git metadata
3. **Hybrid**: Retroactive for existing, prospective for new

**Effort**:
- Retroactive: Low (use existing git queries in Session.swift)
- Prospective: High (requires CLI changes, out of scope for this phase)

**Recommendation**: Retroactive for now, file feature request for CLI updates

---

## Scope 3: Inter-Agent Comparison

| Metric Category | Status | Gap | Recommendation |
|-----------------|--------|-----|----------------|
| **Session Characteristics** | 🟢 | None | Immediate |
| **Response Performance** | 🟡 | Needs timestamp pairing | Parse message sequences |
| **Token Efficiency** | 🟠 | Agent-specific availability | Codex complete, Claude partial, Gemini unknown |
| **Tool Usage** | 🟢 | None | Immediate |
| **Quality Indicators** | 🔴 | No "success" definition | **Critical**: Define success heuristics |

### Scope 3 Gaps Detail

#### Response Time Calculation (🟡 Needs Enrichment)
**Problem**: Need to pair user message → assistant response and calculate delta

**Impact**: Can't measure which agent is "faster"

**Fix**:
1. Parse event sequences
2. Find pairs: `{type: user, timestamp: T1}` → `{type: assistant, timestamp: T2}`
3. Calculate `response_time = T2 - T1`
4. Average per session, per agent

**Effort**: Low-Medium (straightforward parsing)

#### Success Indicators (🔴 Missing)
**Problem**: No explicit "this session succeeded" flag

**Impact**: Can't measure quality, only quantity

**Fix** (Define heuristics):
1. **Completion**: Session has end_time and duration > threshold
2. **No errors**: No error events in session
3. **Tool success**: All tools exit with code 0
4. **User satisfaction proxy**: Session duration reasonable, no repeated rework

**Effort**: Low (heuristics), High (true success tracking would need user feedback)

**Recommendation**: Start with heuristics, iterate based on user feedback

---

## Scope 4: Human Developer Performance

| Metric Category | Status | Gap | Recommendation |
|-----------------|--------|-----|----------------|
| **Prompting Patterns** | 🟢 | None | Character counts work |
| **Decision Speed** | 🟡 | Needs message pairing | Same as response time |
| **Session Outcomes** | 🟡 | Needs "completion" definition | Use heuristics |
| **Productivity Patterns** | 🟢 | None | Hour/day extraction works |
| **Learning Curve** | 🟡 | Needs time-series aggregation | Compute trends over weeks/months |
| **Rework Detection** | 🔴 | No file tracking | **Major gap**: would need file edit history |

### Scope 4 Gaps Detail

#### Learning Curve (🟡 Needs Enrichment)
**Problem**: Showing improvement over time requires aggregating metrics by week/month

**Impact**: Can't answer "Am I getting better at prompting?"

**Fix**:
1. Group sessions by time bucket (week, month)
2. Calculate metrics per bucket (avg prompt length, completion rate, tokens per session)
3. Show trend lines

**Effort**: Low (data exists, just needs aggregation)

#### Rework Detection (🔴 Missing)
**Problem**: No file-level edit tracking across sessions

**Impact**: Can't detect "edited same file 3x this week" (thrashing indicator)

**Fix** (Options):
1. **Lightweight**: Parse tool_call arguments for file paths, track most-edited files
   - Pros: Works with existing data
   - Cons: Inaccurate (doesn't distinguish create vs edit, may miss multimodal content)

2. **Comprehensive**: Extend session format to include file_edit_history
   - Pros: Accurate, enables detailed rework metrics
   - Cons: Requires CLI changes, no retroactive data

**Effort**:
- Lightweight: Medium (complex parsing)
- Comprehensive: High (out of scope)

**Recommendation**: Lightweight version for Phase 3, revisit comprehensive if high demand

---

## Priority Gap Fixes

### High Priority (Phase 1 Blockers)

1. **Path Normalization** (🟡)
   - **Why**: Needed for accurate by-project metrics
   - **Effort**: Medium
   - **Action**: Extend existing git detection logic, build cwd → repo_root mapping

2. **Claude Token Parsing** (🟠)
   - **Why**: Enables cross-agent token comparison
   - **Effort**: Medium
   - **Action**: Parse `~/.claude/usage-cache.json`, map to sessions

### Medium Priority (Phase 2 Enhancements)

3. **Success Heuristics** (🔴)
   - **Why**: Unlocks quality metrics
   - **Effort**: Low-Medium
   - **Action**: Define 3-5 simple heuristics, implement scoring

4. **Response Time Calculation** (🟡)
   - **Why**: Key for inter-agent comparison
   - **Effort**: Low-Medium
   - **Action**: Parse message pairs, calculate deltas

5. **Cost Estimation** (🔴)
   - **Why**: User-requested metric
   - **Effort**: Medium
   - **Action**: Create pricing table, calculate from tokens

### Low Priority (Phase 3+)

6. **Git Metadata Retroactive** (🟠)
   - **Why**: Nice-to-have for branch tracking
   - **Effort**: Low (query file system)
   - **Action**: For sessions with valid cwd, run git commands to get branch/remote

7. **File Edit Tracking (Lightweight)** (🔴)
   - **Why**: Rework detection
   - **Effort**: Medium
   - **Action**: Parse tool_call arguments for file operations

---

## Recommended Action Plan

### Immediate (This Week)
1. ✅ **Complete data discovery** (Done!)
2. **Implement path normalization** for by-project metrics
3. **Parse Claude usage-cache.json** for token data
4. **Build Phase 1 metrics** (see metrics-matrix.md)

### Short-Term (Next 2 Weeks)
5. **Define success heuristics** and implement scoring
6. **Add response time calculation** to inter-agent metrics
7. **Create token pricing table** and cost estimator
8. **Build Phase 2 metrics** (token efficiency, tool patterns)

### Medium-Term (Month 2)
9. **Implement learning curve** time-series analysis
10. **Add git metadata** retroactive enrichment
11. **Prototype file edit tracking** (lightweight version)
12. **Build Phase 3 metrics** (trends, quality indicators)

### Future Considerations
- **CLI Integration**: Request git/token/success tracking from CLI teams
- **User Feedback**: Add explicit session rating (1-5 stars) for true quality metric
- **File History**: If rework detection proves valuable, consider schema extension

---

## Data Quality Notes

### Known Issues

1. **Small Sessions**
   - Many Claude sessions are tiny (125-1000 bytes)
   - May be test invocations or errors
   - **Impact**: Skew averages
   - **Fix**: Filter sessions < 1KB or < 2 messages

2. **Missing End Times**
   - Some sessions have start but no end timestamp
   - **Interpretation**: Crashed? Still running? Abandoned?
   - **Fix**: Treat as "abandoned" if last_event > 24h ago

3. **Model Name Inconsistency**
   - Codex: Sometimes present, sometimes inferred
   - Claude: Rarely explicit
   - Gemini: Not always populated
   - **Fix**: Inference rules based on CLI version + date

4. **Gemini Sample Size**
   - Only 3 sessions scanned
   - **Impact**: Gemini metrics may not be representative
   - **Fix**: Scan more Gemini sessions if available

---

## Conclusion

**Current State**: Strong foundation for analytics. 60-70% of desired metrics are immediately available.

**Key Strengths**:
- Session metadata comprehensive (timestamps, counts)
- Codex token tracking excellent
- Tool usage well-documented
- Project identification possible (with normalization)

**Key Weaknesses**:
- Token parity across agents incomplete
- Success indicators undefined
- Cost tracking absent
- File-level rework detection not feasible with current data

**Next Steps**:
1. Review this report with user
2. Prioritize gap fixes based on user needs
3. Implement Phase 1 metrics while working on high-priority gaps
4. Iterate based on real-world usage

**Timeline Estimate**:
- Phase 1 (Foundation): 1 week (with path normalization)
- Phase 2 (Enhancements): 2 weeks (with success heuristics, response time, cost)
- Phase 3 (Advanced): Ongoing (trends, learning curves, file tracking)
