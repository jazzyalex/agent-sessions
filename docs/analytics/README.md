# Analytics Data Discovery

This directory contains the results of comprehensive data discovery for the Analytics feature.

## Overview

Before implementing Analytics, we conducted a thorough audit of session data from all three CLI agents (Codex, Claude Code, Gemini) to determine what metrics are possible with current data.

## Contents

### Discovery Scripts (`/tools/analytics/`)

**`discover_fields.py`**
- Scans session files from all CLIs
- Catalogs every field found, its type, frequency, and example values
- Outputs: `field-catalog.yaml`

**`prototype_metrics.py`**
- Tests sample metric calculations on real session data
- Demonstrates what's possible for each analytics scope
- Outputs: `prototype-metrics.json`

### Documentation

**`field-catalog.yaml`**
- Complete inventory of fields discovered in sessions
- Shows which fields are always present vs optional
- Provides example values for each field
- Summary:
  - **Codex**: 20 sessions scanned, 73 unique fields
  - **Claude Code**: 20 sessions scanned, 16 unique fields
  - **Gemini**: 3 sessions scanned, 21 unique fields

**`metrics-matrix.md`**
- Maps discovered fields to your 4 analytics scopes:
  1. Total Analytics (agent-specific or all agents)
  2. By-Project Analytics (cross-agent, per project)
  3. Inter-Agent Comparison (performance metrics)
  4. Human Developer Performance (your effectiveness)
- Shows which metrics are:
  - ✅ Available (ready to use)
  - ⚠️ Partial (needs cleanup/normalization)
  - ❌ Missing (requires new tracking)
  - 🔧 Derived (can be calculated)

**`gap-report.md`**
- Detailed analysis of data gaps
- Priority recommendations for filling gaps
- Implementation timeline and effort estimates
- Known data quality issues

**`prototype-metrics.json`**
- Sample output from metrics calculator
- Demonstrates what analytics look like with real data
- Proof-of-concept for each scope

## Key Findings

### What's Available Now (60-70% of desired metrics)

✅ **Session Metadata**: Counts, timestamps, durations
✅ **Message Counts**: Total, by role, per session
✅ **Token Metrics**: Detailed tracking (Codex), partial (Claude/Gemini)
✅ **Tool Usage**: Call counts, types, execution times (Codex)
✅ **Project Identification**: Via cwd paths (needs normalization)
✅ **Productivity Patterns**: Time-of-day, day-of-week analysis

### Key Gaps

❌ **Cost Estimation**: No pricing data (need token price table)
⚠️ **Token Parity**: Codex excellent, Claude partial, Gemini unknown
❌ **Success Indicators**: No explicit "success" flag (need heuristics)
⚠️ **Git Metadata**: Only Codex tracks (can enrich retroactively)
❌ **Rework Detection**: No file edit history across sessions

### Recommendations

**Phase 1 (Week 1)**: Foundation metrics
- Session counts, time metrics, message counts
- Immediate value, low effort

**Phase 2 (Weeks 2-3)**: Enhancements
- Token efficiency, tool patterns
- Success heuristics, response time calculation
- Cost estimation

**Phase 3 (Month 2+)**: Advanced metrics
- Learning curves, trends over time
- File operation tracking (lightweight)
- Quality indicators

## Usage

### Running Discovery Scripts

```bash
# Discover all fields from sessions
python3 tools/analytics/discover_fields.py

# Calculate sample metrics
python3 tools/analytics/prototype_metrics.py
```

### Output Locations

- **Field Catalog**: `docs/analytics/field-catalog.yaml`
- **Prototype Metrics**: `docs/analytics/prototype-metrics.json`

## Next Steps

1. **Review** metrics-matrix.md and gap-report.md
2. **Prioritize** which metrics to implement first
3. **Design** Analytics UI based on available data
4. **Build** Phase 1 metrics into Agent Sessions
5. **Iterate** based on user feedback

## Related Documentation

- `docs/session-storage-format.md` - Session file format reference
- `AgentSessions/Model/Session.swift` - Current session data model
- `AgentSessions/Services/*Parser.swift` - Session parsers

## Questions?

For questions about analytics data or implementation, see:
- **Feasibility**: Check `metrics-matrix.md`
- **Data Gaps**: Check `gap-report.md`
- **Field Details**: Check `field-catalog.yaml`
- **Sample Output**: Check `prototype-metrics.json`
