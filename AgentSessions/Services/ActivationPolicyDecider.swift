import AppKit

enum ActivationPolicyDecider {
    static func policy(
        hideDockIcon: Bool,
        menuBarEnabled: Bool,
        pinnedCockpitAvailable: Bool = false
    ) -> NSApplication.ActivationPolicy {
        hideDockIcon && (menuBarEnabled || pinnedCockpitAvailable) ? .accessory : .regular
    }
}

enum DockIconPreferenceController {
    static func isMenuBarEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: PreferencesKey.menuBarEnabled) as? Bool ?? false
    }

    static func isDockIconHidden(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: PreferencesKey.Advanced.hideDockIcon) as? Bool ?? false
    }

    /// A pinned floating window keeps the app reachable only while the Quota Meter is the
    /// floating window; in strip placement the stored pin is not shown anywhere.
    static func isPinnedCockpitAvailable(defaults: UserDefaults = .standard) -> Bool {
        let liveSessionsEnabled = defaults.object(forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled) as? Bool ?? true
        let pinnedCockpit = defaults.object(forKey: PreferencesKey.Cockpit.hudPinned) as? Bool ?? false
        let floatingDecision = defaults.string(forKey: QuotaMeterPresentationCoordinator.decisionKey) != "strip"
        return liveSessionsEnabled && pinnedCockpit && floatingDecision
    }

    static func hasDockHiddenReachability(defaults: UserDefaults = .standard) -> Bool {
        isMenuBarEnabled(defaults: defaults) || isPinnedCockpitAvailable(defaults: defaults)
    }

    static func dockIconMenuTitle(defaults: UserDefaults = .standard) -> String {
        isDockIconHidden(defaults: defaults) ? "Show Dock Icon" : "Hide Dock Icon"
    }

    /// `MenuBarEnabled` means "the menu bar strip is on screen" and only the Quota Meter
    /// placement coordinator writes it. Hiding the Dock icon without that or a pinned window
    /// requests the menu bar placement; the Dock icon actually hides once the coordinator has
    /// presented the strip and published `MenuBarEnabled = true`.
    static func setDockIconHidden(_ hidden: Bool, defaults: UserDefaults = .standard) {
        if hidden, !hasDockHiddenReachability(defaults: defaults) {
            defaults.set(QuotaMeterPlacement.menuBar.rawValue, forKey: PreferencesKey.quotaMeterPlacement)
            defaults.set(false, forKey: PreferencesKey.quotaMeterStripHidden)
        }
        defaults.set(hidden, forKey: PreferencesKey.Advanced.hideDockIcon)
    }

    static func setMenuBarEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: PreferencesKey.menuBarEnabled)
        if !enabled, !isPinnedCockpitAvailable(defaults: defaults) {
            defaults.set(false, forKey: PreferencesKey.Advanced.hideDockIcon)
        }
    }

    static func reconcileReachability(defaults: UserDefaults = .standard) {
        if !hasDockHiddenReachability(defaults: defaults), isDockIconHidden(defaults: defaults) {
            defaults.set(false, forKey: PreferencesKey.Advanced.hideDockIcon)
        }
    }

    @discardableResult
    static func toggleDockIconHidden(defaults: UserDefaults = .standard) -> Bool {
        let nextValue = !isDockIconHidden(defaults: defaults)
        setDockIconHidden(nextValue, defaults: defaults)
        return nextValue
    }
}

enum DockRecentAppCleaner {
    static func removingApp(
        from recentApps: [Any],
        bundleIdentifier: String?,
        bundleURL: URL?
    ) -> [Any] {
        recentApps.filter { item in
            !matchesApp(item, bundleIdentifier: bundleIdentifier, bundleURL: bundleURL)
        }
    }

    @discardableResult
    static func removeCurrentAppIfPresent(
        bundle: Bundle = .main,
        dockDefaults: UserDefaults? = UserDefaults(suiteName: "com.apple.dock"),
        restartDock: () -> Void = restartDock
    ) -> Bool {
        guard let dockDefaults,
              let recentApps = dockDefaults.array(forKey: "recent-apps") else {
            return false
        }

        let cleaned = removingApp(
            from: recentApps,
            bundleIdentifier: bundle.bundleIdentifier,
            bundleURL: bundle.bundleURL
        )
        guard cleaned.count != recentApps.count else { return false }

        dockDefaults.set(cleaned, forKey: "recent-apps")
        dockDefaults.synchronize()
        restartDock()
        return true
    }

    private static func matchesApp(
        _ item: Any,
        bundleIdentifier: String?,
        bundleURL: URL?
    ) -> Bool {
        guard let tileData = (item as? [String: Any])?["tile-data"] as? [String: Any] else {
            return false
        }

        if let bundleIdentifier,
           tileData["bundle-identifier"] as? String == bundleIdentifier {
            return true
        }

        guard let bundleURL else { return false }
        let fileData = tileData["file-data"] as? [String: Any]
        return fileData?["_CFURLString"] as? String == bundleURL.absoluteString
    }

    private static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
