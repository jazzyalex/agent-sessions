import Foundation

enum QwenStorageEnvironmentOverride: Equatable {
    case qwenHome(URL)
    case runtimeDirectory(URL)
}

extension Session {
    /// Qwen's installed `--resume` lookup reads active `chats/<id>.jsonl`
    /// only. Every other Qwen path is browse-only, including native archives
    /// and Agent Sessions' archive fallback copies.
    var isArchivedQwenSession: Bool {
        isArchivedQwenSession(storageContext: nil)
    }

    func isArchivedQwenSession(storageContext: QwenResumeEligibility.StorageContext?) -> Bool {
        source == .qwen && !QwenResumeEligibility.isActiveSession(self, storageContext: storageContext)
    }
}

enum QwenResumeEligibility {
    struct StorageContext: Equatable {
        let projectsRoot: URL
        /// Preserves how storage was selected so copied and launched commands
        /// use the environment variable understood by that storage source.
        let environmentOverride: QwenStorageEnvironmentOverride?
        /// QWEN_RUNTIME_DIR always resolves a literal `projects` child. An
        /// arbitrary renamed/copied projects root is browseable, but the CLI
        /// cannot be pointed back to it reliably.
        let supportsResumeLookup: Bool
    }

    static func configuredStorageContext(
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> StorageContext {
        let preference = defaults.string(forKey: QwenPreferencesKey.sessionsRootOverride)
            .flatMap { $0.isEmpty ? nil : $0 }
        let qwenHome = environment["QWEN_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        // QWEN_HOME is deliberately NOT passed as customRoot. Doing so routed it through
        // the customRoot branch, which never falls back, so resume would resolve
        // $QWEN_HOME while discovery resolved ~/.qwen and every listed session came back
        // browse-only. Let the shared resolver apply the same rule here.
        let discovery = QwenSessionDiscovery(
            customRoot: preference,
            homeDirectory: homeDirectory,
            environment: environment
        )
        let projectsRoot = discovery.sessionsRoot().standardizedFileURL
        let supportsResumeLookup: Bool
        let environmentOverride: QwenStorageEnvironmentOverride?
        if preference != nil {
            // A manual projects root can represent QWEN_RUNTIME_DIR output only
            // when the CLI can reconstruct it as <runtime>/projects.
            supportsResumeLookup = projectsRoot.lastPathComponent == "projects"
            environmentOverride = supportsResumeLookup
                ? .runtimeDirectory(projectsRoot.deletingLastPathComponent())
                : nil
        } else if let qwenHome {
            let expandedHome = URL(
                fileURLWithPath: UserPathExpansion.expand(qwenHome, relativeTo: homeDirectory),
                isDirectory: true
            ).standardizedFileURL
            let expectedProjectsRoot = expandedHome
                .appendingPathComponent("projects", isDirectory: true)
                .standardizedFileURL
            // Either QWEN_HOME is where sessions live, or the resolver fell back to
            // ~/.qwen because $QWEN_HOME/projects does not exist. Both are resumable,
            // and both carry an explicit QWEN_HOME.
            //
            // The fallback must NOT be left to the inherited environment. 0.14.x ignores
            // QWEN_HOME and would find the session either way, but 0.22.x honors it via
            // getGlobalQwenDir() and would resolve the user's stale export and report the
            // session as missing. Naming the fallback root explicitly is correct for both
            // readers, so no CLI version gate is needed.
            supportsResumeLookup = true
            environmentOverride = projectsRoot == expectedProjectsRoot
                ? .qwenHome(expandedHome)
                : .qwenHome(
                    homeDirectory.appendingPathComponent(".qwen", isDirectory: true).standardizedFileURL
                )
        } else {
            supportsResumeLookup = true
            environmentOverride = nil
        }
        return StorageContext(
            projectsRoot: projectsRoot,
            environmentOverride: environmentOverride,
            supportsResumeLookup: supportsResumeLookup
        )
    }

    static func isActiveSession(_ session: Session, storageContext: StorageContext? = nil) -> Bool {
        guard session.source == .qwen else { return false }
        let context = storageContext ?? configuredStorageContext()
        guard context.supportsResumeLookup else { return false }
        return QwenSessionDiscovery.transcriptLocation(
            for: URL(fileURLWithPath: session.filePath),
            projectsRoot: context.projectsRoot
        ) == .active
    }

    static func canResume(_ session: Session, storageContext: StorageContext? = nil) -> Bool {
        isActiveSession(session, storageContext: storageContext)
    }

    static func canCopyResumeCommand(_ session: Session, storageContext: StorageContext? = nil) -> Bool {
        canResume(session, storageContext: storageContext)
    }

}

struct QwenResumeCommandBuilder {
    struct CommandPackage {
        let shellCommand: String
        let displayCommand: String
        let workingDirectory: URL?
    }

    enum BuildError: Error { case missingSessionID }
    enum Strategy { case sessionByID(id: String); case continueMostRecent }

    func strategy(forSessionID id: String) -> Strategy {
        id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .continueMostRecent
            : .sessionByID(id: id)
    }

    func makeCoreCommand(strategy: Strategy,
                         binaryCommand: String,
                         storageEnvironmentOverride: QwenStorageEnvironmentOverride? = nil) throws -> String {
        let binary = ShellQuoting.quoteIfNeeded(binaryCommand)
        let command: String
        switch strategy {
        case .sessionByID(let id):
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw BuildError.missingSessionID }
            command = "\(binary) --resume \(ShellQuoting.quoteIfNeeded(trimmed))"
        case .continueMostRecent:
            command = "\(binary) --continue"
        }
        return withStorageEnvironment(storageEnvironmentOverride, command: command)
    }

    func makeCommand(strategy: Strategy,
                     binaryURL: URL,
                     workingDirectory: URL?,
                     storageEnvironmentOverride: QwenStorageEnvironmentOverride? = nil) throws -> CommandPackage {
        let binary = ShellQuoting.quote(binaryURL.path)
        let command: String
        switch strategy {
        case .sessionByID(let id):
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw BuildError.missingSessionID }
            command = "\(binary) --resume \(ShellQuoting.quote(trimmed))"
        case .continueMostRecent:
            command = "\(binary) --continue"
        }
        let core = withStorageEnvironment(storageEnvironmentOverride, command: command)
        let shell = workingDirectory.map { "cd \(ShellQuoting.quote($0.path)) && \(core)" } ?? core
        return CommandPackage(shellCommand: shell, displayCommand: core, workingDirectory: workingDirectory)
    }

