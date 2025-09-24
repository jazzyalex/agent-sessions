import XCTest
@testable import AgentSessions

@MainActor
final class CodexResumeTests: XCTestCase {
    func testVersionParsingHandlesTypicalOutput() {
        let version = CodexVersion.parse(from: "codex 0.40.1")
        switch version {
        case let .semantic(major, minor, patch):
            XCTAssertEqual(major, 0)
            XCTAssertEqual(minor, 40)
            XCTAssertEqual(patch, 1)
        default:
            XCTFail("Expected semantic version")
        }
        XCTAssertTrue(version.supportsResumeByID)
    }

    func testVersionParsingUnknown() {
        let version = CodexVersion.parse(from: "codex dev-build")
        switch version {
        case .unknown:
            XCTAssertFalse(version.supportsResumeByID)
        default:
            XCTFail("Expected unknown version")
        }
    }

    func testCommandBuilderProducesResumeCommand() throws {
        let session = sampleSession(id: "abc123", fileName: "rollout-2025-09-22T10-11-12-abc123.jsonl", cwd: "/tmp/project")
        let defaults = UserDefaults(suiteName: "CodexResumeTestsCommand")!
        defaults.removePersistentDomain(forName: "CodexResumeTestsCommand")
        let settings = CodexResumeSettings.makeForTesting(defaults: defaults)
        settings.setDefaultWorkingDirectory("/tmp/fallback")
        let binaryURL = URL(fileURLWithPath: "/usr/local/bin/codex")
        let builder = CodexResumeCommandBuilder()
        let package = try builder.makeCommand(for: session,
                                              settings: settings,
                                              binaryURL: binaryURL,
                                              fallbackPath: nil,
                                              attemptResumeFirst: true)
        XCTAssertEqual(package.displayCommand, "'/usr/local/bin/codex' resume 'abc123'")
        XCTAssertEqual(package.workingDirectory?.path, "/tmp/project")
        XCTAssertTrue(package.shellCommand.contains("cd '/tmp/project'"))
        XCTAssertTrue(package.shellCommand.contains("resume 'abc123'"))
    }

    func testCommandBuilderUsesFallbackWhenProvided() throws {
        let session = sampleSession(id: "def456", fileName: "rollout-2025-09-22T10-11-12-def456.jsonl", cwd: nil)
        let defaults = UserDefaults(suiteName: "CodexResumeTestsFallback")!
        defaults.removePersistentDomain(forName: "CodexResumeTestsFallback")
        let settings = CodexResumeSettings.makeForTesting(defaults: defaults)
        settings.setDefaultWorkingDirectory("/tmp/work")
        let binaryURL = URL(fileURLWithPath: "/opt/codex")
        let builder = CodexResumeCommandBuilder()
        let fallback = URL(fileURLWithPath: "/logs/session.jsonl")
        let package = try builder.makeCommand(for: session,
                                              settings: settings,
                                              binaryURL: binaryURL,
                                              fallbackPath: fallback,
                                              attemptResumeFirst: false)
        XCTAssertEqual(package.displayCommand, "'/opt/codex' -c experimental_resume='/logs/session.jsonl'")
        XCTAssertEqual(package.shellCommand, "'/opt/codex' -c experimental_resume='/logs/session.jsonl'")
        XCTAssertNil(package.workingDirectory)
    }

    func testCommandBuilderCombinesResumeAndFallback() throws {
        let session = sampleSession(id: "ghi789", fileName: "rollout-2025-09-22T10-11-12-ghi789.jsonl", cwd: "/projects/repo")
        let defaults = UserDefaults(suiteName: "CodexResumeTestsCombo")!
        defaults.removePersistentDomain(forName: "CodexResumeTestsCombo")
        let settings = CodexResumeSettings.makeForTesting(defaults: defaults)
        let binaryURL = URL(fileURLWithPath: "/usr/bin/codex")
        let builder = CodexResumeCommandBuilder()
        let fallback = URL(fileURLWithPath: "/tmp/session.jsonl")
        let package = try builder.makeCommand(for: session,
                                              settings: settings,
                                              binaryURL: binaryURL,
                                              fallbackPath: fallback,
                                              attemptResumeFirst: true)

        XCTAssertTrue(package.displayCommand.contains("resume 'ghi789'"))
        XCTAssertTrue(package.displayCommand.contains("experimental_resume='/tmp/session.jsonl'"))
        XCTAssertFalse(package.displayCommand.contains("experimental_resume='/tmp/session.jsonl' resume"))
        XCTAssertTrue(package.shellCommand.contains("||"))
    }

    // MARK: Helpers

    private func sampleSession(id: String, fileName: String, cwd: String?) -> Session {
        let event: SessionEvent
        if let cwd {
            let raw = "{\\\"cwd\\\":\\\"\(cwd)\\\"}"
            event = SessionEvent(id: "evt-\(id)", timestamp: nil, kind: .meta, role: nil, text: nil, toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: raw)
        } else {
            event = SessionEvent(id: "evt-\(id)", timestamp: nil, kind: .meta, role: nil, text: nil, toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
        }
        let events: [SessionEvent] = [event]
        return Session(id: id,
                       startTime: nil,
                       endTime: nil,
                       model: nil,
                       filePath: "/tmp/\(fileName)",
                       eventCount: events.count,
                       events: events)
    }
}
