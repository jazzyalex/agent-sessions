import Cocoa
import Sparkle

/// Manages Sparkle 2 automatic updates with gentle reminder support for menu bar apps.
///
/// This controller wraps SPUStandardUpdaterController and implements delegates to provide
/// non-intrusive update notifications that don't steal focus from the user's current work.
///
/// **Usage**:
/// ```swift
/// @StateObject private var updaterController = UpdaterController()
///
/// // In menu:
/// Button("Check for Updates…", action: updaterController.checkForUpdates)
///
/// // Optional: Show badge when update available
/// if updaterController.hasGentleReminder {
///     // Display indicator on menu bar
/// }
/// ```
@MainActor
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    // MARK: - Shared Instance

    /// Shared instance for app-wide access (set by App during initialization)
    static weak var shared: UpdaterController?

    // MARK: - Published State

    /// Indicates whether a gentle reminder should be shown (update available but app was in background).
    /// Use this to display a subtle indicator (badge, menu bar dot) without stealing focus.
    @Published var hasGentleReminder: Bool = false

    // MARK: - Private Properties

    private var controller: SPUStandardUpdaterController!

    // MARK: - Initialization

    override init() {
        super.init()

        // Initialize Sparkle controller with self as delegates
        // Use startingUpdater: false to avoid early initialization errors
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        // Delay starting the updater to avoid launch errors
        // This makes the updater ready for manual checks while avoiding early errors
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }

            // Start the updater (required when startingUpdater: false)
            do {
                try self.controller.updater.start()
                print("Updater started successfully")

                // Schedule background check after updater is started
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    self.controller.updater.checkForUpdatesInBackground()
                }
            } catch {
                print("Failed to start updater - \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Public API

    /// Exposes the underlying SPUUpdater for advanced use cases.
    var updater: SPUUpdater {
        controller.updater
    }

    /// Triggers a manual update check (ignores scheduled interval).
    /// Wired to "Check for Updates…" menu item.
    ///
    /// - Parameter sender: The menu item or button that triggered the action
    @objc func checkForUpdates(_ sender: Any?) {
        print("UpdaterController: Manual check for updates triggered")
        controller.checkForUpdates(sender)
    }

    // MARK: - SPUStandardUserDriverDelegate (Gentle Reminders)

    /// Enables gentle reminder support for menu bar apps.
    /// When true, Sparkle won't show update alerts immediately during background checks.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    /// Called when Sparkle finds an update during a scheduled check.
    /// Returns whether Sparkle should immediately show its standard UI.
    ///
    /// - Parameters:
    ///   - update: The available update
    ///   - immediateFocus: Whether the app is currently in focus
    /// - Returns: true to show Sparkle UI immediately, false to defer to gentle reminder
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Only show Sparkle UI immediately if the app is in immediate focus
        // Otherwise, we'll show a gentle reminder (badge/notification)
        return immediateFocus
    }

    /// Called to notify whether Sparkle will handle showing the update UI.
    /// If Sparkle won't show UI (background check), we activate our gentle reminder.
    ///
    /// - Parameters:
    ///   - handleShowingUpdate: Whether Sparkle will show its UI
    ///   - update: The available update
    ///   - state: Current update state
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            guard !handleShowingUpdate else {
                // Sparkle is showing UI, clear any gentle reminder
                hasGentleReminder = false
                return
            }

            // Sparkle is NOT showing UI (app was in background)
            // Activate gentle reminder so we can show a subtle indicator
            hasGentleReminder = true

            // Optional: Post a user notification
            // postUpdateNotification(for: update)
        }
    }

    /// Called when the user focuses the updater (clicks menu item or badge).
    /// Clear the gentle reminder since Sparkle will now show its UI.
    ///
    /// - Parameter update: The available update
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            hasGentleReminder = false
        }
    }

    /// Called when the update session finishes (user installed, skipped, or dismissed).
    /// Clear the gentle reminder.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            hasGentleReminder = false
        }
    }

    // MARK: - SPUUpdaterDelegate (Optional Customization)

    /// Called before updater checks for updates.
    /// Useful for logging or analytics.
    nonisolated func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool {
        print("Checking for updates...")
        return true
    }

    /// Called after updater finishes checking for updates.
    ///
    /// - Parameters:
    ///   - updater: The updater
    ///   - error: Error if check failed, nil if successful
    nonisolated func updaterDidFinishCheckingForUpdates(_ updater: SPUUpdater, error: Error?) {
        if let error = error {
            print("Update check failed - \(error.localizedDescription)")
        } else {
            print("Update check completed")
        }
    }

    /// Called when updater finds a valid update.
    ///
    /// - Parameters:
    ///   - updater: The updater
    ///   - item: The update item
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("Update available - \(item.displayVersionString)")
    }

    /// Called when updater determines the user is on the latest version.
    ///
    /// - Parameter updater: The updater
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        print("Already up to date")
    }

    // MARK: - Helper Methods (Optional)

    /// Posts a macOS user notification about the available update.
    /// Uncomment and customize if you want push notifications.
    ///
    /// - Parameter update: The available update
    /*
    private func postUpdateNotification(for update: SUAppcastItem) {
        let content = UNMutableNotificationContent()
        content.title = "Update Available"
        content.body = "Agent Sessions \(update.displayVersionString) is ready to install."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "sparkle-update-\(update.displayVersionString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to post update notification: \(error)")
            }
        }
    }
    */
}
