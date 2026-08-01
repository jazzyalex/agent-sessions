import Foundation
import os.log

private let liveLog = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeCloud")

/// App-level owner of the Claude cloud-session poll.
///
/// This deliberately does NOT live inside the Quota Meter's derived-state model.
/// It did originally, and the result was that cloud rows never appeared at all:
/// that model only advances inside `rebuildIfReady`, which returns early when its
/// weak `activeCodex` is unbound and is further gated by `HUDRebuildGate`. Neither
/// condition has anything to do with whether a cloud session exists, so the fetch
/// simply never ran.
///
/// Owning the timer here means the poll's liveness depends only on the app being
/// running — the HUD reads whatever rows are current, and is free to rebuild or not.
@MainActor
@Observable
final class ClaudeCloudLiveModel {

    /// Posted after `rows` changes. The Quota Meter's derived-state model rebuilds
    /// its snapshot from this, because that snapshot is assembled imperatively on a
    /// gated tick rather than recomputed from observed state — `@Observable` alone
    /// re-renders views that read `rows`, but does not make that model rebuild.
    static let rowsDidChange = Notification.Name("ClaudeCloudLiveModelRowsDidChange")

    static let shared = ClaudeCloudLiveModel()

    /// Mapped rows ready for the HUD. Empty whenever the feature is off, the cookie
    /// is missing, or the source is in a cleared failure state.
    private(set) var rows: [HUDRow] = []

    /// Bumped whenever `rows` changes, so the HUD's rebuild gate can notice.
    private(set) var version: UInt64 = 0

    /// Stored, not a pass-through to `catalog.state`.
    ///
    /// The catalog is a plain class, so reading through it registered no observation
    /// and the status line rendered whatever state happened to be current at first
    /// body eval — forever. Every failure this line exists to surface (notConnected,
    /// expired, rateLimited, offline, contractDrift, empty) occurs with rows going
    /// [] -> [], so a rows-only invalidation never fires. Copying the state onto a
    /// tracked property is what makes those states visible.
    private(set) var state: ClaudeCloudSourceState = .disabled

    private let catalog: ClaudeCloudSessionCatalog
    private var timer: Timer?
    private var inFlight = false

    /// A network list call. Half-a-minute granularity is ample for a row that says
    /// "still working", and it stays well clear of rate limiting.
    private let interval: TimeInterval = 30

    private init(catalog: ClaudeCloudSessionCatalog? = nil) {
        self.catalog = catalog ?? ClaudeCloudSessionCatalog(
            sessionKeyProvider: { ClaudeManualWebCookieStore.shared.currentSessionKey() },
            isEnabled: { UserDefaults.standard.bool(forKey: PreferencesKey.claudeCloudSessionsEnabled) }
        )
    }

    /// Diagnostic heartbeat.
    ///
    /// os_log from this app does not reach `log show`/`log stream` on this machine,
    /// which made every "did it run?" question unanswerable. A file always works.
    /// Records the last thing the model did, so an empty row list can be attributed
    /// to a stage rather than guessed at.
    static let debugPath = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("com.triada.AgentSessions/cloud-debug.json")

    private func note(_ stage: String, extra: [String: Any] = [:]) {
#if DEBUG
        guard !AppRuntime.isRunningTests, let url = Self.debugPath else { return }
        var payload: [String: Any] = [
            "stage": stage,
            "at": ISO8601DateFormatter().string(from: Date()),
            "enabled": UserDefaults.standard.bool(forKey: PreferencesKey.claudeCloudSessionsEnabled),
            "state": String(describing: catalog.state),
            "rows": rows.count
        ]
        payload.merge(extra) { _, new in new }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: url, options: .atomic)
        }
#else
        _ = (stage, extra)
#endif
    }

    /// Idempotent: safe to call from every place that might be the first to need
    /// cloud rows.
    func startIfNeeded() {
        // The note goes AFTER the guard on purpose: `rebuildIfReady` calls this on
        // every ~2s presence tick, so noting before the guard meant a main-thread
        // atomic file write every two seconds, forever, feature on or off.
        guard timer == nil else { return }
        note("startIfNeeded called")
        os_log("cloud: live model started (interval=%{public}.0fs)", log: liveLog, type: .info, interval)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.catalog.refresh()
            self.inFlight = false
            // Copy the state across on every refresh, not only when rows change —
            // a transition from ok to expired with an unchanged (empty) row list is
            // exactly the case the status line must catch.
            self.state = self.catalog.state
            let mapped = ClaudeCloudHUDRowMapper.rows(from: self.catalog.sessions)
            let changed = mapped != self.rows
            if changed {
                self.rows = mapped
                self.version &+= 1
                NotificationCenter.default.post(name: Self.rowsDidChange, object: nil)
            }
            self.note("refresh done", extra: [
                "sessions": self.catalog.sessions.count,
                "mapped": mapped.count,
                "changed": changed
            ])
        }
    }
}
