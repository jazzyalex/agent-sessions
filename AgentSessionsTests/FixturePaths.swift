import Foundation

enum FixturePaths {
    static func repoRootURL(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        let fm = FileManager.default

        func hasMarker(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent("AgentSessions.xcodeproj").path) ||
                fm.fileExists(atPath: dir.appendingPathComponent(".git").path)
        }

        while url.path != "/" {
            if hasMarker(url) { return url }
            url = url.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static func stage0FixtureURL(_ relativePath: String, file: StaticString = #filePath) -> URL {
        repoRootURL(file: file)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("stage0", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
    }
}

