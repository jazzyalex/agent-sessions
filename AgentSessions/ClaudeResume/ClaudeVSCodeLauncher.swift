import AppKit
import Foundation

/// The side effects `ClaudeVSCodeLauncher` needs, behind a seam so tests can
/// record the order of calls without launching VS Code.
@MainActor
protocol ClaudeVSCodeWorkspace {
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
    func isRunning(bundleIdentifier: String) -> Bool
    func openFolder(_ folder: URL, withApplicationAt applicationURL: URL) async throws
    func openURL(_ url: URL) -> Bool
    func pause(for duration: Duration) async
}

@MainActor
struct SystemClaudeVSCodeWorkspace: ClaudeVSCodeWorkspace {
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    func openFolder(_ folder: URL, withApplicationAt applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([folder], withApplicationAt: applicationURL, configuration: configuration)
    }

    func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func pause(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

/// Opens a Claude Code session in the Claude Code extension for VS Code.
///
/// The extension registers `vscode://anthropic.claude-code/open?session=<id>`
/// (https://code.claude.com/docs/en/vs-code). It resumes the session from the
/// folder open in the focused VS Code window and starts a fresh conversation
/// when it can't find the session there. So the launcher opens the session's
/// project folder first, waits for that window to come forward, and only then
/// hands the extension the URI.
enum ClaudeVSCodeLauncher {

    struct Editor: Equatable {
        let bundleIdentifier: String
        let urlScheme: String
        let displayName: String
    }

    /// Stable first; Insiders is used only when stable isn't installed.
    static let editors: [Editor] = [
        Editor(bundleIdentifier: "com.microsoft.VSCode", urlScheme: "vscode", displayName: "VS Code"),
        Editor(bundleIdentifier: "com.microsoft.VSCodeInsiders", urlScheme: "vscode-insiders", displayName: "VS Code Insiders"),
    ]

    /// Wait between opening the folder and sending the URI. Two seconds was
    /// verified by hand with VS Code already running. A cold start also has to
    /// load the window and activate the extension, so it gets more time.
    static let warmStartDelay: Duration = .seconds(2)
    static let coldStartDelay: Duration = .seconds(6)

    struct Request: Equatable {
        let sessionID: String
        let folder: URL
    }

    enum Validation: Equatable {
        case ready(Request)
        case invalid(String)
    }

    enum Outcome: Equatable {
        case launched
        case failure(String)
    }

    static func sessionURL(sessionID: String, scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "anthropic.claude-code"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url
    }

    /// Checks the inputs before anything is launched. A worktree that has been
    /// removed falls back to its repository root: since Claude Code 2.1.300 the
    /// extension also resumes worktree sessions from the main checkout.
    static func makeRequest(sessionID: String?,
                            workingDirectory: URL?,
                            fileManager: FileManager = .default) -> Validation {
        guard let sessionID, ClaudeSessionIDHelper.looksLikeUUID(sessionID) else {
            return .invalid("This session has no Claude session ID, so VS Code can't resume it.")
        }
        guard let workingDirectory else {
            return .invalid("This session has no working directory, so VS Code doesn't know which folder to open.")
        }
        if isDirectory(workingDirectory, fileManager: fileManager) {
            return .ready(Request(sessionID: sessionID, folder: workingDirectory))
        }
        if let repositoryRoot = worktreeRepositoryRoot(for: workingDirectory),
           isDirectory(repositoryRoot, fileManager: fileManager) {
            return .ready(Request(sessionID: sessionID, folder: repositoryRoot))
        }
        return .invalid("The session's folder doesn't exist on this Mac: \(workingDirectory.path)")
    }

    /// `/repo/.claude/worktrees/<name>` → `/repo`. Nil for any other path.
    static func worktreeRepositoryRoot(for folder: URL) -> URL? {
        let marker = "/.claude/worktrees/"
        let path = folder.standardizedFileURL.path
        guard let range = path.range(of: marker), range.lowerBound > path.startIndex else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]), isDirectory: true)
    }

    @MainActor
    static func installedEditor(in workspace: any ClaudeVSCodeWorkspace) -> (Editor, URL)? {
        for editor in editors {
            if let url = workspace.applicationURL(forBundleIdentifier: editor.bundleIdentifier) {
                return (editor, url)
            }
        }
        return nil
    }

    @MainActor
    static var isEditorInstalled: Bool {
        installedEditor(in: SystemClaudeVSCodeWorkspace()) != nil
    }

    @MainActor
    static func open(sessionID: String?,
                     workingDirectory: URL?,
                     workspace: (any ClaudeVSCodeWorkspace)? = nil,
                     fileManager: FileManager = .default) async -> Outcome {
        let workspace = workspace ?? SystemClaudeVSCodeWorkspace()
        let request: Request
        switch makeRequest(sessionID: sessionID, workingDirectory: workingDirectory, fileManager: fileManager) {
        case .ready(let ready):
            request = ready
        case .invalid(let message):
            return .failure(message)
        }
        guard let (editor, applicationURL) = installedEditor(in: workspace) else {
            return .failure("VS Code isn't installed. Install Visual Studio Code with the Claude Code extension to open sessions there.")
        }
        guard let uri = sessionURL(sessionID: request.sessionID, scheme: editor.urlScheme) else {
            return .failure("Could not build the VS Code link for this session.")
        }
        let wasRunning = workspace.isRunning(bundleIdentifier: editor.bundleIdentifier)
        do {
            try await workspace.openFolder(request.folder, withApplicationAt: applicationURL)
        } catch {
            return .failure("\(editor.displayName) could not open \(request.folder.path): \(error.localizedDescription)")
        }
        await workspace.pause(for: wasRunning ? warmStartDelay : coldStartDelay)
        guard workspace.openURL(uri) else {
            return .failure("\(editor.displayName) did not accept the link for this session. Check that the Claude Code extension is installed.")
        }
        return .launched
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
