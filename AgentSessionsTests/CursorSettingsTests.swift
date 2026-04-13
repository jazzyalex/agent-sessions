import XCTest
@testable import AgentSessions

@MainActor
final class CursorSettingsTests: XCTestCase {
    func testEffectiveWorkingDirectoryFallsBackToBestEffortFromFilePath() {
        let defaults = UserDefaults(suiteName: "CursorSettingsTests")!
        defaults.removePersistentDomain(forName: "CursorSettingsTests")
        let settings = CursorSettings.makeForTesting(defaults: defaults)

        let filePath = "/Users/alex/.cursor/projects/Users-alexm-Repository-My-Repo/agent-transcripts/123/123.jsonl"
        let session = Session(id: "123",
                              source: .cursor,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: filePath,
                              fileSizeBytes: nil,
                              eventCount: 0,
                              events: [],
                              cwd: nil,
                              repoName: nil,
                              lightweightTitle: nil)

        let wd = settings.effectiveWorkingDirectory(for: session)
        XCTAssertEqual(wd?.path, "/Users/alexm/Repository/My-Repo")
    }
}
