import XCTest
import Darwin
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

    func testBinaryPathForCopyCommandUsesCachedResolvedBinaryInAutoMode() {
        let defaults = UserDefaults(suiteName: "CursorSettingsTests")!
        defaults.removePersistentDomain(forName: "CursorSettingsTests")
        let settings = CursorSettings.makeForTesting(defaults: defaults)
        let binaryPath = makeTempExecutable(name: "cursor-settings-agent")

        settings.setResolvedBinary(binaryPath, supportsResume: true, supportsContinue: true)

        XCTAssertEqual(settings.binaryPathForCopyCommand(), binaryPath)
    }

    func testBinaryPathForCopyCommandPrefersCustomBinary() {
        let defaults = UserDefaults(suiteName: "CursorSettingsTests")!
        defaults.removePersistentDomain(forName: "CursorSettingsTests")
        let settings = CursorSettings.makeForTesting(defaults: defaults)
        let binaryPath = makeTempExecutable(name: "cursor-settings-agent")

        settings.setResolvedBinary(binaryPath, supportsResume: true, supportsContinue: true)
        settings.setBinaryPath("/opt/homebrew/bin/agent")

        XCTAssertEqual(settings.binaryPathForCopyCommand(), "/opt/homebrew/bin/agent")
    }

    func testClearingCustomBinaryDropsCachedResolvedBinary() {
        let defaults = UserDefaults(suiteName: "CursorSettingsTests")!
        defaults.removePersistentDomain(forName: "CursorSettingsTests")
        let settings = CursorSettings.makeForTesting(defaults: defaults)

        settings.setResolvedBinaryPath("/old/custom/agent")
        settings.setBinaryPath("")

        XCTAssertEqual(settings.resolvedBinaryPath, "")
        XCTAssertEqual(settings.binaryPathForCopyCommand(), "agent")
    }

    func testCopyCommandPlanFallsBackToContinueForContinueOnlyCachedBinary() {
        let defaults = UserDefaults(suiteName: "CursorSettingsTests")!
        defaults.removePersistentDomain(forName: "CursorSettingsTests")
        let settings = CursorSettings.makeForTesting(defaults: defaults)
        let binaryPath = makeTempExecutable(name: "cursor-settings-continue-only")

        settings.setResolvedBinary(binaryPath, supportsResume: false, supportsContinue: true)

        let plan = settings.copyCommandPlan(sessionID: "chat-123")

        XCTAssertEqual(plan.binary, binaryPath)
        if case .continueMostRecent = plan.strategy {
        } else {
            XCTFail("expected continueMostRecent")
        }
    }

    func testCopyCommandPlanClearsStaleCachedBinary() {
        let defaults = UserDefaults(suiteName: "CursorSettingsTests")!
        defaults.removePersistentDomain(forName: "CursorSettingsTests")
        let settings = CursorSettings.makeForTesting(defaults: defaults)

        settings.setResolvedBinary("/tmp/missing-cursor-agent-\(UUID().uuidString)", supportsResume: true, supportsContinue: true)

        let plan = settings.copyCommandPlan(sessionID: "chat-123")

        XCTAssertEqual(plan.binary, "agent")
        XCTAssertEqual(settings.resolvedBinaryPath, "")
    }

    private func makeTempExecutable(name: String) -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let file = dir.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        _ = chmod(file.path, 0o755)
        return file.path
    }
}
