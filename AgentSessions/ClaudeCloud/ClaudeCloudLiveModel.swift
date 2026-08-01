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
final class ClaudeCloudLiveModel {

    static let shared = ClaudeCloudLiveModel()

    /// Mapped rows ready for the HUD. Empty whenever the feature is off, the cookie
    /// is missing, or the source is in a cleared failure state.
    private(set) var rows: [HUDRow] = []

    /// Bumped whenever `rows` changes, so the HUD's rebuild gate can notice.
    private(set) var version: UInt64 = 0

    var state: ClaudeCloudSourceState { catalog.state }

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

    /// Idempotent: safe to call from every place that might be the first to need
    /// cloud rows.
    func startIfNeeded() {
        guard timer == nil else { return }
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
            let mapped = ClaudeCloudHUDRowMapper.rows(from: self.catalog.sessions)
            guard mapped != self.rows else { return }
            self.rows = mapped
            self.version &+= 1
        }
    }
}
