# iOS Companion Runway PRD

Status: Draft exploration
Date: 2026-06-15
Owner: Product / Agent Cockpit
Scope: Define a low-risk iOS companion path for Agent Sessions limits, burn-rate, and active-session status.

## Decision

Build the iOS companion around a small Mac-produced status snapshot, not around direct iOS access to Codex credentials, local JSONL logs, or provider APIs.

The Mac app is already the trusted collector. It can read local session logs, compute Codex and Claude limit state, attribute active-session burn, and preserve the current local-first security posture. The iOS app, widget, and Live Activity should render the latest exported snapshot and request user attention when the Mac collector reports pressure.

## Product Shape

The companion should answer one question quickly:

```text
Can I keep my current agent work running until reset?
```

Primary glance:

```text
Codex 5h     91% used    >1h35m burn-out    3h33m reset
Weekly       64% used    safe until Sunday

Active drain
GOAL auth-flow       after reset if paused    +1h58m
tests-cleanup        >1h52m if paused         +17m
```

Secondary states:

- Mac offline: show the last snapshot age and do not imply current safety.
- No active pressure: keep the widget provider-first and avoid filling space with low-value session rows.
- Stale data: show stale timing before any burn interpretation.
- Paused session: show how the deadline changes after pausing, using the same Runway grammar as the Mac HUD.

## Mockups

### iPhone App: Today

```text
┌─────────────────────────────────────┐
│ Agent Sessions              now 09:41│
├─────────────────────────────────────┤
│ Codex 5h                            │
│ 91% used       burn-out >1h35m      │
│ reset 3h33m    updated 42s ago      │
│ ████████████████████░░              │
│                                     │
│ Weekly                              │
│ 64% used       safe until Sunday    │
│ reset Sun 04:00                     │
├─────────────────────────────────────┤
│ Active drain                        │
│ GOAL auth-flow                      │
│ if paused: after reset       +1h58m │
│                                     │
│ tests-cleanup                       │
│ if paused: >1h52m             +17m  │
│                                     │
│ +4 bursts                           │
│ if paused: >1h44m              +9m  │
├─────────────────────────────────────┤
│ Mac collector                       │
│ MacBook Pro awake, last sync 42s    │
└─────────────────────────────────────┘
```

Primary interactions:

- Tap provider card: open full 5h/weekly detail, source, last sample, and reset clock.
- Tap active drain row: show pause-impact math and the source Mac session name.
- Pull to refresh: fetch latest cloud snapshot and show whether it is newer than the rendered widget snapshot.
- Long press active drain: start a Live Activity for that session if the current snapshot is fresh enough.

### Home Screen Medium Widget

Best default widget for the main screen or the left-swipe widget screen.

```text
┌─────────────────────────────────────┐
│ AS Runway                 fresh 3m  │
│ Codex 5h   91%  >1h35m   ↻3h33m     │
│ Weekly     64%  safe     Sun        │
│                                     │
│ Pause first: auth-flow              │
│ after reset if paused        +1h58m │
└─────────────────────────────────────┘
```

Design rules:

- The upper-right freshness label is mandatory.
- If freshness is older than the warning threshold, replace `fresh 3m` with `stale 28m` and dim burn interpretation.
- Show one pause action only. Widgets should not become mini dashboards.
- Use the same clock-first grammar as the Mac Quota Meter: used percent, burn-out ETA, reset ETA.

### Home Screen Small Widget

For users who want a permanent slot on the first page.

```text
┌─────────────────┐
│ Codex 5h   91%  │
│ >1h35m          │
│ ↻3h33m          │
│ fresh 3m        │
└─────────────────┘
```

Small widget fallback states:

```text
┌─────────────────┐
│ Codex 5h        │
│ stale 31m       │
│ open app        │
│ last 91%        │
└─────────────────┘
```

### Lock Screen Accessory

Use only for a coarse pressure indicator. The Lock Screen accessory is too small for session attribution.

```text
Codex 91%  >1h35m
```

Fallback:

```text
AS stale 31m
```

### Live Activity

Use for an active pressure window, not for always-on passive monitoring.

Lock Screen:

