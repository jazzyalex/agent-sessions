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
    /// Returns true exactly once per signed-out/expired episode; resets on ok/unknown.
    func shouldNotify(provider p: AuthProvider, state: UsageAuthState) -> Bool {
        let d = UserDefaults.standard
        switch state {
        case .signedOut, .expired, .cliNotInstalled:
            if d.bool(forKey: key(p)) { return false }   // already notified this episode
            d.set(true, forKey: key(p)); return true
        case .ok, .unknown, .needsSetup:
            d.set(false, forKey: key(p)); return false
        }
    }
    func reset(provider p: AuthProvider) { UserDefaults.standard.set(false, forKey: key(p)) }
}

final class AuthStatusNotifier {
    private let gate: NotificationGate
    private let store: AuthEpisodeStore
    init(gate: NotificationGate = SystemNotificationGate(), store: AuthEpisodeStore = AuthEpisodeStore()) {
        self.gate = gate; self.store = store
    }
    func onStatus(_ s: UsageAuthStatus, provider: AuthProvider) async {
        // `shouldNotify` is the sole gate: it returns true once per alarming
        // episode AND resets the episode on a non-alarming state. Do NOT pre-guard
        // on `isAlarming` — that would skip the reset for `.ok`/`.unknown`, so a
        // recovery followed by a new signed-out state could never re-notify.
        guard store.shouldNotify(provider: provider, state: s.state) else { return }
        guard await gate.isAuthorized() else { return }
        gate.post(title: s.headline, body: "Open Agent Sessions to see how to fix it.")
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
