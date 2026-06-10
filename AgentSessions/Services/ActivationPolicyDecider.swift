import AppKit

enum ActivationPolicyDecider {
    static func policy(hideDockIcon: Bool, menuBarEnabled: Bool) -> NSApplication.ActivationPolicy {
        hideDockIcon && menuBarEnabled ? .accessory : .regular
    }
}

enum DockIconPreferenceController {
    static func isDockIconHidden(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: PreferencesKey.Advanced.hideDockIcon) as? Bool ?? false
    }

    static func dockIconMenuTitle(defaults: UserDefaults = .standard) -> String {
        isDockIconHidden(defaults: defaults) ? "Show Dock Icon" : "Hide Dock Icon"
    }

    static func setDockIconHidden(_ hidden: Bool, defaults: UserDefaults = .standard) {
        if hidden {
            defaults.set(true, forKey: PreferencesKey.menuBarEnabled)
        }
        defaults.set(hidden, forKey: PreferencesKey.Advanced.hideDockIcon)
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