```text
┌─────────────────────────────────────┐
│ Agent Sessions Runway               │
│ Codex burn-out >1h35m   reset 3h33m │
│ Pause auth-flow: after reset +1h58m │
│ snapshot 2m ago                     │
└─────────────────────────────────────┘
```

Dynamic Island expanded:

```text
┌───────────────────────────────┐
│ Codex 91%  >1h35m  ↻3h33m     │
│ Pause auth-flow       +1h58m  │
└───────────────────────────────┘
```

Dynamic Island compact:

```text
AS 91%  >1h35m
```

Serverless v1 rule: the Live Activity can count down from the last synced `burnoutAt` and `resetAt` dates, but it should not claim live burn-rate accuracy after the snapshot becomes stale. True remote Live Activity updates from Mac activity would require APNs update infrastructure; CloudKit or iCloud sync alone should not be treated as a reliable background Live Activity update channel.

### Apple Watch

Defer watch app work until the iPhone app and widget prove useful. The first watch surface should be a one-glance complication-style view:

```text
Codex
91%
>1h35m
```

## Current Repo Evidence

- The macOS app is the only app target today. `AgentSessions.xcodeproj/project.pbxproj` has the `AgentSessions` application target and test targets, with `SUPPORTED_PLATFORMS = macosx`.
- The entitlement file is effectively empty, so App Groups, iCloud, CloudKit, widget, and Live Activity capabilities are not configured yet.
- The app is explicitly local-first: session data stays on the Mac and the only documented network activity is optional Sparkle update checking.
- `CodexUsageModel` already owns 5h and weekly percentages, reset text, last update timestamps, and projected 5h run-out timestamps.
- `CodexRunwayModel` already owns the provider baseline, pause-impact rows, attribution confidence, and recent active-session scan logic.
- `HUDRunwayIdentityReducer` already reduces active HUD rows into parent-aware Codex runway identities so subagent log paths can roll up under the parent session.

## Snapshot Contract

Add a Foundation-only shared contract before adding iOS targets:

```swift
struct AgentSessionsMobileSnapshot: Codable, Equatable {
    var schemaVersion: Int
    var generatedAt: Date
    var macName: String?
    var providers: [MobileProviderLimitSnapshot]
    var activeSessions: [MobileActiveSessionSnapshot]
}

struct MobileProviderLimitSnapshot: Codable, Equatable {
    var provider: String
    var fiveHourUsedPercent: Int?
    var fiveHourRemainingPercent: Int?
    var fiveHourResetAt: Date?
    var fiveHourProjectedRunoutAt: Date?
    var weeklyUsedPercent: Int?
    var weeklyRemainingPercent: Int?
    var weeklyResetAt: Date?
    var freshness: String
    var source: String?
}

struct MobileActiveSessionSnapshot: Codable, Equatable {
    var id: String
    var provider: String
    var displayName: String
    var isGoal: Bool
    var state: String
    var lastActivityAt: Date?
    var pauseImpact: MobilePauseImpact?
}

struct MobilePauseImpact: Codable, Equatable {
    var deadlineIfPaused: Date?
    var reachesResetIfPaused: Bool
    var gainedSeconds: TimeInterval
    var quotaMinutesPerHour: Double
    var confidence: String
}
```

Rules:

- The snapshot must not contain raw transcript text, prompts, command output, credentials, cookies, or local absolute paths.
- Provider reset dates should be resolved to `Date` on the Mac before export; iOS should not parse provider-specific reset strings.
- The contract should be additive and versioned. Widgets and Live Activities should ignore unknown fields.
- Export cadence should be modest: update when provider usage changes, active-session rows change, pressure state changes, or at a capped timer interval.

## Sync Options

Recommended first implementation: local Mac writer plus iCloud key-value or CloudKit private database after the snapshot contract is tested.

Options:

1. Local file only
   - Best for testing the writer and schema.
   - Does not reach iPhone without extra transport.

2. iCloud key-value store
   - Good for a tiny latest-status snapshot.
   - Poor fit for history or many devices.

3. CloudKit private database
   - Better long-term shape for multiple Macs, last-seen device state, and optional history.
   - Requires stronger entitlement, account, failure-mode, and privacy handling.

