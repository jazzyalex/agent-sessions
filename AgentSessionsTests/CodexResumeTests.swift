import XCTest
@testable import AgentSessions

@MainActor
final class CodexResumeTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled)
        super.tearDown()
    }

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
        UserDefaults.standard.set(false, forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled)

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
        XCTAssertTrue(package.shellCommand.hasPrefix("cd '/tmp/work' && "))
        XCTAssertTrue(package.shellCommand.contains("'/opt/codex' -c experimental_resume='/logs/session.jsonl'"))
        XCTAssertEqual(package.workingDirectory?.path, "/tmp/work")
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
        XCTAssertTrue(package.displayCommand.hasPrefix("'/usr/bin/codex' resume 'ghi789' || "))
        XCTAssertTrue(package.shellCommand.contains("||"))
    }

    func testCommandBuilderPrefersInternalSessionID() throws {
        // Build a session whose JSONL contains a different internal session_id
        let defaults = UserDefaults(suiteName: "CodexResumeTestsInternalID")!
        defaults.removePersistentDomain(forName: "CodexResumeTestsInternalID")
        let settings = CodexResumeSettings.makeForTesting(defaults: defaults)
        let binaryURL = URL(fileURLWithPath: "/usr/bin/codex")
        let builder = CodexResumeCommandBuilder()

        // Create an event with an internal session_id
        let raw = "{\"session_id\":\"internal-xyz\"}"
        let event = SessionEvent(id: "evt-1", timestamp: nil, kind: .meta, role: nil, text: nil, toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: raw)
        let session = Session(id: "s1",
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: "/tmp/rollout-2025-09-22T10-11-12-ghi789.jsonl",
                              eventCount: 1,
                              events: [event])

        let fallback = URL(fileURLWithPath: "/tmp/session.jsonl")
        let package = try builder.makeCommand(for: session,
                                              settings: settings,
                                              binaryURL: binaryURL,
                                              fallbackPath: fallback,
                                              attemptResumeFirst: true)
        XCTAssertTrue(package.displayCommand.contains("resume 'internal-xyz'"))
    }

    func testCommandBuilderDoesNotCoupleResumeCommandToCockpitPresence() throws {
        UserDefaults.standard.set(true, forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled)

        let session = sampleSession(id: "active-123", fileName: "rollout-2025-09-22T10-11-12-active-123.jsonl", cwd: "/tmp/project")
        let defaults = UserDefaults(suiteName: "CodexResumeTestsActivePresence")!
        defaults.removePersistentDomain(forName: "CodexResumeTestsActivePresence")
        let settings = CodexResumeSettings.makeForTesting(defaults: defaults)
        let binaryURL = URL(fileURLWithPath: "/usr/local/bin/codex")
        let builder = CodexResumeCommandBuilder()

        let package = try builder.makeCommand(for: session,
                                              settings: settings,
                                              binaryURL: binaryURL,
                                              fallbackPath: nil,
                                              attemptResumeFirst: true)

        XCTAssertEqual(package.shellCommand, "cd '/tmp/project' && '/usr/local/bin/codex' resume 'active-123'")
        XCTAssertFalse(package.shellCommand.contains("/bin/zsh "))
        XCTAssertFalse(package.shellCommand.contains("write_presence(){"))
    }

    func testCommandBuilderRejectsVSCodeSurfaceForCLIResume() throws {
        let session = Session(id: "vscode-123",
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: "/tmp/rollout-2025-09-22T10-11-12-vscode-123.jsonl",
                              eventCount: 0,
                              events: [],
                              codexInternalSessionIDHint: "vscode-123",
                              codexOriginator: "codex_vscode",
                              codexSource: "vscode",
                              codexSurface: .vscode)
        let defaults = UserDefaults(suiteName: "CodexResumeTestsVSCodeSurface")!
        defaults.removePersistentDomain(forName: "CodexResumeTestsVSCodeSurface")
        let settings = CodexResumeSettings.makeForTesting(defaults: defaults)

        XCTAssertThrowsError(try CodexResumeCommandBuilder().makeCommand(for: session,
                                                                         settings: settings,
                                                                         binaryURL: URL(fileURLWithPath: "/usr/local/bin/codex"),
                                                                         fallbackPath: nil,
                                                                         attemptResumeFirst: true)) { error in
            guard case CodexResumeCommandBuilder.BuildError.unsupportedSurface(.vscode) = error else {
                XCTFail("Expected unsupported VS Code surface error, got \(error)")
                return
            }
        }
    }

    // MARK: Helpers

    private func sampleSession(id: String, fileName: String, cwd: String?) -> Session {
        let event: SessionEvent
        if let cwd {
            let raw = #"{"session_id":"\#(id)","cwd":"\#(cwd)"}"#
            event = SessionEvent(id: "evt-\(id)", timestamp: nil, kind: .meta, role: nil, text: nil, toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: raw)
        } else {
            let raw = #"{"session_id":"\#(id)"}"#
            event = SessionEvent(id: "evt-\(id)", timestamp: nil, kind: .meta, role: nil, text: nil, toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: raw)
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
