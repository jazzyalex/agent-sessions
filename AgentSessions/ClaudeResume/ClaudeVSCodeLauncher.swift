import AppKit
import Foundation

@MainActor
protocol ClaudeVSCodeWorkspace {
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
    func openFolder(_ folder: URL, withApplicationAt applicationURL: URL) async -> Bool
    func verifiedWindow(for folder: URL, editor: ClaudeVSCodeLauncher.Editor, applicationURL: URL) async -> Int?
    func openURL(_ url: URL, withApplicationAt applicationURL: URL) async -> Bool
}

@MainActor
struct SystemClaudeVSCodeWorkspace: ClaudeVSCodeWorkspace {
    private let editorArguments: [String]
    private let ideDirectory: URL

    init(editorArguments: [String] = [], ideDirectory: URL? = nil) {
        self.editorArguments = editorArguments
        let configRoot = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        self.ideDirectory = ideDirectory ?? configRoot.appendingPathComponent("ide", isDirectory: true)
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func openFolder(_ folder: URL, withApplicationAt applicationURL: URL) async -> Bool {
        guard let cli = Self.cli(in: applicationURL) else { return false }
        return await Self.run(cli, editorArguments + ["--folder-uri", folder.absoluteString], timeout: 6) != nil
    }

    func verifiedWindow(for folder: URL, editor: ClaudeVSCodeLauncher.Editor, applicationURL: URL) async -> Int? {
        guard let cli = Self.cli(in: applicationURL) else { return nil }
        let directory = ideDirectory
        let arguments = editorArguments
        let editorName = editor.applicationName
        return await Task.detached(priority: .utility) { () -> Int? in
            let locks = ClaudeVSCodeWindowEvidence.readLocks(in: directory, matching: folder, editorName: editorName)
            guard !locks.isEmpty,
                  let status = Self.runBlocking(cli, arguments + ["--status"], timeout: 3) else { return nil }
            // Claude's lock records the editor parent PID. Only the process that
            // still owns the loopback listener identifies the actual window's host.
            var listeners: [ClaudeVSCodeWindowEvidence.Listener] = []
            let deadline = ContinuousClock.now + .seconds(3)
            for lock in locks {
                guard ContinuousClock.now < deadline else { return nil }
                guard let output = Self.runBlocking(URL(fileURLWithPath: "/usr/sbin/lsof"),
                    ["-nP", "-a", "-iTCP@127.0.0.1:\(lock.port)", "-sTCP:LISTEN", "-Fp"], timeout: 1),
                      let owner = ClaudeVSCodeWindowEvidence.listenerPID(in: output),
                      ClaudeVSCodeWindowEvidence.readLock(lock.url, matching: folder, editorName: editorName) == lock
                else { continue }
                listeners.append(.init(editorPID: lock.editorPID, processID: owner))
            }
            return ClaudeVSCodeWindowEvidence.windowID(in: status, listeners: listeners)
        }.value
    }

    func openURL(_ url: URL, withApplicationAt applicationURL: URL) async -> Bool {
        guard let cli = Self.cli(in: applicationURL) else { return false }
        return await Self.run(cli, editorArguments + ["--open-url", "--", url.absoluteString], timeout: 4) != nil
    }

    private static func cli(in applicationURL: URL) -> URL? {
        let bin = applicationURL.appendingPathComponent("Contents/Resources/app/bin", isDirectory: true)
        return ["code", "code-insiders"].map { bin.appendingPathComponent($0) }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private nonisolated static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async -> String? {
        guard !Task.isCancelled else { return nil }
        return await Task.detached(priority: .utility) {
            runBlocking(executable, arguments, timeout: timeout)
        }.value
    }

    private nonisolated static func runBlocking(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-vscode-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("stdout")
            guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else { return nil }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            // The bundled code CLI can otherwise forward into a remote terminal.
            environment.removeValue(forKey: "VSCODE_IPC_HOOK_CLI")
            process.environment = environment
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            try process.run()
            guard process.waitForExit(timeout: timeout), process.terminationStatus == 0 else { return nil }
            let reader = try FileHandle(forReadingFrom: output)
            defer { try? reader.close() }
            let limit = 512 * 1024
            let data = try reader.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

/// VS Code status reports extension-host PIDs and window IDs, but prints only
/// workspace basenames. Claude's IDE locks report full workspace paths, but
/// their PID is shared by every window in an editor instance.
enum ClaudeVSCodeWindowEvidence {
    struct Lock: Equatable {
        let url: URL
        let port: Int
        let editorPID: Int
    }

    struct Listener {
        let editorPID: Int
        let processID: Int
    }

    static func readLocks(in directory: URL, matching folder: URL, editorName: String) -> [Lock] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { readLock($0, matching: folder, editorName: editorName) }
    }

    static func readLock(_ url: URL, matching folder: URL, editorName: String) -> Lock? {
        struct Metadata: Decodable {
            let pid: Int
            let workspaceFolders: [String]
            let ideName: String
            let transport: String
        }
        guard url.pathExtension == "lock", let port = Int(url.deletingPathExtension().lastPathComponent),
              (1...65535).contains(port),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 16_384,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384,
              let info = try? JSONDecoder().decode(Metadata.self, from: data),
              info.pid > 0, info.ideName == editorName, info.transport == "ws",
              info.workspaceFolders.count == 1, let path = info.workspaceFolders.first, path.hasPrefix("/"),
              URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                == folder.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return Lock(url: url, port: port, editorPID: info.pid)
    }

    static func listenerPID(in output: String) -> Int? {
        let pids = Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            line.first == "p" ? Int(line.dropFirst()) : nil
        }.filter { $0 > 0 })
        return pids.count == 1 ? pids.first : nil
    }

    static func windowID(in status: String, listeners: [Listener]) -> Int? {
        let lines = status.split(whereSeparator: \.isNewline)
        guard let header = lines.firstIndex(where: {
            $0.split(whereSeparator: \.isWhitespace) == ["CPU", "%", "Mem", "MB", "PID", "Process"]
        }) else { return nil }
        let table = lines.dropFirst(header + 1).prefix { !$0.hasPrefix("Workspace Stats:") }
        let rows = table.compactMap { line -> (pid: Int, process: Substring)? in
            let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard fields.count == 4, Int(fields[0]) != nil, Int(fields[1]) != nil,
                  let pid = Int(fields[2]), pid > 0 else { return nil }
            return (pid, fields[3])
        }
        guard let main = rows.first, ["code", "code-insiders"].contains(main.process) else { return nil }
        func id(in process: Substring, prefix: String) -> Int? {
            guard process.hasPrefix(prefix), let end = process.firstIndex(of: "]") else { return nil }
            return Int(process.dropFirst(prefix.count)[..<end])
        }
        let windows = Set(rows.compactMap { id(in: $0.process, prefix: "window [") })
        let livePIDs = Set(listeners.filter { $0.editorPID == main.pid }.map(\.processID))
        let hosts = rows.compactMap { row -> (pid: Int, window: Int)? in
            guard let window = id(in: row.process, prefix: "extension-host [") else { return nil }
            return (row.pid, window)
        }
        let matching = hosts.filter { livePIDs.contains($0.pid) && windows.contains($0.window) }
        guard matching.count == 1, let match = matching.first, match.window > 0 else { return nil }
        // VS Code's URI router uses a prefix regex for window IDs and falls
        // back to the active window if it has no matching host connection.
        // Refuse ambiguous routing, even if the folder itself was verified.
        let prefix = String(match.window)
        let knownIDs = windows.union(hosts.map(\.window))
        guard !knownIDs.contains(where: { $0 != match.window && String($0).hasPrefix(prefix) }) else { return nil }
        return match.window
    }
}

enum ClaudeVSCodeLauncher {
    struct Editor: Equatable {
        let bundleIdentifier: String
        let urlScheme: String
        let applicationName: String
    }

