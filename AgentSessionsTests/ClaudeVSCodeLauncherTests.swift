import XCTest
@testable import AgentSessions

@MainActor
final class ClaudeVSCodeLauncherTests: XCTestCase {

    private let sessionID = "c1b5bf2b-1002-4afa-aebc-1b133c4facb1"

    // MARK: - Link

    func testSessionURLUsesExtensionOpenHandler() {
        let url = ClaudeVSCodeLauncher.sessionURL(sessionID: sessionID, scheme: "vscode")
        XCTAssertEqual(url?.absoluteString, "vscode://anthropic.claude-code/open?session=\(sessionID)")
    }

    func testSessionURLForInsidersUsesItsScheme() {
        let url = ClaudeVSCodeLauncher.sessionURL(sessionID: sessionID, scheme: "vscode-insiders")
        XCTAssertEqual(url?.absoluteString, "vscode-insiders://anthropic.claude-code/open?session=\(sessionID)")
    }

    // MARK: - Request validation

    func testMakeRequestRejectsMissingSessionID() {
        let folder = makeTemporaryDirectory()
        guard case .invalid = ClaudeVSCodeLauncher.makeRequest(sessionID: nil, workingDirectory: folder) else {
            return XCTFail("A missing session ID must not produce a request")
        }
    }

    func testMakeRequestRejectsNonUUIDSessionID() {
        // Agent Sessions' own row key is a SHA-256 hex string, not a Claude session ID.
        let folder = makeTemporaryDirectory()
        let hash = "864234886659c7cf81ec8093ab9beefc30ad306fbd1ea35f1d7d29b439b8d75a"
        guard case .invalid = ClaudeVSCodeLauncher.makeRequest(sessionID: hash, workingDirectory: folder) else {
            return XCTFail("Only a UUID is a Claude session ID")
        }
    }

    func testMakeRequestRejectsMissingWorkingDirectory() {
        guard case .invalid = ClaudeVSCodeLauncher.makeRequest(sessionID: sessionID, workingDirectory: nil) else {
            return XCTFail("A missing folder must not produce a request")
        }
    }

    func testMakeRequestAcceptsExistingFolder() {
        let folder = makeTemporaryDirectory()
        XCTAssertEqual(ClaudeVSCodeLauncher.makeRequest(sessionID: sessionID, workingDirectory: folder),
                       .ready(.init(sessionID: sessionID, folder: folder)))
    }

    func testMakeRequestRejectsFolderMissingOnThisMac() {
        // A Claude Desktop SSH session records the remote host's folder.
        let remote = URL(fileURLWithPath: "/home/someone-\(UUID().uuidString)")
        guard case .invalid(let message) = ClaudeVSCodeLauncher.makeRequest(sessionID: sessionID, workingDirectory: remote) else {
            return XCTFail("A folder that doesn't exist must not produce a request")
        }
        XCTAssertTrue(message.contains(remote.path))
    }

    func testMakeRequestFallsBackToRepositoryRootForRemovedWorktree() {
        let repo = makeTemporaryDirectory()
        let removedWorktree = repo.appendingPathComponent(".claude/worktrees/amazing-lamport-75adc4")
        guard case .ready(let request) = ClaudeVSCodeLauncher.makeRequest(sessionID: sessionID, workingDirectory: removedWorktree) else {
            return XCTFail("A removed worktree should fall back to its repository root")
        }
        XCTAssertEqual(request.folder.standardizedFileURL.path, repo.standardizedFileURL.path)
    }

    func testWorktreeRepositoryRootIgnoresOtherPaths() {
        XCTAssertNil(ClaudeVSCodeLauncher.worktreeRepositoryRoot(for: URL(fileURLWithPath: "/Users/me/project")))
        XCTAssertNil(ClaudeVSCodeLauncher.worktreeRepositoryRoot(for: URL(fileURLWithPath: "/.claude/worktrees/x")))
    }

    // MARK: - Launch sequence

    func testOpenFailsWhenNoEditorIsInstalled() async {
        let workspace = FakeWorkspace(installed: [])
        let outcome = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: makeTemporaryDirectory(), workspace: workspace)
        guard case .failure = outcome else { return XCTFail("Expected a failure without VS Code") }
        XCTAssertTrue(workspace.calls.isEmpty, "Nothing may launch without an editor")
    }

    func testOpenWithRunningEditorOpensFolderThenWaitsThenSendsLink() async {
        let folder = makeTemporaryDirectory()
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCode"], running: ["com.microsoft.VSCode"])
        let outcome = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: folder, workspace: workspace)
        XCTAssertEqual(outcome, .launched)
        XCTAssertEqual(workspace.calls, [
            .openFolder(folder.path),
            .pause(ClaudeVSCodeLauncher.warmStartDelay),
            .openURL("vscode://anthropic.claude-code/open?session=\(sessionID)"),
        ])
    }

    func testOpenWithStoppedEditorWaitsLonger() async {
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCode"], running: [])
        _ = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: makeTemporaryDirectory(), workspace: workspace)
        XCTAssertTrue(workspace.calls.contains(.pause(ClaudeVSCodeLauncher.coldStartDelay)))
    }

    func testOpenFallsBackToInsiders() async {
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCodeInsiders"], running: ["com.microsoft.VSCodeInsiders"])
        _ = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: makeTemporaryDirectory(), workspace: workspace)
        XCTAssertEqual(workspace.calls.last, .openURL("vscode-insiders://anthropic.claude-code/open?session=\(sessionID)"))
    }

    func testOpenDoesNotSendLinkWhenFolderFailsToOpen() async {
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCode"], running: ["com.microsoft.VSCode"], folderOpenFails: true)
        let outcome = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: makeTemporaryDirectory(), workspace: workspace)
        guard case .failure = outcome else { return XCTFail("Expected a failure when the folder can't open") }
        XCTAssertFalse(workspace.calls.contains { if case .openURL = $0 { return true } else { return false } },
                       "The link would start a fresh conversation in whatever window is focused")
    }

    func testOpenReportsRejectedLink() async {
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCode"], running: ["com.microsoft.VSCode"], linkAccepted: false)
        let outcome = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: makeTemporaryDirectory(), workspace: workspace)
        guard case .failure = outcome else { return XCTFail("Expected a failure when the link is rejected") }
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeVSCodeLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

@MainActor
private final class FakeWorkspace: ClaudeVSCodeWorkspace {
    enum Call: Equatable {
        case openFolder(String)
        case pause(Duration)
        case openURL(String)
    }

    struct FolderOpenError: Error {}

    private let installed: Set<String>
    private let running: Set<String>
    private let folderOpenFails: Bool
    private let linkAccepted: Bool
    private(set) var calls: [Call] = []

    init(installed: Set<String>, running: Set<String> = [], folderOpenFails: Bool = false, linkAccepted: Bool = true) {
        self.installed = installed
        self.running = running
        self.folderOpenFails = folderOpenFails
        self.linkAccepted = linkAccepted
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        installed.contains(bundleIdentifier) ? URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app") : nil
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        running.contains(bundleIdentifier)
    }

    func openFolder(_ folder: URL, withApplicationAt applicationURL: URL) async throws {
        calls.append(.openFolder(folder.path))
        if folderOpenFails { throw FolderOpenError() }
    }

    func openURL(_ url: URL) -> Bool {
        calls.append(.openURL(url.absoluteString))
        return linkAccepted
    }

    func pause(for duration: Duration) async {
        calls.append(.pause(duration))
    }
}
