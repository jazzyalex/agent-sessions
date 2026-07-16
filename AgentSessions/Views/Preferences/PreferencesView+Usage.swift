import SwiftUI

struct LimitAlertReadinessFormatter {
    static func text(provider: String,
                     source: String,
                     freshness: String,
                     observedAt: Double,
                     projection: String,
                     projectionRunoutAt: Double,
                     projectionObservedAt: Double,
                     delivery: String,
                     deliveryAt: Double,
                     notificationsEnabled: Bool,
                     providerEnabled: Bool,
                     visualEnabled: Bool,
                     soundEnabled: Bool,
                     now: Date = Date()) -> String {
        guard notificationsEnabled else { return "Alerts off" }
        guard providerEnabled else { return "Alerts off for \(provider)" }
        if !visualEnabled && !soundEnabled { return "Delivery off" }

        if observedAt <= 0 || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Waiting for usage data"
        }

        let age = now.timeIntervalSince(Date(timeIntervalSince1970: observedAt))
        if age > 10 * 60 || freshness.localizedCaseInsensitiveContains("stale") {
            return "Stale; alerts may be delayed"
        }

        let deliveryText = delivery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if visualEnabled,
           deliveryAt > 0,
           deliveryText.contains("denied")
            || deliveryText.contains("failed")
            || deliveryText.contains("unknown") {
            return "Notifications need attention"
        }

        let projectionText = formatUsageProjectionDiagnosticsText(
            projection,
            runoutAt: projectionRunoutAt,
            observedAt: projectionObservedAt,
            now: now
        )
        if projectionText.hasPrefix("Active ") {
            return "Watching active 5h burn"
        }
        if !visualEnabled {
            return "Ready; sound only"
        }
        return "Ready"
    }
}

extension PreferencesView {

    private var webApiEffectivelyEnabled: Bool {
        let mode = ClaudeUsageMode(rawValue: UserDefaults.standard.string(forKey: PreferencesKey.claudeUsageMode) ?? "auto") ?? .auto
        if mode == .webOnly { return true }
        if mode == .auto && UserDefaults.standard.bool(forKey: PreferencesKey.claudeWebApiEnabled) { return true }
        return false
    }

    var usageTrackingTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Usage Tracking")
                .font(.title2)
                .fontWeight(.semibold)

