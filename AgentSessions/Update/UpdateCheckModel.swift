import Foundation
import SwiftUI
import AppKit

@MainActor
final class UpdateCheckModel: ObservableObject {
    static let shared = UpdateCheckModel()

    @Published var state: UpdateState = .idle

    private var checker: UpdateChecker?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Check for updates on app launch (respects 24h cadence)
    func checkOnLaunch() {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            state = .error("Unable to determine app version")
            return
        }

        let client = GitHubHTTPClient()
        let checker = UpdateChecker(client: client,
                                    defaults: defaults,
                                    currentVersion: currentVersion) { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
            }
        }
        self.checker = checker

        Task {
            await checker.checkForUpdates(force: false)
        }
    }

    /// Manually check for updates (ignores 24h cadence)
    func checkManually() {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            state = .error("Unable to determine app version")
            return
        }

        let client = GitHubHTTPClient()
        let checker = UpdateChecker(client: client,
                                    defaults: defaults,
                                    currentVersion: currentVersion) { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
                // Show alert if up to date when manually checking
                if case .upToDate = newState {
                    self?.showUpToDateNSAlert()
                }
            }
        }
        self.checker = checker

        Task {
            await checker.checkForUpdates(force: true)
        }
    }

    private func showUpToDateNSAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "You have the latest version installed."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        // Set app icon without white background
        if let appIcon = NSApp.applicationIconImage {
            alert.icon = appIcon
        }

        alert.runModal()
    }

    /// Skip launch dialog for a specific version (but still allow manual checks)
    func skipVersionForLaunchOnly(_ version: String) {
        Task {
            await checker?.skipVersion(version)
            // Keep state as available so "Check for Updates" still shows it
        }
    }

    /// Open URL in default browser
    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