4. Local network relay
   - Useful for demos and low-latency development.
   - Worse default product posture because the phone cannot rely on it away from the Mac network.

Do not send snapshots through an Agent Sessions server for the first version. That would change the privacy story and create unnecessary credential and trust questions.

## Freshness And Cadence Parameters

The user-facing promise should be:

```text
App: near-current when opened.
Widget: glanceable, usually within minutes, never presented as real time.
Live Activity: countdown-current from its last snapshot, burn-current only while fresh.
```

Recommended defaults:

| Parameter | Default | Notes |
| --- | ---: | --- |
| Mac active collector cadence | 30s | Use when Agent Cockpit or Quota Meter is visible, pinned, or active pressure is detected. |
| Mac normal collector cadence | 60s | Matches the existing Codex usage tracking posture for visible usage surfaces. |
| Mac background ceiling | 180s | Preserve battery and avoid unnecessary probes while still keeping snapshots usable. |
| Snapshot write debounce | 10s | Avoid rewriting for every tiny row/view update. |
| Snapshot write max cadence under pressure | 30s | Enough for iOS app freshness and future server-backed Live Activity decisions. |
| Snapshot write max cadence normal | 60s | Good default when usage is changing but not urgent. |
| Snapshot write max cadence idle | 5m | Keeps stale/offline state moving without noisy sync. |
| Fresh threshold | <= 5m | App and widgets can show normal burn interpretation. |
| Warming threshold | > 5m and <= 15m | Show data, but label age prominently. |
| Stale threshold | > 15m | Replace interpretation with stale-state copy. |
| Offline threshold | > 60m | Treat Mac collector as unavailable until a newer snapshot arrives. |
| Widget target timeline | 15m entries | Ask for useful refreshes, but expect the system to budget actual reload timing. |
| Widget practical expectation | 15-60m | Apple documents adaptive budgets; frequently viewed widgets commonly get roughly this range. |
| Widget daily budget assumption | 40-70 reloads/day | Planning assumption for a frequently viewed widget; never design around per-minute widget updates. |
| iOS app foreground refresh | immediate fetch | On open/pull-to-refresh, read the latest synced snapshot and recalculate countdown labels locally. |
| Live Activity fresh window | 5m | After that, show snapshot age or stale state instead of implying current burn. |
| Live Activity serverless update cadence | opportunistic | Countdown labels can keep moving from dates; burn attribution changes need a fresh synced snapshot. |
| Live Activity APNs-backed update cadence | 1-5m under pressure | Only if a future server/APNs lane exists and budget/throttling behavior is tested. |

Freshness labels:

```text
fresh 42s
fresh 4m
warming 11m
stale 28m
Mac offline 1h12m
```

Widget behavior by age:

| Snapshot age | Widget presentation |
| ---: | --- |
| 0-5m | Full numbers: percent, burn-out ETA, reset ETA, top pause action. |
| 5-15m | Same layout, but freshness label becomes visually dominant. |
| 15-60m | Hide top pause action; show last known percent and `stale`. |
| >60m | Show `Mac offline`, last known provider percent, and open-app affordance. |

Practical expectation for a swipe-left widget glance:

- If the Mac is awake and actively collecting, the widget should usually be useful enough to answer "am I under pressure?".
- It should not promise sub-minute changes. A Home Screen widget can be behind even if the Mac has a fresher snapshot.
- The label must always distinguish snapshot age from reset/burn clocks. A stale `>1h35m` is worse than no burn clock.
- For truly urgent active pressure, the app should offer a Live Activity because it is the correct iOS surface for a few-hour running state.

Apple references used for the cadence assumptions:

