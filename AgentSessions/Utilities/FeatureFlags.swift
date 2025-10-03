import Foundation

enum FeatureFlags {
    // Keep legacy Codex/Claude standalone windows for one release only.
    // Default OFF: UI routes to Unified window instead.
    static let legacyWindows: Bool = false
}

