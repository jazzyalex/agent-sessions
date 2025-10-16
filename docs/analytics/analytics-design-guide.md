# Agent Sessions Analytics - UI/UX Design Guide

## Overview
Analytics provides users with clear, actionable insights into their AI agent usage patterns. The design follows macOS Human Interface Guidelines while maintaining the app's developer-focused, minimal aesthetic.

---

## 1. Toolbar Integration

### Analytics Button
**Location:** Main window toolbar, right side after search  
**Appearance:** SF Symbol with text label (macOS standard)

```
┌─────────────────────────────────────────────────────────┐
│ [≡] Agent Sessions    [🔍 Search]     [📊 Analytics]    │
└─────────────────────────────────────────────────────────┘
```

**Specifications:**
- **Symbol:** `chart.bar.xaxis` (SF Symbol)
- **Label:** "Analytics"
- **Style:** `.bordered` button style (macOS 11+)
- **Keyboard Shortcut:** `⌘+K` (standard for auxiliary views)
- **Tooltip:** "View usage analytics (⌘K)"
- **State:** Toggles analytics window open/closed

**SwiftUI Code:**
```swift
Button(action: { showAnalytics.toggle() }) {
    Label("Analytics", systemImage: "chart.bar.xaxis")
}
.buttonStyle(.bordered)
.keyboardShortcut("k", modifiers: .command)
.help("View usage analytics (⌘K)")
```

---

## 2. Analytics Window Design

### Window Behavior
- **Type:** Secondary window (not modal, can coexist with main window)
- **Size:** 
  - **Default:** 900×650 pt
  - **Minimum:** 700×500 pt
  - **Resizable:** Yes, maintains aspect ratio on resize
- **Position:** Centered on screen on first open, remembers position
- **Close:** Standard window close button, or `⌘K` to toggle
- **Persistence:** Window state saved (size, position, selected tab)

### Window Chrome
```
┌─────────────────────────────────────────────────────────┐
│ ⚫⟡⬜  Analytics                                         │ ← Standard macOS title bar
├─────────────────────────────────────────────────────────┤
│ [Window Content - see layouts below]                    │
└─────────────────────────────────────────────────────────┘
```

---

## 3. Total View Layout

### Structure Hierarchy
```
Window
├── Header (Controls Bar)
├── Stats Cards Row
├── Primary Chart
└── Secondary Insights (2-column grid)
```

