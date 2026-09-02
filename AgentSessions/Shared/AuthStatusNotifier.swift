import Foundation
import UserNotifications

/// Task 10: permission-gated one-shot signed-out/expired/CLI-missing notifier.
///
/// Design constraints (see `.superpowers/sdd/task-10-brief.md`):
/// - Never calls `requestAuthorization` — only checks whether notifications are
///   already authorized (`SystemNotificationGate.isAuthorized`). If the user
///   hasn't granted the app notification permission through the normal macOS
///   flow, this stays completely silent.
/// - Fires at most once per "episode" of an alarming auth state per provider.
///   `signedOut` and `expired` share one episode (re-polling a still-broken
///   auth state doesn't re-notify); recovering to `.ok`/`.unknown`/`.needsSetup`
///   resets the episode so a *later* alarming state notifies again.
protocol NotificationGate { func isAuthorized() async -> Bool; func post(title: String, body: String) }

/// Real gate: checks getNotificationSettings and NEVER calls requestAuthorization.
struct SystemNotificationGate: NotificationGate {
    func isAuthorized() async -> Bool {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings { cont.resume(returning: $0.authorizationStatus == .authorized) }
        }
    }
    func post(title: String, body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

final class AuthEpisodeStore {
    private func key(_ p: AuthProvider) -> String { p == .claude ? "AuthEpisode.claude" : "AuthEpisode.codex" }
    /// Returns true exactly once per signed-out/expired episode; resets ONLY on
    /// a definite recovery (`.ok`). `.unknown` and `.needsSetup` are ambiguous —
    /// they neither notify nor touch the episode flag, so a transient
    /// `signedOut -> unknown -> signedOut` blip can't slip past the one-shot
    /// gate and double-notify.
    func shouldNotify(provider p: AuthProvider, state: UsageAuthState) -> Bool {
        let d = UserDefaults.standard
        switch state {
        case .signedOut, .expired, .accountUnavailable, .cliNotInstalled:
            if d.bool(forKey: key(p)) { return false }   // already notified this episode
            d.set(true, forKey: key(p)); return true
        case .ok:
            d.set(false, forKey: key(p)); return false   // only a definite recovery resets the episode
        case .unknown, .needsSetup, .idle:
            return false                                  // ambiguous/calm: neither notify nor reset
        }
    }
    func reset(provider p: AuthProvider) { UserDefaults.standard.set(false, forKey: key(p)) }
}

actor AuthStatusNotifier {
    private let gate: NotificationGate
    private let store: AuthEpisodeStore
    private var notificationChecksInFlight: Set<String> = []
    private var latestStatus: [String: UsageAuthStatus] = [:]

    private func providerKey(_ provider: AuthProvider) -> String {
        provider == .claude ? "claude" : "codex"
    }
    init(gate: NotificationGate = SystemNotificationGate(), store: AuthEpisodeStore = AuthEpisodeStore()) {
        self.gate = gate; self.store = store
    }
    func onStatus(_ s: UsageAuthStatus, provider: AuthProvider) async {
        let key = providerKey(provider)
        latestStatus[key] = s
        // Order matters: for an alarming state, the episode must be consumed
        // (via `shouldNotify`, which flips the "already notified" flag) ONLY
        // once we know a notification will actually be posted. Otherwise an
        // un-authorized run would burn the episode silently, and a later
        // permission grant during the SAME signed-out episode would never fire.
        //
        // Non-alarming states still need to reach `shouldNotify` unconditionally
        // (skipping the auth check) so `.ok` can reset the episode even when
        // notifications aren't authorized — the reset must not depend on
        // notification permission.
        guard s.state.isAlarming else {
            _ = store.shouldNotify(provider: provider, state: s.state)
            return
        }
        // Actor methods are reentrant across the authorization await. Keep one
        // check in flight per provider so two simultaneous publications cannot
        // both observe the UserDefaults episode flag before either claims it.
        guard notificationChecksInFlight.insert(key).inserted else { return }
        defer { notificationChecksInFlight.remove(key) }
        guard await gate.isAuthorized() else { return }
        // Recovery may have arrived while notification authorization was being
        // checked. Never post a stale auth alert after a definite recovery.
        // Another alarming verdict may have replaced the original one while
        // notification permission was being checked. Post the newest status,
        // not a stale headline, and consume the shared episode for that verdict.
        guard let current = latestStatus[key], current.state.isAlarming else { return }
        guard store.shouldNotify(provider: provider, state: current.state) else { return }
        gate.post(title: current.headline, body: "Open Agent Sessions to see how to fix it.")
    }
}

// MARK: - Shared instance

/// One process-wide notifier instance shared by both usage models so the two
/// providers' episodes are tracked through the same `AuthEpisodeStore`/gate
/// wiring. Exposed on both `CodexUsageModel` and `ClaudeUsageModel` as
/// `Self.authNotifier` (see extensions in their respective files) pointing at
/// this single instance.
extension AuthStatusNotifier {
    static let shared = AuthStatusNotifier()
}