    private func withStorageEnvironment(
        _ override: QwenStorageEnvironmentOverride?,
        command: String
    ) -> String {
        guard let override else { return command }
        let assignment: String
        switch override {
        case .qwenHome(let directory):
            assignment = "QWEN_HOME=\(ShellQuoting.quote(directory.path))"
        case .runtimeDirectory(let directory):
            assignment = "QWEN_RUNTIME_DIR=\(ShellQuoting.quote(directory.path))"
        }
        return "\(assignment) \(command)"
    }
}

struct QwenResumeInput {
    let sessionID: String?
    let workingDirectory: URL?
    let binaryOverride: String?
    let storageEnvironmentOverride: QwenStorageEnvironmentOverride?

    init(sessionID: String?,
         workingDirectory: URL?,
         binaryOverride: String?,
         storageEnvironmentOverride: QwenStorageEnvironmentOverride? = nil) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.binaryOverride = binaryOverride
        self.storageEnvironmentOverride = storageEnvironmentOverride
    }
}

struct QwenResumeResult {
    let launched: Bool
    let error: String?
}

@MainActor
protocol QwenTerminalLaunching {
    func launchInTerminal(_ package: QwenResumeCommandBuilder.CommandPackage) async throws
}

@MainActor final class QwenTerminalLauncher: QwenTerminalLaunching {
    func launchInTerminal(_ package: QwenResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "QwenTerminalLauncher")
    }
}
@MainActor final class QwenITermLauncher: QwenTerminalLaunching {
    func launchInTerminal(_ package: QwenResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "QwenITermLauncher")
    }
}
@MainActor final class QwenWarpLauncher: QwenTerminalLaunching {
    func launchInTerminal(_ package: QwenResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand,
                                                     cwd: package.workingDirectory?.path,
                                                     kind: .warp)
    }
}
@MainActor final class QwenWarpPreviewLauncher: QwenTerminalLaunching {
    func launchInTerminal(_ package: QwenResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand,
                                                     cwd: package.workingDirectory?.path,
                                                     kind: .warpPreview)
    }
}

@MainActor
final class QwenResumeCoordinator {
    private let environment: QwenCLIEnvironmentProviding
    private let builder: QwenResumeCommandBuilder
    private let launcher: QwenTerminalLaunching

    init(environment: QwenCLIEnvironmentProviding,
         builder: QwenResumeCommandBuilder,
         launcher: QwenTerminalLaunching) {
        self.environment = environment
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: QwenResumeInput, dryRun: Bool = false) async -> QwenResumeResult {
        let environment = self.environment
        let override = input.binaryOverride
        let probe = await Task.detached { environment.probe(customPath: override) }.value
        guard case .success(let info) = probe else {
            let error: String
            if case .failure(let failure) = probe {
                error = failure.localizedDescription
            } else {
                error = "Qwen Code not found."
            }
            return QwenResumeResult(launched: false, error: error)
        }

        let id = input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let strategy: QwenResumeCommandBuilder.Strategy
        if !id.isEmpty, info.supportsResume {
            strategy = .sessionByID(id: id)
        } else if info.supportsContinue, input.workingDirectory != nil {
            strategy = .continueMostRecent
        } else if info.supportsContinue {
            return QwenResumeResult(launched: false,
                                    error: "No working directory for this session, so --continue could resume an unrelated one.")
        } else {
            return QwenResumeResult(launched: false,
                                    error: "Qwen Code does not advertise the required --resume or --continue flag.")
        }

        do {
            let package = try builder.makeCommand(strategy: strategy,
                                                  binaryURL: info.binaryURL,
                                                  workingDirectory: input.workingDirectory,
                                                  storageEnvironmentOverride: input.storageEnvironmentOverride)
            if dryRun { return QwenResumeResult(launched: false, error: nil) }
            try await launcher.launchInTerminal(package)
            return QwenResumeResult(launched: true, error: nil)
        } catch {
            return QwenResumeResult(launched: false, error: error.localizedDescription)
        }
    }
}
