import XCTest
@testable import AgentSessions

@MainActor
final class ClaudeVSCodeLauncherTests: XCTestCase {

    private let sessionID = "c1b5bf2b-1002-4afa-aebc-1b133c4facb1"

    // MARK: - Link

    func testSessionURLUsesExtensionOpenHandler() {
        let url = ClaudeVSCodeLauncher.sessionURL(sessionID: sessionID, scheme: "vscode", windowID: 12)
        XCTAssertEqual(url?.absoluteString, "vscode://anthropic.claude-code/open?session=\(sessionID)&windowId=12")
    }

    func testSessionURLForInsidersUsesItsScheme() {
        let url = ClaudeVSCodeLauncher.sessionURL(sessionID: sessionID, scheme: "vscode-insiders", windowID: 12)
        XCTAssertEqual(url?.absoluteString, "vscode-insiders://anthropic.claude-code/open?session=\(sessionID)&windowId=12")
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

    func testOpenWaitsForVerifiedWindowAndTargetsIt() async {
        let folder = makeTemporaryDirectory()
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCode"], windows: [nil, 12])
        let outcome = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: folder, workspace: workspace)
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(workspace.calls, [
            .openFolder(folder.path),
            .verify(folder.path),
            .verify(folder.path),
            .openURL("vscode://anthropic.claude-code/open?session=\(sessionID)&windowId=12"),
        ])
    }

    func testUnverifiedWorkspaceDoesNotSendURI() async {
        let folder = makeTemporaryDirectory()
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCode"], windows: [nil])
        let outcome = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: folder,
                                                       workspace: workspace, verificationTimeout: .zero)
        guard case .failure = outcome else { return XCTFail("An unverified folder must fail") }
        XCTAssertEqual(workspace.calls, [.openFolder(folder.path), .verify(folder.path)])
    }

    func testOpenFallsBackToInsiders() async {
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCodeInsiders"])
        _ = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: makeTemporaryDirectory(), workspace: workspace)
        XCTAssertEqual(workspace.calls.last, .openURL("vscode-insiders://anthropic.claude-code/open?session=\(sessionID)&windowId=12"))
    }

    func testOpenDoesNotSendLinkWhenFolderFailsToOpen() async {
        let folder = makeTemporaryDirectory()
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCode"], folderOpenFails: true)
        let outcome = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: folder, workspace: workspace)
        guard case .failure = outcome else { return XCTFail("Expected a failure when the folder can't open") }
        XCTAssertEqual(workspace.calls, [.openFolder(folder.path)])
    }

    func testOpenReportsRejectedLink() async {
        let workspace = FakeWorkspace(installed: ["com.microsoft.VSCode"], linkAccepted: false)
        let outcome = await ClaudeVSCodeLauncher.open(sessionID: sessionID, workingDirectory: makeTemporaryDirectory(), workspace: workspace)
        guard case .failure = outcome else { return XCTFail("Expected a failure when the link is rejected") }
    }

    func testLockRequiresExactSingleFolderAndEditor() throws {
        let root = makeTemporaryDirectory()
        let lock = root.appendingPathComponent("12345.lock")
        let target = root.appendingPathComponent("one/shared")
        let other = root.appendingPathComponent("two/shared")
        func writeLock(_ folders: [URL]) throws {
            try JSONSerialization.data(withJSONObject: [
                "pid": 3000, "workspaceFolders": folders.map(\.path),
                "ideName": "Visual Studio Code", "transport": "ws",
            ]).write(to: lock)
        }
        try writeLock([other])
        XCTAssertNil(ClaudeVSCodeWindowEvidence.readLock(lock, matching: target, editorName: "Visual Studio Code"))
        try writeLock([target, other])
        XCTAssertNil(ClaudeVSCodeWindowEvidence.readLock(lock, matching: target, editorName: "Visual Studio Code"))
        try writeLock([target])
        XCTAssertNil(ClaudeVSCodeWindowEvidence.readLock(lock, matching: target, editorName: "Visual Studio Code - Insiders"))
        XCTAssertEqual(ClaudeVSCodeWindowEvidence.readLock(lock, matching: target, editorName: "Visual Studio Code")?.port, 12345)
    }

    func testWindowIDAmbiguityAndWrongEditorFailClosed() {
        let status = """
                    CPU % Mem MB PID Process
                    0 100 500 code
                    0 100 501 window [2] (shared)
                    0 100 502 extension-host [2]
                    0 100 503 window [21] (shared)
                    0 100 504 extension-host [21]
                    """
        typealias Listener = ClaudeVSCodeWindowEvidence.Listener
        XCTAssertNil(ClaudeVSCodeWindowEvidence.windowID(in: status, listeners: [Listener(editorPID: 500, processID: 502)]))
        XCTAssertNil(ClaudeVSCodeWindowEvidence.windowID(in: status, listeners: [Listener(editorPID: 900, processID: 504)]))
        XCTAssertNil(ClaudeVSCodeWindowEvidence.windowID(in: status, listeners: [Listener(editorPID: 500, processID: 501)]))
        XCTAssertNil(ClaudeVSCodeWindowEvidence.windowID(in: status, listeners: [
            Listener(editorPID: 500, processID: 502), Listener(editorPID: 500, processID: 504),
        ]))
        XCTAssertEqual(ClaudeVSCodeWindowEvidence.windowID(in: status, listeners: [Listener(editorPID: 500, processID: 504)]), 21)
    }

    func testListenerMustHaveOneLiveOwner() {
        XCTAssertEqual(ClaudeVSCodeWindowEvidence.listenerPID(in: "p500\nf1\n"), 500)
        XCTAssertNil(ClaudeVSCodeWindowEvidence.listenerPID(in: "p500\np501\n"))
        XCTAssertNil(ClaudeVSCodeWindowEvidence.listenerPID(in: ""))
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
        case verify(String)
        case openURL(String)
    }

    private let installed: Set<String>
    private var windows: [Int?]
    private let folderOpenFails: Bool
    private let linkAccepted: Bool
    private(set) var calls: [Call] = []

    init(installed: Set<String>, windows: [Int?] = [12], folderOpenFails: Bool = false, linkAccepted: Bool = true) {
        self.installed = installed
        self.windows = windows
        self.folderOpenFails = folderOpenFails
        self.linkAccepted = linkAccepted
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        installed.contains(bundleIdentifier) ? URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app") : nil
    }

    func openFolder(_ folder: URL, withApplicationAt applicationURL: URL) async -> Bool {
        calls.append(.openFolder(folder.path))
        return !folderOpenFails
    }

    func verifiedWindow(for folder: URL, editor: ClaudeVSCodeLauncher.Editor, applicationURL: URL) async -> Int? {
        calls.append(.verify(folder.path))
        return windows.isEmpty ? nil : windows.removeFirst()
    }

    func openURL(_ url: URL, withApplicationAt applicationURL: URL) async -> Bool {
        calls.append(.openURL(url.absoluteString))
        return linkAccepted
    }
}