### Full Layout Mockup
```
┌─────────────────────────────────────────────────────────────────┐
│ ⚫⟡⬜  Analytics                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│ ┌─────────────────────────────────────────────────────────┐   │ ← Header (60pt height)
│ │ [Total] Projects Agents   │ [Last 7 Days ▼] [All ▼] 🔄 │   │
│ └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│ ┌──────────────────────────────────────────────────────────┐  │
│ │  STATS CARDS (4 cards, equal width, 100pt height)        │  │
│ │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐            │  │
│ │  │Sessions│ │Messages│ │Commands│ │  Time  │            │  │
│ │  │  87    │ │  342   │ │  198   │ │ 8h 23m │            │  │
│ │  │  +12%  │ │  +8%   │ │  -3%   │ │  +15%  │            │  │
│ │  └────────┘ └────────┘ └────────┘ └────────┘            │  │
│ └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│ ┌──────────────────────────────────────────────────────────┐  │
│ │  PRIMARY CHART (280pt height)                             │  │
│ │  Sessions Over Time                                        │  │
│ │  ┌──────────────────────────────────────────────────┐    │  │
│ │  │                        ▄█                         │    │  │
│ │  │      ▄█       ▄█      ███                         │    │  │
│ │  │     ███      ███     ████   ▄█                    │    │  │
│ │  │    ████  ▄█ █████   █████  ███                    │    │  │
│ │  │   █████ ███ █████  ██████ ████                    │    │  │
│ │  │  ██████████████████████████████                   │    │  │
│ │  └──────────────────────────────────────────────────┘    │  │
│ │              Mon Tue Wed Thu Fri Sat Sun                  │  │
│ │              ███ Codex  ███ Claude                        │  │
│ └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│ ┌──────────────────────┐  ┌──────────────────────────────┐   │
│ │ BY AGENT (180pt)     │  │ TIME OF DAY (180pt)          │   │
│ │                      │  │                              │   │
│ │ Codex    ████████ 60%│  │  [Heatmap visualization]     │   │
│ │ Claude   █████ 40%   │  │                              │   │
│ │                      │  │  Most Active: 9am-11am       │   │
│ │ 52 sessions • 5h 12m │  │                              │   │
│ │ 35 sessions • 3h 11m │  │                              │   │
│ └──────────────────────┘  └──────────────────────────────┘   │
│                                                                 │
│                                    Updated 2 minutes ago       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Component Specifications

### 4.1 Header Controls Bar

**Height:** 60pt  
**Background:** `.background` (system adaptive)  
**Bottom Border:** 1px separator line

**Layout:**
```
┌─────────────────────────────────────────────────────────┐
│ [Tab 1] [Tab 2] [Tab 3]  │  [Picker 1▼] [Picker 2▼] 🔄 │
│ ←─────────────────────────┴──────────────────────────→  │
│ Navigation Tabs            Filters & Refresh            │
└─────────────────────────────────────────────────────────┘
```

**Elements:**

1. **Navigation Tabs (Left)**
   - Style: Segmented control (`.segmented` picker style)
   - Items: "Total" | "Projects" | "Agents"
   - Selection: Accent color underline
   - Font: `.headline` weight

2. **Spacer** (flexible, pushes filters right)

3. **Date Range Picker**
   - Style: Menu picker with border
   - Options: "Last 7 Days" | "Last 30 Days" | "Last 90 Days" | "All Time" | "Custom..."
   - Width: 140pt
   - Icon: Small calendar icon in menu

4. **Agent Filter Picker**
   - Style: Menu picker with border
   - Options: "All Agents" | "Codex Only" | "Claude Only" | "Gemini Only"
   - Width: 140pt
   - Icon: Small agent icon in menu

5. **Refresh Button**
   - Style: Borderless button
   - Icon: `arrow.clockwise` SF Symbol
   - Size: 16pt icon
   - Behavior: Spins during refresh (rotation animation)
   - Tooltip: "Refresh analytics"
   - Auto-refresh: Every 5 minutes when window is visible

**SwiftUI Implementation Pattern:**
```swift
VStack(spacing: 0) {
    HStack {
        Picker("View", selection: $selectedView) {
            Text("Total").tag(View.total)
            Text("Projects").tag(View.projects)
            Text("Agents").tag(View.agents)
        }
        .pickerStyle(.segmented)
        
        Spacer()
        
        Picker("Date Range", selection: $dateRange) {
            // ... options
        }
        .pickerStyle(.menu)
        .frame(width: 140)
        
        Picker("Agent", selection: $agentFilter) {
            // ... options
        }
        .pickerStyle(.menu)
        .frame(width: 140)
        
        Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(Color(nsColor: .controlBackgroundColor))
    
    Divider()
}
```

---

### 4.2 Stats Cards

**Container:**
- Horizontal stack, equal spacing
- Padding: 20pt all sides
- Spacing: 12pt between cards

**Individual Card:**
- Size: Flexible width, 100pt height
- Background: `.quaternarySystemFill` (subtle gray)
- Corner Radius: 10pt
- Padding: 16pt
- Shadow: None (flat design)

**Card Structure:**
```
┌────────────────┐
│ 📊 Label       │ ← SF Symbol + Text (.caption style, secondary color)
│                │
│    Value       │ ← Large number (.title style, primary color)
│                │
│    +12% ↗      │ ← Change indicator (.caption2, success/error color)
└────────────────┘
```

**Four Cards:**

1. **Sessions**
   - Icon: `square.stack.3d.up` (subtle, secondary color)
   - Label: "Sessions"
   - Value: Count (e.g., "87")
   - Change: vs previous period (e.g., "+12%")

2. **Messages**
   - Icon: `bubble.left.and.bubble.right`
   - Label: "Messages"
   - Value: Count (e.g., "342")
   - Change: vs previous period

3. **Commands**
   - Icon: `terminal`
   - Label: "Commands"
   - Value: Count (e.g., "198")
   - Change: vs previous period

4. **Active Time**
   - Icon: `clock`
   - Label: "Active Time"
   - Value: Formatted duration (e.g., "8h 23m")
   - Change: vs previous period

**Change Indicator Colors:**
- Positive change: `.green` (system success color)
- Negative change: `.secondary` (neutral, not alarming)
- Arrow: `↗` for positive, `↘` for negative
- Font: `.caption2`, medium weight

**Card Interaction:**
- Hover: Slight scale up (1.02)
- Click: No action in MVP (future: show detail popover)
- Accessibility: Full VoiceOver descriptions

---

### 4.3 Primary Chart (Sessions Over Time)

**Container:**
- Height: 280pt
- Padding: 20pt horizontal, 16pt vertical
- Background: `.background` (system adaptive)
- Corner Radius: 10pt

**Chart Header:**
```
┌────────────────────────────────────────────────┐
│ Sessions Over Time            ███ Codex █ Claude │
│                               ↑ Legend (right)   │
└────────────────────────────────────────────────┘
```

**Chart Specifications:**
- Type: SwiftUI `Chart` with `BarMark` (stacked bars)
- X-Axis: Date/time based on date range
  - Last 7 Days: Daily bars
  - Last 30 Days: Daily bars (condensed)
  - Last 90 Days: Weekly aggregation
  - All Time: Monthly aggregation
- Y-Axis: Session count, auto-scaling
- Grid Lines: Horizontal only, `.quaternary` color
- Colors: 
  - Codex: `.blue` (primary accent)
  - Claude: `.orange` (secondary accent)
  - Gemini: `.green` (tertiary)
- Bar Width: Auto-calculated, 2pt spacing
- Corner Radius: 4pt on bars
- Animation: `.easeInOut` on data changes

**Empty State:**
```
┌────────────────────────────────────────────────┐
│                                                │
│            📊                                  │
│                                                │
│        No sessions yet                         │
│        Start coding to see analytics           │
│                                                │
└────────────────────────────────────────────────┘
```

**Interaction:**
- Hover: Show tooltip with exact values
- Click: No drill-down in MVP
- Zoom: Not in MVP (future enhancement)

**SwiftUI Chart Pattern:**
```swift
Chart(data) { item in
    BarMark(
        x: .value("Date", item.date),
        y: .value("Sessions", item.count),
        stacking: .standard
    )
    .foregroundStyle(by: .value("Agent", item.agent))
}
.chartForegroundStyleScale([
    "Codex": .blue,
    "Claude": .orange
])
.chartXAxis {
    AxisMarks(values: .automatic) { _ in
        AxisGridLine()
        AxisValueLabel(format: .dateTime.day().month())
    }
}
.chartYAxis {
    AxisMarks(position: .leading)
}
.frame(height: 220)
```

---

### 4.4 Secondary Insights (2-Column Grid)

**Container:**
- Two-column grid, equal width
- Spacing: 12pt between columns
- Height: 180pt per card
- Padding: 20pt horizontal

**Left Card: By Agent Breakdown**

```
┌─────────────────────────────┐
│ By Agent                    │ ← Title (.headline)
│                             │
│ Codex    ████████ 60%       │ ← Progress bar + percentage
│ 52 sessions • 5h 12m        │ ← Secondary info (.caption)
│                             │
│ Claude   █████ 40%          │
│ 35 sessions • 3h 11m        │
│                             │
└─────────────────────────────┘
```

**Specifications:**
- Background: `.quaternarySystemFill`
- Corner Radius: 10pt
- Padding: 16pt
- Progress Bars:
  - Height: 8pt
  - Corner Radius: 4pt
  - Colors: Match agent colors from chart
  - Background: `.quaternary` (unfilled portion)
- Typography:
  - Agent name: `.body`, semibold
  - Percentage: `.body`, regular, secondary color
  - Details: `.caption`, tertiary color
- Spacing: 12pt between agents

**Right Card: Time of Day Heatmap**

```
┌─────────────────────────────┐
│ Time of Day                 │ ← Title (.headline)
│                             │
│ [Heatmap Grid]              │ ← 24 hours × 7 days
│  12a 3a 6a 9a 12p 3p 6p 9p  │
│ M ▪  ▪  ◼  ◼  ▪  ◼  ▪  ▪   │
│ T ▪  ▪  ◼  ◼  ◼  ◼  ▪  ▪   │
│ W ▪  ▪  ▪  ◼  ◼  ◼  ▪  ▪   │
│ ...                         │
│                             │
│ Most Active: 9am - 11am     │ ← Insight (.caption)
└─────────────────────────────┘
```

**Heatmap Specifications:**
- Grid: 8 columns (3-hour buckets) × 7 rows (days)
- Cell Size: 16pt × 16pt
- Cell Spacing: 2pt
- Colors: Gradient from `.quaternary` to `.blue`
  - No activity: `.quaternary`
  - Low: `.blue.opacity(0.3)`
  - Medium: `.blue.opacity(0.6)`
  - High: `.blue.opacity(1.0)`
- Corner Radius: 3pt per cell
- Labels:
  - Hours: Top, abbreviated (12a, 3a, 6a...)
  - Days: Left, single letter (M, T, W...)
  - Font: `.caption2`, secondary color

---

## 5. Update Behavior

### Auto-Refresh Logic
```
Window Visible + No User Interaction for 5 min
  → Refresh data silently
  → Animate refresh icon briefly
  → Update "Updated X minutes ago" timestamp
  → Smooth data transition (no jarring changes)

Window Hidden
  → Pause auto-refresh
  → Resume on window show

Manual Refresh (click refresh button)
  → Immediate refresh
  → Show loading state (spinner on refresh button)
  → Duration: <500ms (data is local)
```

### Loading States

**Initial Load (first open):**
```
┌─────────────────────────────────────────┐
│        ⟳  Loading analytics...          │
│                                         │
│        (Spinner + text)                 │
└─────────────────────────────────────────┘
```

**Refresh (data already loaded):**
- Refresh button spins
- Existing data remains visible
- New data fades in (0.3s ease)
- No skeleton/placeholder needed (fast operation)

**No Data State:**
```
┌─────────────────────────────────────────┐
│              📊                         │
│                                         │
│       No sessions found                 │
│                                         │
│   Try adjusting your date range         │
│   or agent filter                       │
└─────────────────────────────────────────┘
```

### Timestamp Display
- Location: Bottom-right corner
- Text: "Updated X minutes ago"
- Font: `.caption2`, tertiary color
- Updates: Every minute when visible
- Format examples:
  - "Updated just now"
  - "Updated 2 minutes ago"
  - "Updated 1 hour ago"
  - "Updated today at 3:42 PM" (>6 hours)

---

## 6. Spacing & Padding System

**Global Padding:**
- Window edges: 20pt
- Section spacing: 16pt (between major sections)
- Card spacing: 12pt (between cards in grid)
- Internal padding: 16pt (inside cards)

**Vertical Rhythm:**
```
Header:           60pt
Spacer:           16pt
Stats Cards:      100pt
Spacer:           16pt
Primary Chart:    280pt
Spacer:           16pt
Secondary Grid:   180pt
Spacer:           12pt
Footer:           20pt (timestamp)
Total:            ~696pt (fits in 700pt min height)
```

---

## 7. Typography Scale

**Type System:**
- `.largeTitle`: Not used (too large for analytics)
- `.title`: Main values in stats cards (e.g., "87")
- `.title2`: Not used
- `.title3`: Not used
- `.headline`: Section titles, tab labels
- `.body`: Default text, agent names
- `.callout`: Not used
- `.subheadline`: Not used
- `.footnote`: Not used
- `.caption`: Secondary info (session counts, durations)
- `.caption2`: Timestamps, axis labels, minimal info

**Font Weights:**
- `.regular`: Body text, percentages
- `.medium`: Not commonly used
- `.semibold`: Agent names, emphasis
- `.bold`: Not used (too heavy)

**Line Heights:**
- Default: System (1.2× font size)
- Multi-line: 1.4× for readability

---

## 8. Color System

### Semantic Colors (System Adaptive)
- **Primary Text:** `.primary` (black in light, white in dark)
- **Secondary Text:** `.secondary` (gray tones)
- **Tertiary Text:** `.tertiary` (lighter gray)
- **Backgrounds:** 
  - Main: `.background`
  - Cards: `.quaternarySystemFill`
  - Hover: `.tertiarySystemFill`

### Accent Colors (Agent Identity)
- **Codex:** `Color.blue` (system blue)
- **Claude:** `Color.orange` (system orange)
- **Gemini:** `Color.green` (system green)
- **All/Mixed:** `Color.accentColor` (user's preference)

### Status Colors
- **Success/Positive:** `.green`
- **Warning:** `.orange`
- **Error:** `.red`
- **Neutral:** `.secondary`

### Chart Colors
- Grid lines: `.quaternary` (very subtle)
- Axes: `.secondary`
- Bars/areas: Agent colors with full opacity
- Legends: Agent colors with 0.8 opacity

**Dark Mode:**
All colors automatically adapt via system colors. No custom handling needed.

---

## 9. Animations & Transitions

### Entrance Animations
```swift
// Window appears
.transition(.opacity.combined(with: .scale(scale: 0.95)))
.animation(.easeOut(duration: 0.3), value: isShowing)

// Charts load
.transition(.opacity)
.animation(.easeInOut(duration: 0.4), value: chartData)
```

### Data Updates
```swift
// Value changes in cards
.animation(.spring(response: 0.5, dampingFraction: 0.8), value: stats)

// Chart bars grow
.animation(.easeInOut(duration: 0.6), value: chartData)
```

### Interactions
```swift
// Card hover
.scaleEffect(isHovered ? 1.02 : 1.0)
.animation(.easeOut(duration: 0.2), value: isHovered)

// Refresh button spin
.rotationEffect(.degrees(isRefreshing ? 360 : 0))
.animation(.linear(duration: 1.0).repeatWhile(isRefreshing), value: isRefreshing)
```

**Performance:**
- All animations use SwiftUI's optimized rendering
- No custom Core Animation needed
- Charts use built-in SwiftUI Charts animations

---

## 10. Accessibility

### VoiceOver Support
```swift
// Stats card
.accessibilityElement(children: .combine)
.accessibilityLabel("Sessions: 87, up 12% from previous period")

// Chart
.accessibilityLabel("Sessions over time chart showing 7 days of activity")
.accessibilityValue("52 Codex sessions and 35 Claude sessions")

// Refresh button
.accessibilityLabel("Refresh analytics")
.accessibilityHint("Updates data from recent sessions")
```

### Keyboard Navigation
- All interactive elements focusable with Tab
- Space/Return activates buttons
- Arrow keys navigate tabs/pickers
- Escape closes window

### Reduced Motion
```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

// Conditional animations
.animation(reduceMotion ? nil : .easeOut, value: data)
```

### High Contrast
- All text meets WCAG AA (4.5:1 contrast)
- Chart colors distinguishable in high contrast mode
- Borders appear on cards in high contrast

---

## 11. Empty & Error States

### No Sessions (First Time)
```
┌─────────────────────────────────────────┐
│              🚀                         │
│                                         │
│      Welcome to Analytics!              │
│                                         │
│   Start using AI agents to see          │
│   insights about your coding sessions   │
└─────────────────────────────────────────┘
```

### No Data for Filters
```
┌─────────────────────────────────────────┐
│              🔍                         │
│                                         │
│      No sessions found                  │
│                                         │
│   Try adjusting your date range         │
│   or agent filter                       │
│                                         │
│   [Reset Filters]                       │
└─────────────────────────────────────────┘
```

### Error Loading Data
```
┌─────────────────────────────────────────┐
│              ⚠️                         │
│                                         │
│   Could not load analytics              │
│                                         │
│   [Try Again]                           │
└─────────────────────────────────────────┘
```

---

## 12. Implementation Checklist

### Phase 1: Structure (Day 1-2)
- [ ] Create AnalyticsWindow.swift
- [ ] Add toolbar button to main window
- [ ] Set up window management (show/hide, persistence)
- [ ] Implement navigation tabs (Total/Projects/Agents)
- [ ] Add date range and agent filter pickers
- [ ] Create refresh button with loading state

### Phase 2: Stats Cards (Day 3)
- [ ] Create StatsCardView component
- [ ] Implement 4 card types (Sessions, Messages, Commands, Time)
- [ ] Add percentage change calculations
- [ ] Style with SF Symbols and system colors
- [ ] Add accessibility labels

### Phase 3: Primary Chart (Day 4-5)
- [ ] Set up SwiftUI Chart with stacked bars
- [ ] Implement date-based aggregation logic
- [ ] Add agent color coding
- [ ] Create chart legend
- [ ] Handle empty state
- [ ] Add tooltips on hover

### Phase 4: Secondary Insights (Day 6)
- [ ] Create agent breakdown card with progress bars
- [ ] Implement time-of-day heatmap
- [ ] Calculate "Most Active" insight
- [ ] Style both cards consistently

### Phase 5: Polish (Day 7)
- [ ] Add all animations and transitions
- [ ] Implement auto-refresh logic
- [ ] Add timestamp footer
- [ ] Test dark mode appearance
- [ ] Complete accessibility audit
- [ ] Add keyboard shortcuts
- [ ] Test with empty/error states

---

## 13. Design Tokens (Constants)

```swift
enum AnalyticsDesign {
    // Window
    static let defaultSize = CGSize(width: 900, height: 650)
    static let minimumSize = CGSize(width: 700, height: 500)
    
    // Spacing
    static let windowPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let cardSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 16
    
    // Sizes
    static let headerHeight: CGFloat = 60
    static let statsCardHeight: CGFloat = 100
    static let primaryChartHeight: CGFloat = 280
    static let secondaryCardHeight: CGFloat = 180
    
    // Corner Radius
    static let cardCornerRadius: CGFloat = 10
    static let chartBarCornerRadius: CGFloat = 4
    static let heatmapCellCornerRadius: CGFloat = 3
    
    // Animation
    static let defaultDuration: Double = 0.3
    static let chartDuration: Double = 0.6
    static let hoverDuration: Double = 0.2
    
    // Colors
    static let codexColor = Color.blue
    static let claudeColor = Color.orange
    static let geminiColor = Color.green
    
    // Auto-refresh
    static let refreshInterval: TimeInterval = 300 // 5 minutes
}
```

---

## Summary

This design provides:
- **Clear Visual Hierarchy:** Important data prominently displayed
- **Native macOS Feel:** Uses system colors, fonts, and components
- **Developer-Friendly:** Clean, minimal, functional aesthetic
- **Accessible:** Full VoiceOver and keyboard support
- **Performant:** Local data, fast updates, smooth animations
- **Extensible:** Easy to add Projects and Agents tabs later

The implementation follows HIG guidelines while maintaining Agent Sessions' developer-focused identity. Every element serves a purpose, and the design scales gracefully from 700pt to large displays.