    static let editors = [
        Editor(bundleIdentifier: "com.microsoft.VSCode", urlScheme: "vscode", applicationName: "Visual Studio Code"),
        Editor(bundleIdentifier: "com.microsoft.VSCodeInsiders", urlScheme: "vscode-insiders", applicationName: "Visual Studio Code - Insiders"),
    ]

    @MainActor private static var busy = false

    struct Request: Equatable {
        let sessionID: String
        let folder: URL
    }

    enum Validation: Equatable {
        case ready(Request)
        case invalid(String)
    }

    enum Outcome: Equatable {
        case sent
        case failure(String)
    }

    static func sessionURL(sessionID: String, scheme: String, windowID: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "anthropic.claude-code"
        components.path = "/open"
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "windowId", value: String(windowID)),
        ]
        return components.url
    }

    static func makeRequest(sessionID: String?,
                            workingDirectory: URL?,
                            fileManager: FileManager = .default) -> Validation {
        guard let sessionID, ClaudeSessionIDHelper.looksLikeUUID(sessionID) else {
            return .invalid(String(localized: "This session has no Claude session ID."))
        }
        guard let workingDirectory, workingDirectory.isFileURL else {
            return .invalid(String(localized: "This session has no working directory to open in VS Code."))
        }
        if isDirectory(workingDirectory, fileManager: fileManager) {
            return .ready(Request(sessionID: sessionID, folder: workingDirectory))
        }
        // Claude Code extension 2.1.300+ searches this repository's worktrees.
        if let root = worktreeRepositoryRoot(for: workingDirectory), isDirectory(root, fileManager: fileManager) {
            return .ready(Request(sessionID: sessionID, folder: root))
        }
        return .invalid(String(localized: "The session’s folder doesn’t exist on this Mac. \(workingDirectory.path)",
                               comment: "The placeholder is the original Claude session folder path."))
    }

    static func worktreeRepositoryRoot(for folder: URL) -> URL? {
        let path = folder.standardizedFileURL.path
        guard let range = path.range(of: "/.claude/worktrees/"), range.lowerBound > path.startIndex else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]), isDirectory: true)
    }

    @MainActor
    private static func installedEditor(in workspace: any ClaudeVSCodeWorkspace) -> (Editor, URL)? {
        for editor in editors {
            if let url = workspace.applicationURL(forBundleIdentifier: editor.bundleIdentifier) {
                return (editor, url)
            }
        }
        return nil
    }

    @MainActor
    static var isEditorInstalled: Bool { installedEditor(in: SystemClaudeVSCodeWorkspace()) != nil }

    @MainActor
    static func open(sessionID: String?,
                     workingDirectory: URL?,
                     workspace: (any ClaudeVSCodeWorkspace)? = nil,
                     verificationTimeout: Duration = .seconds(20)) async -> Outcome {
        guard !busy else {
            return .failure(String(localized: "A Claude session is already opening in VS Code."))
        }
        busy = true
        defer { busy = false }
        let workspace = workspace ?? SystemClaudeVSCodeWorkspace()
        let request: Request
        switch makeRequest(sessionID: sessionID, workingDirectory: workingDirectory) {
        case .ready(let ready): request = ready
        case .invalid(let message): return .failure(message)
        }
        guard let (editor, applicationURL) = installedEditor(in: workspace) else {
            return .failure(String(localized: "Install VS Code and the Claude Code extension to open this session."))
        }
        guard await workspace.openFolder(request.folder, withApplicationAt: applicationURL) else {
            return .failure(String(localized: "VS Code could not open the session’s folder. \(request.folder.path)",
                                   comment: "The placeholder is the Claude session folder path."))
        }
        let deadline = ContinuousClock.now + verificationTimeout
        repeat {
            if Task.isCancelled { break }
            if let windowID = await workspace.verifiedWindow(for: request.folder, editor: editor, applicationURL: applicationURL),
               let uri = sessionURL(sessionID: request.sessionID, scheme: editor.urlScheme, windowID: windowID) {
                guard !Task.isCancelled else { break }
                if await workspace.openURL(uri, withApplicationAt: applicationURL) { return .sent }
                return .failure(String(localized: "VS Code could not accept the Claude session link. Check that the Claude Code extension is installed and enabled."))
            }
            guard ContinuousClock.now < deadline else { break }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
        } while ContinuousClock.now < deadline
        return .failure(String(localized: "Could not verify the Claude Code workspace in VS Code. Open and trust this folder, enable the Claude Code extension, then try again. \(request.folder.path)",
                               comment: "The placeholder is the folder that could not be verified in VS Code."))
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
