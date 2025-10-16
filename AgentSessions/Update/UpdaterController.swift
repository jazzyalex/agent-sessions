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

    // MARK: - Published State

    /// Indicates whether a gentle reminder should be shown (update available but app was in background).
    /// Use this to display a subtle indicator (badge, menu bar dot) without stealing focus.
    @Published var hasGentleReminder: Bool = false

    // MARK: - Private Properties

    private let controller: SPUStandardUpdaterController

    // MARK: - Initialization

    override init() {
        // Initialize Sparkle controller with delegates set to nil initially
        // (we'll set them after super.init() to avoid escaping self)
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        super.init()

        // Now that self is fully initialized, set delegates
        controller.updater.delegate = self
        if let userDriver = controller.updater.userDriver as? SPUStandardUserDriver {
            userDriver.delegate = self
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
        controller.checkForUpdates(sender)
    }

    // MARK: - SPUStandardUserDriverDelegate (Gentle Reminders)

    /// Enables gentle reminder support for menu bar apps.
    /// When true, Sparkle won't show update alerts immediately during background checks.
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    /// Called when Sparkle finds an update during a scheduled check.
    /// Returns whether Sparkle should immediately show its standard UI.
    ///
    /// - Parameters:
    ///   - update: The available update
    ///   - immediateFocus: Whether the app is currently in focus
    /// - Returns: true to show Sparkle UI immediately, false to defer to gentle reminder
    func standardUserDriverShouldHandleShowingScheduledUpdate(
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
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
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

    /// Called when the user focuses the updater (clicks menu item or badge).
    /// Clear the gentle reminder since Sparkle will now show its UI.
    ///
    /// - Parameter update: The available update
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        hasGentleReminder = false
    }

    /// Called when the update session finishes (user installed, skipped, or dismissed).
    /// Clear the gentle reminder.
    func standardUserDriverWillFinishUpdateSession() {
        hasGentleReminder = false
    }

    // MARK: - SPUUpdaterDelegate (Optional Customization)

    /// Called before Sparkle checks for updates.
    /// Useful for logging or analytics.
    func updaterWillCheckForUpdates(_ updater: SPUUpdater) {
        print("Sparkle: Checking for updates...")
    }

    /// Called after Sparkle finishes checking for updates.
    ///
    /// - Parameters:
    ///   - updater: The updater
    ///   - error: Error if check failed, nil if successful
    func updaterDidFinishCheckingForUpdates(_ updater: SPUUpdater, error: Error?) {
        if let error = error {
            print("Sparkle: Update check failed - \(error.localizedDescription)")
        } else {
            print("Sparkle: Update check completed")
        }
    }

    /// Called when Sparkle finds a valid update.
    ///
    /// - Parameters:
    ///   - updater: The updater
    ///   - item: The update item
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("Sparkle: Update available - \(item.displayVersionString)")
    }

    /// Called when Sparkle determines the user is on the latest version.
    ///
    /// - Parameter updater: The updater
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        print("Sparkle: Already up to date")
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
