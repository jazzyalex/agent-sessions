# Analytics Window Layout Specification

## Window Dimensions
- Default size: **1100 × 900pt**
- Minimum size: **1100 × 900pt**

## Layout Hierarchy

```
┌─────────────────────────────────────────────────────────────┐
│ HEADER (fixed ~60pt)                                        │
│ ├─ Date Range Picker (180pt width)                          │
│ ├─ Agent Filter (140pt width)                               │
│ ├─ Project Filter (200pt width)                             │
│ └─ Refresh Button                                           │
├─────────────────────────────────────────────────────────────┤
│ SCROLLVIEW CONTENT (~840pt available)                       │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Window Padding Top: 16pt                             │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ STATS CARDS ROW (~128pt total)                       │   │
│  │ ┌──────┬──────┬──────┬──────┐                        │   │
│  │ │ Sess │ Msgs │ Avg  │Total │ (4 cards)              │   │
│  │ │  52  │ 342  │ 21m  │ 8.3h │                        │   │
│  │ └──────┴──────┴──────┴──────┘                        │   │
│  │ - Card padding: 14pt (top/bottom)                    │   │
│  │ - Min height: 100pt                                  │   │
│  │ - Spacing between cards: 10pt                        │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Stats-to-Chart Spacing: 13pt                         │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ SESSIONS CHART (260pt total)                         │   │
│  │ ┌────────────────────────────────────────────────┐   │   │
│  │ │ "Sessions Over Time"                           │   │   │
│  │ │ [Stacked bar chart by agent]                   │   │   │
│  │ │ - Card padding: 16pt (top/bottom)              │   │   │
│  │ │ - Chart area: ~228pt                           │   │   │
│  │ └────────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Chart-to-Insights Spacing: 20pt                      │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ SECONDARY INSIGHTS ROW (340pt total)                 │   │
│  │ ┌─────────────────┬─────────────────┐                │   │
│  │ │ BY AGENT        │ TIME OF DAY     │                │   │
│  │ │ (50% width)     │ (50% width)     │                │   │
│  │ │                 │                 │                │   │
│  │ │ Codex    ████   │  M ░░▓▓▓░░░     │                │   │
│  │ │ Claude   ███    │  T ░▓▓▓▓▓░░     │                │   │
│  │ │ Gemini   ██     │  W ░░▓▓▓░░░     │                │   │
│  │ │ OpenCode █      │  T ░░░▓░░░░     │                │   │
│  │ │                 │  F ░▓▓▓▓░░░     │                │   │
│  │ │ [Currently      │  S ░░░░░░░░     │                │   │
│  │ │  overflowing]   │  S ░░░░░░░░     │                │   │
│  │ │                 │                 │                │   │
│  │ └─────────────────┴─────────────────┘                │   │
│  │ - Frame height: 340pt (both cards)                   │   │
│  │ - Card padding: 16pt (top/bottom = 32pt total)       │   │
│  │ - Available content space: 308pt                     │   │
│  │ - Horizontal spacing: 13pt                           │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Window Padding Bottom: 16pt                          │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Current Problem: By Agent Card Overflow

### Time of Day Card (WORKING CORRECTLY)
**Total frame:** 340pt
**Card padding:** 32pt (16pt top + 16pt bottom)
**Available content:** 308pt

Content breakdown:
- Header: ~58pt
- Spacing: 16pt
- Heatmap grid: **expands to fill** (~234pt)
  - Uses `.frame(maxHeight: .infinity)` to adapt
  - 7 rows × 8 columns grid
  - Labels and footer fit naturally

### By Agent Card (OVERFLOWING)
**Total frame:** 340pt
**Card padding:** 32pt (16pt top + 16pt bottom)
**Available content:** 308pt

Current content breakdown:
- Header with picker: ~58pt
- VStack spacing: 16pt
- 4 Agent rows:
  - Each row padding: `.vertical(16)` = 32pt total
  - Each row content: ~40pt (name, details, progress bar, percentage)
  - Dividers between rows: ~1pt each × 3 = 3pt
  - **Subtotal:** (32pt + 40pt) × 4 + 3pt = **291pt**
- Spacer() at bottom: **consumes remaining space, pushes content**
- **TOTAL:** 58 + 16 + 291 + extra = **~365pt+ > 308pt available**

### Root Causes
1. **Excessive vertical padding:** 16pt per side (32pt total) per agent row
2. **Bottom Spacer():** Pushes content upward, causing overflow
3. **Fixed content heights:** Doesn't adapt like Time of Day heatmap

## Design Tokens (from AnalyticsDesignTokens.swift)

### Spacing
- `windowPadding`: 16pt (edge padding)
- `statsToChartSpacing`: 13pt (compact, related content)
- `chartToInsightsSpacing`: 20pt (major section break)
- `insightsGridSpacing`: 13pt (horizontal spacing between bottom cards)
- `metricsCardSpacing`: 10pt (between stats cards)
- `statsCardPadding`: 14pt (internal padding for stats cards)
- `cardPadding`: 16pt (internal padding for large cards)

### Heights
- `headerHeight`: 60pt
- `statsCardHeight`: 100pt
- `primaryChartHeight`: 260pt
- `secondaryCardHeight`: 340pt ⭐

### Corner Radius
- `cardCornerRadius`: 8pt
- `chartBarCornerRadius`: 4pt
- `heatmapCellCornerRadius`: 4pt

## Solution Applied ✓

To fit 4 agents in 308pt available content space:

**Target breakdown:**
- Header: 58pt
- Spacing: 12pt (reduced from 16pt)
- **Remaining for agents:** 238pt
- **Per agent:** ~59.5pt

**Implemented per-agent structure:**
- Content height: ~38-40pt (fixed)
- Vertical padding: **9pt top + 9pt bottom** = 18pt total
- **Total per agent:** ~56-58pt ✓

**Changes applied (AgentBreakdownView.swift:52-101):**
1. ✓ Reduced VStack spacing from `16pt` → `12pt`
2. ✓ Reduced agent row `.padding(.vertical, 16)` → `.padding(.vertical, 9)`
3. ✓ Removed `Spacer()` at bottom, replaced with `.frame(maxHeight: .infinity, alignment: .top)`

**Result:**
- By Agent card now fits exactly within 340pt frame
- Visual density matches Time of Day card
- 4 agents display comfortably without overflow
- Top-aligned content prevents pushing/overflow issues