- [Keeping a Widget Up To Date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Timeline](https://developer.apple.com/documentation/widgetkit/timeline)
- [Starting and Updating Live Activities with ActivityKit Push Notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)
- [NSSupportsLiveActivitiesFrequentUpdates](https://developer.apple.com/documentation/bundleresources/information-property-list/nssupportsliveactivitiesfrequentupdates)

## Target Layout

Lowest-risk implementation order:

1. Add `AgentSessionsShared` as a Swift package or framework target with Foundation-only snapshot models, formatters, and tests.
2. Add a macOS snapshot producer that converts `CodexUsageModel`, `ClaudeUsageModel`, and `CodexRunwaySnapshot` into `AgentSessionsMobileSnapshot`.
3. Write the latest snapshot to a local JSON file in an app-owned location for testability.
4. Add an iOS app target that reads fixture snapshots and renders the primary glance UI.
5. Add iCloud/CloudKit sync once local writer and iOS renderer are stable.
6. Add WidgetKit after the iOS app can render stale/offline/pressure states.
7. Add ActivityKit for active pressure sessions that need live-ish visibility over a few hours.

The current AppKit shell, menu bar, Dock behavior, and HUD views should stay in the macOS target. Only Foundation-only contracts and formatting should move to shared code.

## Logic Flow

```text
Codex / Claude local activity on Mac
        |
        v
Mac collector
  - reads local session/log state
  - updates provider percentages and reset clocks
  - computes projected burn-out
  - computes Runway pause-impact rows
        |
        v
Redaction + snapshot builder
  - removes raw paths, prompts, output, credentials
  - resolves reset strings to dates
  - marks freshness/source/confidence
        |
        v
Local snapshot store
  - writes latest JSON
  - unit tests verify schema and redaction
        |
        v
Sync lane
  v1: iCloud key-value or CloudKit private database
  dev: local JSON fixture
        |
        v
iOS app
  - fetches latest snapshot on open
  - recalculates relative countdowns from dates
  - starts Live Activity only for fresh pressure snapshots
        |
        +--> WidgetKit
        |     - timeline entries from latest snapshot
        |     - always shows snapshot age
        |
        +--> Live Activity
              - countdowns from last fresh snapshot
              - staleDate / stale copy when snapshot ages out
```

Decision flow:

```text
Is snapshot newer than 5m?
  yes -> show full provider clocks and top pause action.
  no  -> Is snapshot newer than 15m?
          yes -> show clocks with strong freshness warning.
          no  -> Is snapshot newer than 60m?
                  yes -> show stale provider summary only.
                  no  -> show Mac offline state.

Is projected burn-out before reset?
  yes -> rank active sessions by pause-impact gained seconds.
  no  -> show provider safe state; suppress low-impact rows.

Is user starting a Live Activity?
  require fresh snapshot.
  require active pressure or explicit pinned session.
  set stale window to 5m unless APNs-backed updates are available.
```

## iOS Surface Priority

1. iPhone app
   - Shows the latest snapshot, freshness, provider clocks, and top pause-impact rows.
   - Owns settings for notification thresholds and Live Activity start/stop behavior.

2. Home Screen widget
   - Shows last known provider clocks and the highest-impact active session.
   - Must make freshness obvious because widget refresh is system-budgeted.

3. Live Activity / Dynamic Island
   - Use only when the Mac reports active pressure or the user pins a session.
   - Show current burn-out ETA, reset ETA, and the top pause action.

4. Apple Watch
   - Defer until iPhone snapshot rendering and notifications are stable.

## Acceptance Criteria

1. The Mac app can produce a redacted `AgentSessionsMobileSnapshot` without adding network calls or probes.
2. Unit tests verify that raw paths, prompts, command output, and credentials are not exported.
3. The iOS app can render fresh, stale, Mac-offline, pressure, and no-pressure fixture snapshots.
4. The widget never presents stale data as current.
5. A Live Activity can be started from a pressure snapshot and ended when pressure clears or data becomes stale.
6. The existing macOS build continues to pass after shared-code extraction.
7. Documentation and privacy copy are updated before any iCloud or CloudKit capability ships.

## Open Questions

- Should iOS companion support Claude in v1, or keep v1 Codex-only and add Claude after the shared snapshot proves stable?
- Should the Mac app auto-enable snapshot export, or require an explicit companion setup flow?
- Which sync lane fits the first public build: iCloud key-value for latest-only status, or CloudKit private database for a more durable multi-device model?
- Should Live Activity start automatically under active pressure, or only from explicit user action?
- Should the snapshot keep a short history for trend lines, or remain latest-state only for privacy and simplicity?
