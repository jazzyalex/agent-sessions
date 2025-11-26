# Analytics Feature

## Overview

The Analytics feature provides insights into AI agent usage patterns across Codex, Claude Code, Gemini, and OpenCode sessions.

## Architecture

### Directory Structure

```
AgentSessions/Analytics/
├── Models/                          # Data models
│   ├── AnalyticsData.swift         # Core data structures
│   └── AnalyticsDateRange.swift    # Filter enums
├── Services/
│   └── AnalyticsService.swift      # Metric calculation engine
├── Views/
│   ├── AnalyticsView.swift         # Main container
│   ├── AnalyticsWindowController.swift  # Window management
│   ├── StatsCardsView.swift        # Summary stats cards
│   ├── SessionsChartView.swift     # Primary time-series chart
│   ├── AgentBreakdownView.swift    # Agent progress bars
│   └── TimeOfDayHeatmapView.swift  # Activity heatmap
└── Utilities/
    ├── AnalyticsColors.swift       # Agent brand colors
    └── AnalyticsDesignTokens.swift # Design constants
```

### Key Components

**AnalyticsService**
- Calculates metrics from session data
- Supports filtering by date range and agent
- Computes:
  - Summary stats (sessions, messages, commands, time)
  - Time series data for charts
  - Agent breakdown percentages
  - Time-of-day activity heatmap
  - Percentage changes vs previous period

**AnalyticsView**
- Main analytics UI container
- Header with filters (date range, agent)
- Stats cards row
- Primary chart (stacked bars)
- Secondary insights (2-column grid)
- Auto-refresh support

**AnalyticsWindowController**
- Manages secondary analytics window
- Window state persistence (size, position)
- Keyboard shortcut support (⌘K)

## Agent Brand Colors

Uses consistent brand colors from main app:
- **Codex**: `Color.blue` (system blue)
- **Claude**: `Color(red: 204/255, green: 121/255, blue: 90/255)` (terracotta)
- **Gemini**: `Color.teal` (system teal)
- **OpenCode**: `Color.purple`

Color utilities in `AnalyticsColors.swift` provide:
```swift
Color.agentColor(for: SessionSource) -> Color
Color.agentColor(for: String) -> Color
```

## Usage

### Opening Analytics

**Via Toolbar:**
- Click Analytics button in main window toolbar

**Via Keyboard:**
- Press `⌘K` to toggle analytics window

### Filters

**Date Range:**
- Last 7 Days (daily bars)
- Last 30 Days (daily bars)
- Last 90 Days (weekly aggregation)
- All Time (monthly aggregation)

**Agent Filter:**
- All Agents
- Codex Only
- Claude Only
- Gemini Only

### Metrics Displayed

**Stats Cards:**
1. Sessions - Total session count
2. Messages - Total message exchanges
3. Commands - Tool/command executions
4. Active Time - Total session duration

Each card shows:
- Current value
- Change vs previous period (+12% ↗)

**Primary Chart:**
- Stacked bar chart
- Sessions over time by agent
- Color-coded by agent
- Interactive tooltips

**Agent Breakdown:**
- Progress bars showing agent usage percentage
- Session counts and durations per agent
- Sorted by usage descending

**Time of Day Heatmap:**
- 8×7 grid (3-hour buckets × days of week)
- Color intensity shows activity level
- "Most Active" time range insight

## Implementation Notes

### Data Source

Analytics pulls data from:
- `SessionIndexer` (Codex sessions)
- `ClaudeSessionIndexer` (Claude Code sessions)
- `GeminiSessionIndexer` (Gemini sessions)

All calculations use existing session data structures - no schema changes required.

### Performance

- Metrics calculated on-demand when filters change
- Lightweight session metadata used when possible
- Chart animations use SwiftUI's built-in optimizations
- Auto-refresh every 5 minutes (when window visible)

### Accessibility

- Full VoiceOver support for all components
- Keyboard navigation (Tab, Space, Arrow keys)
- Reduced motion support
- High contrast mode compatible

## Design Reference

Complete design specifications: `docs/analytics/analytics-design-guide.md`

## Future Enhancements

**Phase 2 (Projects Tab):**
- Analytics per project/repo
- Most active projects
- Language/framework breakdown
- Time invested per project

**Phase 3 (Agents Tab):**
- Detailed agent comparison
- Response time analysis
- Token efficiency metrics
- Success rate indicators

**Phase 4 (Advanced Metrics):**
- Cost estimation (requires token pricing)
- Learning curves over time
- Rework detection
- Quality indicators

## Related Documentation

- Design Guide: `docs/analytics/analytics-design-guide.md`
- Data Discovery: `docs/analytics/field-catalog.yaml`
- Metrics Matrix: `docs/analytics/metrics-matrix.md`
- Gap Report: `docs/analytics/gap-report.md`