            // Sources
            sectionHeader("Usage Sources")
            VStack(alignment: .leading, spacing: 12) {
                // Codex
                HStack(spacing: 12) {
                    toggleRow("Enable Codex tracking", isOn: $codexUsageEnabled, help: "Turn Codex usage tracking on or off (independent of strip/menu bar)")
                    Button("Refresh now") { CodexUsageModel.shared.refreshNow() }
                        .buttonStyle(.bordered)
                        .disabled(!codexUsageEnabled || !codexAgentEnabled)
                }
                .disabled(!codexAgentEnabled)
                labeledRow("Refresh every") {
                    Picker("", selection: $codexPollingInterval) {
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("3 minutes").tag(180)
                    }
                    .pickerStyle(.segmented)
                    .help("How often to refresh Codex usage while a usage surface is visible. Automatic /status probes keep their separate cooldowns.")
                }
                .disabled(!codexAgentEnabled)

                Divider().padding(.vertical, 6)

                // Claude
                HStack(spacing: 12) {
                    toggleRow("Enable Claude tracking", isOn: $claudeUsageEnabled, help: "Turn Claude usage tracking on or off (independent of strip/menu bar)")
                    Button("Refresh now") { ClaudeUsageModel.shared.refreshNow() }
                        .buttonStyle(.bordered)
                        .disabled(!claudeUsageEnabled || !claudeAgentEnabled)
                }
                .disabled(!claudeAgentEnabled)
                labeledRow("Data source") {
                    Picker("", selection: Binding(
                        get: { ClaudeUsageMode(rawValue: UserDefaults.standard.string(forKey: PreferencesKey.claudeUsageMode) ?? "auto") ?? .auto },
                        set: { UserDefaults.standard.set($0.rawValue, forKey: PreferencesKey.claudeUsageMode) }
                    )) {
                        ForEach(ClaudeUsageMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    .help("Auto: OAuth endpoint (60s); CLI tmux fallback only if you opt in below. Web API only: claude.ai session cookie. tmux only: legacy behavior.")
                }
                .disabled(!claudeAgentEnabled || !claudeUsageEnabled)
                toggleRow(
                    "Include Web API in Auto fallback",
                    isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.claudeWebApiEnabled) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.claudeWebApiEnabled) }
                    ),
                    help: "When enabled, Auto mode falls back to the claude.ai Web API before tmux. Uses a session cookie you paste below — no Full Disk Access needed."
                )
                .disabled(!claudeAgentEnabled || !claudeUsageEnabled ||
                          (ClaudeUsageMode(rawValue: UserDefaults.standard.string(forKey: PreferencesKey.claudeUsageMode) ?? "auto") ?? .auto) != .auto)
                if webApiEffectivelyEnabled {
                    ClaudeWebSessionCookieCallout()
                }
                toggleRow(
                    "Allow CLI probe fallback",
                    isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: PreferencesKey.claudeTmuxAutoFallbackOptIn) },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.claudeTmuxAutoFallbackOptIn) }
                    ),
                    help: "When the OAuth endpoint keeps failing, Auto mode may fall back to running `claude` in tmux to scrape /usage. Off by default — the interactive CLI can open a browser sign-in. tmux-only mode is unaffected."
                )
                .disabled(!claudeAgentEnabled || !claudeUsageEnabled ||
                          (ClaudeUsageMode(rawValue: UserDefaults.standard.string(forKey: PreferencesKey.claudeUsageMode) ?? "auto") ?? .auto) != .auto)
                labeledRow("Refresh every") {
                    Picker("", selection: $claudePollingInterval) {
                        Text("2 minutes").tag(120)
                        Text("3 minutes").tag(180)
                    }
                    .pickerStyle(.segmented)
                    .help("How often to refresh Claude tmux fallback while a usage surface is visible. OAuth and Web API sources refresh every 60 seconds.")
                }
                .disabled(!claudeAgentEnabled || !claudeUsageEnabled)
            }

            // Strip options (shared)
            sectionHeader("Strip Options")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show Codex strip", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showCodexStrip) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showCodexStrip) }
                ), help: "Show the Codex usage strip at the bottom of the Unified window")
                    .disabled(!codexUsageEnabled || !codexAgentEnabled)
                toggleRow("Show Claude strip", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showClaudeStrip) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Unified.showClaudeStrip) }
                ), help: "Show the Claude usage strip at the bottom of the Unified window")
                    .disabled(!claudeUsageEnabled || !claudeAgentEnabled)
                toggleRow("Show reset times", isOn: $stripShowResetTime, help: "Display the usage reset timestamp next to each meter")
            }

            // Display style (shared across Codex & Claude)
            sectionHeader("Display Style")
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Quota Meter display") {
                    Picker("", selection: Binding(
                        get: { UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .left },
                        set: { usageDisplayModeRaw = $0.rawValue }
                    )) {
                        ForEach(UsageDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Choose whether usage meters show remaining (left) or used percentages.")
                }
                Text("Applies to Codex and Claude usage strips, menu bar reset meters, and the Quota Meter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                labeledRow("Session Runway") {
                    Picker("", selection: Binding(
                        get: { QuotaMeterRunwayVisibility.current(raw: quotaMeterRunwayVisibilityRaw) },
                        set: { quotaMeterRunwayVisibilityRaw = $0.rawValue }
                    )) {
                        ForEach(QuotaMeterRunwayVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Choose when Quota Meter shows the session runway drawer.")
                }

                labeledRow("On-track glyph") {
                    Picker("", selection: Binding(
                        get: { QuotaMeterOnTrackGlyph.current(raw: quotaMeterOnTrackGlyphRaw) },
                        set: { quotaMeterOnTrackGlyphRaw = $0.rawValue }
                    )) {
                        ForEach(QuotaMeterOnTrackGlyph.allCases) { glyph in
                            Text(glyph.title).tag(glyph)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("When you’re working but on track to fit the 5-hour window, show a smiling face or a quiet dot in the run-out column.")
                }
                Text(QuotaMeterOnTrackGlyph.current(raw: quotaMeterOnTrackGlyphRaw).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Menu Bar controls moved to the Menu Bar pane
        }
        .onAppear(perform: normalizeUsagePollingIntervals)
    }

    private func normalizeUsagePollingIntervals() {
        if ![60, 120, 180].contains(codexPollingInterval) {
            codexPollingInterval = 60
        }
        if ![120, 180].contains(claudePollingInterval) {
            claudePollingInterval = 180
        }
    }

    var limitAlertsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Limit Alerts")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Alert Sources")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow(
                    "Notify for usage limits",
                    isOn: $usageLimitNotificationsEnabled,
                    help: "Enable Codex and Claude usage-limit alerts."
                )
                .disabled(!(codexAgentEnabled && codexUsageEnabled) && !(claudeAgentEnabled && claudeUsageEnabled))

                labeledRow("Providers") {
                    HStack(spacing: 16) {
                        Toggle("Codex", isOn: $usageLimitNotificationCodexEnabled)
                            .toggleStyle(.checkbox)
                            .disabled(!codexAgentEnabled || !codexUsageEnabled || !usageLimitNotificationsEnabled)
                        Toggle("Claude", isOn: $usageLimitNotificationClaudeEnabled)
                            .toggleStyle(.checkbox)
                            .disabled(!claudeAgentEnabled || !claudeUsageEnabled || !usageLimitNotificationsEnabled)
                    }
                    .help("Choose which usage sources can send limit alerts.")
                }
                .disabled(!usageLimitNotificationsEnabled)
            }

            sectionHeader("Alert Types")
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Warnings") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Low remaining", isOn: $usageLimitNotificationApproachingEnabled)
                            .toggleStyle(.checkbox)
                        Toggle("Predicted run-out soon", isOn: $usageLimitNotificationProjectedEnabled)
                            .toggleStyle(.checkbox)
                        Toggle("Limit exhausted", isOn: $usageLimitNotificationExhaustedEnabled)
                            .toggleStyle(.checkbox)
                        Toggle("5h reset reminder", isOn: $usageLimitNotificationFiveHourResetEnabled)
                            .toggleStyle(.checkbox)
                    }
                    .help("Choose which limit events should create alerts.")
                }
                .disabled(!usageLimitNotificationsEnabled)

                labeledRow("Low limit threshold") {
                    Stepper(value: $usageLimitNotificationThresholdPercent, in: 1...50, step: 1) {
                        Text("\(usageLimitNotificationThresholdPercent)% remaining")
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                    .help("Alert once per reset window when a 5h or weekly limit reaches this remaining percentage.")
                }
                .disabled(!usageLimitNotificationsEnabled || !usageLimitNotificationApproachingEnabled)

                Text("Prediction alerts use fresh usage data and fire when the current burn rate can exhaust a 5h or weekly limit within 60 minutes before reset. Recent cached data can still produce low, exhausted, and 5h reset alerts; stale data is ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            sectionHeader("Diagnostics")
            TimelineView(.periodic(from: Date(), by: 30)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    limitAlertDiagnosticsRow(
                        provider: "Codex",
                        source: usageLimitDiagnosticsCodexSource,
                        freshness: usageLimitDiagnosticsCodexFreshness,
                        observedAt: usageLimitDiagnosticsCodexObservedAt,
                        projection: usageLimitDiagnosticsCodexProjection,
                        projectionRunoutAt: usageLimitDiagnosticsCodexProjectionRunoutAt,
                        projectionObservedAt: usageLimitDiagnosticsCodexProjectionObservedAt,
                        lastAlert: usageLimitDiagnosticsCodexLastAlertSummary,
                        lastAlertAt: usageLimitDiagnosticsCodexLastAlertAt,
                        delivery: usageLimitDiagnosticsCodexDelivery,
                        deliveryAt: usageLimitDiagnosticsCodexDeliveryAt,
                        nextResetAt: usageLimitDiagnosticsCodexNextResetReminderAt
                    )
                    Divider()
                    limitAlertDiagnosticsRow(
                        provider: "Claude",
                        source: usageLimitDiagnosticsClaudeSource,
                        freshness: usageLimitDiagnosticsClaudeFreshness,
                        observedAt: usageLimitDiagnosticsClaudeObservedAt,
                        projection: usageLimitDiagnosticsClaudeProjection,
                        projectionRunoutAt: usageLimitDiagnosticsClaudeProjectionRunoutAt,
                        projectionObservedAt: usageLimitDiagnosticsClaudeProjectionObservedAt,
                        lastAlert: usageLimitDiagnosticsClaudeLastAlertSummary,
                        lastAlertAt: usageLimitDiagnosticsClaudeLastAlertAt,
                        delivery: usageLimitDiagnosticsClaudeDelivery,
                        deliveryAt: usageLimitDiagnosticsClaudeDeliveryAt,
                        nextResetAt: usageLimitDiagnosticsClaudeNextResetReminderAt
                    )
                    Text("Updates when usage tracking receives a limit snapshot. Projection diagnostics use fresh or recent cached data; reset reminders require banners and 5h reset reminders to be enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            sectionHeader("Delivery")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow(
                    "macOS notification banners",
                    isOn: $usageLimitNotificationVisualEnabled,
                    help: "Use macOS notifications for usage limit alerts and scheduled 5h reset reminders."
                )
                .disabled(!usageLimitNotificationsEnabled)

                toggleRow(
                    "Play sound for immediate alerts",
                    isOn: $usageLimitNotificationSoundEnabled,
                    help: "Play a sound when a low, predicted, exhausted, or reset-complete alert fires. Scheduled reset reminders use macOS notification sound when banners are enabled."
                )
                .disabled(!usageLimitNotificationsEnabled)
            }
        }
        .onAppear(perform: seedProjectedAlertDefault)
        .onAppear(perform: cancelDisabledLimitResetReminders)
        .onChange(of: usageLimitNotificationsEnabled) { _, _ in cancelDisabledLimitResetReminders() }
        .onChange(of: usageLimitNotificationVisualEnabled) { _, _ in cancelDisabledLimitResetReminders() }
        .onChange(of: usageLimitNotificationFiveHourResetEnabled) { _, _ in cancelDisabledLimitResetReminders() }
        .onChange(of: usageLimitNotificationCodexEnabled) { _, _ in cancelDisabledLimitResetReminders() }
        .onChange(of: usageLimitNotificationClaudeEnabled) { _, _ in cancelDisabledLimitResetReminders() }
    }

    private func limitAlertDiagnosticsRow(provider: String,
                                          source: String,
                                          freshness: String,
                                          observedAt: Double,
                                          projection: String,
                                          projectionRunoutAt: Double,
                                          projectionObservedAt: Double,
                                          lastAlert: String,
                                          lastAlertAt: Double,
                                          delivery: String,
                                          deliveryAt: Double,
                                          nextResetAt: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(limitAlertReadinessText(
                provider: provider,
                source: source,
                freshness: freshness,
                observedAt: observedAt,
                projection: projection,
                projectionRunoutAt: projectionRunoutAt,
                projectionObservedAt: projectionObservedAt,
                delivery: delivery,
                deliveryAt: deliveryAt
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                diagnosticsField(
                    "Source",
                    value: emptyFallback(source, fallback: "Waiting for data")
                )
                diagnosticsField(
                    "Freshness",
                    value: diagnosticsFreshnessText(freshness: freshness, observedAt: observedAt)
                )
                diagnosticsField(
                    "5h Projection",
                    value: formatUsageProjectionDiagnosticsText(
                        projection,
                        runoutAt: projectionRunoutAt,
                        observedAt: projectionObservedAt
                    )
                )
            }
            HStack(alignment: .top, spacing: 16) {
                diagnosticsField(
                    "Last Alert",
                    value: diagnosticsLastAlertText(summary: lastAlert, timestamp: lastAlertAt)
                )
                diagnosticsField(
                    "Delivery",
                    value: diagnosticsDeliveryText(summary: delivery, timestamp: deliveryAt)
                )
                diagnosticsField(
                    "Next 5h Reminder",
                    value: diagnosticsNextResetText(timestamp: nextResetAt)
                )
            }
        }
    }

    private func limitAlertReadinessText(provider: String,
                                         source: String,
                                         freshness: String,
                                         observedAt: Double,
                                         projection: String,
                                         projectionRunoutAt: Double,
                                         projectionObservedAt: Double,
                                         delivery: String,
                                         deliveryAt: Double) -> String {
        LimitAlertReadinessFormatter.text(
            provider: provider,
            source: source,
            freshness: freshness,
            observedAt: observedAt,
            projection: projection,
            projectionRunoutAt: projectionRunoutAt,
            projectionObservedAt: projectionObservedAt,
            delivery: delivery,
            deliveryAt: deliveryAt,
            notificationsEnabled: usageLimitNotificationsEnabled,
            providerEnabled: provider == "Codex" ? usageLimitNotificationCodexEnabled : usageLimitNotificationClaudeEnabled,
            visualEnabled: usageLimitNotificationVisualEnabled,
            soundEnabled: usageLimitNotificationSoundEnabled
        )
    }

    private func diagnosticsField(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diagnosticsLastAlertText(summary: String, timestamp: Double) -> String {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, timestamp > 0 else {
            return "None yet"
        }
        return "\(summary) / \(relativeTimestamp(timestamp))"
    }

    private func diagnosticsDeliveryText(summary: String, timestamp: Double) -> String {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, timestamp > 0 else {
            return "None yet"
        }
        return "\(summary) / \(relativeTimestamp(timestamp))"
    }

    private func diagnosticsFreshnessText(freshness: String, observedAt: Double) -> String {
        let base = emptyFallback(freshness, fallback: "Waiting for data")
        guard observedAt > 0 else { return base }
        let age = Date().timeIntervalSince(Date(timeIntervalSince1970: observedAt))
        let adjusted: String
        if age > 10 * 60 {
            adjusted = "stale"
        } else if age > 3 * 60 {
            adjusted = base.replacingOccurrences(of: "fresh", with: "stale")
        } else {
            adjusted = base
        }
        return "\(adjusted) / seen \(relativeTimestamp(observedAt))"
    }

    private func diagnosticsNextResetText(timestamp: Double) -> String {
        guard usageLimitNotificationsEnabled,
              usageLimitNotificationVisualEnabled,
              usageLimitNotificationFiveHourResetEnabled else {
            return "Off"
        }
        guard timestamp > 0 else { return "None scheduled" }
        let date = Date(timeIntervalSince1970: timestamp)
        if date < Date() { return "Expired" }
        let timeText = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        return "\(timeText) / \(relativeTimestamp(timestamp))"
    }

    private func relativeTimestamp(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func emptyFallback(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func seedProjectedAlertDefault() {
        guard UserDefaults.standard.object(forKey: PreferencesKey.usageLimitNotificationProjectedEnabled) == nil else {
            return
        }
        usageLimitNotificationProjectedEnabled = usageLimitNotificationApproachingEnabled
    }

    private func cancelDisabledLimitResetReminders() {
        let resetRemindersGloballyDisabled = !usageLimitNotificationsEnabled
            || !usageLimitNotificationVisualEnabled
            || !usageLimitNotificationFiveHourResetEnabled
        if resetRemindersGloballyDisabled || !usageLimitNotificationCodexEnabled {
            UsageLimitNotifier.shared.cancelScheduledFiveHourReset(provider: .codex)
        }
        if resetRemindersGloballyDisabled || !usageLimitNotificationClaudeEnabled {
            UsageLimitNotifier.shared.cancelScheduledFiveHourReset(provider: .claude)
        }
    }

}

/// Web-API readiness callout: the static "requires Full Disk Access" hint plus a
/// live, user-initiated self-test. The test walks the REAL chain — Safari cookie
/// read → org lookup → usage fetch — and reports the first failure with its
/// remedy, so "enabled but silently unusable" (the TCC-denied cookie read) is
/// visible right where the toggle lives instead of dying as a log line.
/// Preferences affordance for the claude.ai Web API source. The primary, durable
/// path is a session cookie the user pastes: sign-in stays in the user's browser,
/// the app only stores the token they hand it (in the Keychain), and it needs no
/// Full Disk Access. Reading the cookie out of Safari is kept only as a legacy
/// fallback (usually unavailable on macOS 14+). The "Test now" button probes the
/// SAME source order the app uses, so "enabled but silently unusable" is visible
/// right where the toggle lives instead of dying as a log line.
private struct ClaudeWebSessionCookieCallout: View {
    private enum TestState: Equatable {
        case idle
        case running
        case result(String, ok: Bool)
    }

    @State private var testState: TestState = .idle
    @State private var pasteText: String = ""
    @State private var hasCookie: Bool = false
    @State private var showHelp: Bool = false

    private let store = ClaudeManualWebCookieStore.shared

    var body: some View {
        PreferenceCallout(iconName: "key.fill", tint: .blue) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste your claude.ai session cookie so Agent Sessions can read subscription usage without the CLI. Sign-in stays in your browser — the app only stores the token you paste, in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if hasCookie {
                    HStack(spacing: 8) {
                        Label("A session cookie is saved", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color.green)
                        Button("Remove") { removeCookie() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    SecureField("Paste sessionKey or cookie header", text: $pasteText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: 320)
                    Button("Save") { saveCookie() }
                        .font(.caption)
                        .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack(spacing: 12) {
                    Button(showHelp ? "Hide steps" : "How do I get this?") { showHelp.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                    Button(testState == .running ? "Testing…" : "Test now") { runTest() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(testState == .running)
                }

                if showHelp {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. Open claude.ai in your browser, signed in.")
                        Text("2. Open Developer Tools → Application/Storage → Cookies → https://claude.ai.")
                        Text("3. Copy the value of the “sessionKey” cookie and paste it above.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if case .result(let message, let ok) = testState {
                    Label(message, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(ok ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().padding(.vertical, 2)
                HStack(alignment: .top, spacing: 12) {
                    Text("Legacy: read the cookie from Safari instead. Needs Full Disk Access, and is usually unavailable on macOS 14+.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Full Disk Access…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .fixedSize()
                }
            }
        }
        .onAppear { hasCookie = store.hasStoredCookie }
    }

    private func saveCookie() {
        if store.save(pasted: pasteText) {
            pasteText = ""
            hasCookie = true
            runTest()
        } else {
            testState = .result("That didn’t contain a claude.ai “sessionKey”. Paste the sessionKey cookie value.", ok: false)
        }
    }

    private func removeCookie() {
        store.clear()
        hasCookie = false
        testState = .idle
    }

    private func runTest() {
        testState = .running
        Task {
            let outcome = await ClaudeWebSessionCookieCallout.performTest()
            await MainActor.run { testState = .result(outcome.message, ok: outcome.ok) }
        }
    }

    /// End-to-end probe of the Web API chain, in the SAME source order the app uses
    /// (pasted cookie first, Safari-file scraping only as a legacy fallback), with
    /// cause-aware messaging. User-initiated only — never called on a timer.
    static func performTest() async -> (message: String, ok: Bool) {
        let sessionKey: String
        if let manual = ClaudeManualWebCookieStore.shared.currentSessionKey() {
            sessionKey = manual
        } else {
            let resolver = ClaudeWebCookieResolver()
            switch await resolver.resolveDetailed() {
            case .found(let cookie):
                sessionKey = cookie.sessionKey
            case .permissionDenied:
                return ("No pasted cookie, and Safari access is blocked. Paste your sessionKey above (or grant Full Disk Access for the legacy path).", false)
            case .cookieExpired:
                return ("Safari's claude.ai session cookie has expired. Paste a fresh sessionKey above.", false)
            case .storeMissing, .validStoreNoCookie, .unsupportedFormat, .malformedRecord:
                // The old message told a signed-in user to "sign in at claude.ai
                // (default profile)" — a lie on macOS 14/15, where Safari keeps the
                // live cookie in a store apps can't read. Say what's actually true.
                return ("No claude.ai session found. Paste your sessionKey above — Safari no longer exposes it to apps on macOS 14+.", false)
            }
        }

        do {
            // bypassCache: the self-test must validate THIS cookie live, not return
            // a recent cached response that may have been fetched with a different one.
            let result = try await ClaudeWebUsageClient().fetch(sessionKey: sessionKey, bypassCache: true)
            return result.fromCache
                ? ("Working — served from a recent cached response.", true)
                : ("Working — usage fetched live from claude.ai.", true)
        } catch ClaudeOAuthUsageClientError.unauthorized {
            return ("The claude.ai session is expired or invalid — paste a fresh sessionKey.", false)
        } catch {
            return ("claude.ai request failed: \(error.localizedDescription)", false)
        }
    }
}
