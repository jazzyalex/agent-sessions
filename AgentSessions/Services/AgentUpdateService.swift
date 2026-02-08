import Foundation

enum AgentPackageManager: String, CaseIterable, Sendable {
    case brew
    case npm
    case pipx
    case pip
    case unknown

    var displayName: String {
        switch self {
        case .brew: return "Homebrew"
        case .npm: return "npm"
        case .pipx: return "pipx"
        case .pip: return "pip"
        case .unknown: return "Unknown"
        }
    }
}

enum AgentUpdateStatus: Sendable {
    case upToDate
    case updateAvailable
    case noPackageManagerDetected
    case latestVersionUnavailable
    case unsupportedForManager
    case failed
}

struct AgentUpdateCheckResult: Sendable {
    let source: SessionSource
    let installedVersion: String?
    let latestVersion: String?
    let packageIdentifier: String?
    let primaryManager: AgentPackageManager
    let detectedManagers: [AgentPackageManager]
    let status: AgentUpdateStatus
    let detailMessage: String
}

struct AgentUpdateExecutionResult: Sendable {
    let source: SessionSource
    let manager: AgentPackageManager
    let packageIdentifier: String?
    let success: Bool
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let detailMessage: String
}

struct AgentUpdateService {
    private static let managerPreference: [AgentPackageManager] = [.brew, .npm, .pipx, .pip, .unknown]
    private static let fallbackBinarySearchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]
    private static let userLevelBinarySearchPaths: [String] = [
        "~/.local/bin",
        "~/bin",
        "~/Library/pnpm",
        "~/.npm-global/bin"
    ]

    func checkForUpdates(source: SessionSource,
                         resolvedBinaryPath: String?,
                         customBinaryPath: String?) -> AgentUpdateCheckResult {
        guard let profile = Self.profile(for: source) else {
            return AgentUpdateCheckResult(source: source,
                                          installedVersion: nil,
                                          latestVersion: nil,
                                          packageIdentifier: nil,
                                          primaryManager: .unknown,
                                          detectedManagers: [],
                                          status: .failed,
                                          detailMessage: "No update profile is configured for \(source.displayName).")
        }

        let binaryPath = resolveBinaryPath(profile: profile,
                                           resolvedBinaryPath: resolvedBinaryPath,
                                           customBinaryPath: customBinaryPath)
        let ownershipManagers = managersFromBinaryOwnership(binaryPath)
        let installedManagers = installedManagers(for: profile)

        var detectedManagers = orderedUnique(ownershipManagers + installedManagers)
        if detectedManagers.isEmpty {
            detectedManagers = [.unknown]
        }

        let primaryManager = selectPrimaryManager(ownershipManagers: ownershipManagers,
                                                  installedManagers: installedManagers)
        guard primaryManager != .unknown else {
            let binaryNote = binaryPath.map { " Binary path: \($0)." } ?? ""
            let sourceHint: String
            switch source {
            case .claude:
                sourceHint = " If this Claude installation uses the built-in installer, run `claude update` in Terminal."
            default:
                sourceHint = ""
            }
            return AgentUpdateCheckResult(
                source: source,
                installedVersion: nil,
                latestVersion: nil,
                packageIdentifier: nil,
                primaryManager: .unknown,
                detectedManagers: detectedManagers,
                status: .noPackageManagerDetected,
                detailMessage: "Could not determine which supported package manager (Homebrew, npm, pipx, pip) owns the \(source.displayName) binary.\(binaryNote)\(sourceHint)"
            )
        }

        let managerMappings = profile.mappings(for: primaryManager)
        guard !managerMappings.isEmpty else {
            return AgentUpdateCheckResult(
                source: source,
                installedVersion: nil,
                latestVersion: nil,
                packageIdentifier: nil,
                primaryManager: primaryManager,
                detectedManagers: detectedManagers,
                status: .unsupportedForManager,
                detailMessage: "\(source.displayName) does not have an update mapping for \(primaryManager.displayName)."
            )
        }

        guard let managerExecutable = managerExecutablePath(for: primaryManager) else {
            return AgentUpdateCheckResult(
                source: source,
                installedVersion: nil,
                latestVersion: nil,
                packageIdentifier: nil,
                primaryManager: primaryManager,
                detectedManagers: detectedManagers,
                status: .failed,
                detailMessage: "\(primaryManager.displayName) is not available on PATH."
            )
        }

        let inferredIdentifier = inferredPackageIdentifier(from: binaryPath, manager: primaryManager)
        var candidateIdentifiers = orderedUniqueStrings(([inferredIdentifier] + managerMappings.map(\.identifier)).compactMap { $0 })
        if candidateIdentifiers.isEmpty {
            candidateIdentifiers = managerMappings.map(\.identifier)
        }

        let resolvedPackage = resolveInstalledAndLatestVersions(manager: primaryManager,
                                                                identifiers: candidateIdentifiers,
                                                                managerExecutablePath: managerExecutable)
        let managerNote = detectedManagers.count > 1
            ? " Multiple managers detected (\(detectedManagers.map(\.displayName).joined(separator: ", ")); using \(primaryManager.displayName) based on binary ownership."
            : ""

        guard let installedVersion = resolvedPackage.installed, !installedVersion.isEmpty else {
            return AgentUpdateCheckResult(
                source: source,
                installedVersion: nil,
                latestVersion: resolvedPackage.latest,
                packageIdentifier: resolvedPackage.identifier,
                primaryManager: primaryManager,
                detectedManagers: detectedManagers,
                status: .failed,
                detailMessage: "Unable to determine installed version for \(resolvedPackage.identifier).\(managerNote)"
            )
        }

        guard let latestVersion = resolvedPackage.latest, !latestVersion.isEmpty else {
            return AgentUpdateCheckResult(
                source: source,
                installedVersion: installedVersion,
                latestVersion: nil,
                packageIdentifier: resolvedPackage.identifier,
                primaryManager: primaryManager,
                detectedManagers: detectedManagers,
                status: .latestVersionUnavailable,
                detailMessage: "Installed \(installedVersion) via \(primaryManager.displayName), but latest version could not be determined.\(managerNote)"
            )
        }

        if isNewerVersion(latestVersion, than: installedVersion) {
            return AgentUpdateCheckResult(
                source: source,
                installedVersion: installedVersion,
                latestVersion: latestVersion,
                packageIdentifier: resolvedPackage.identifier,
                primaryManager: primaryManager,
                detectedManagers: detectedManagers,
                status: .updateAvailable,
                detailMessage: "Installed: \(installedVersion) · Latest: \(latestVersion) (\(primaryManager.displayName)).\(managerNote)"
            )
        }

        return AgentUpdateCheckResult(
            source: source,
            installedVersion: installedVersion,
            latestVersion: latestVersion,
            packageIdentifier: resolvedPackage.identifier,
            primaryManager: primaryManager,
            detectedManagers: detectedManagers,
            status: .upToDate,
            detailMessage: "No update available. Current version: \(installedVersion).\(managerNote)"
        )
    }

    func performUpdate(source: SessionSource,
                       manager: AgentPackageManager,
                       packageIdentifier: String? = nil) -> AgentUpdateExecutionResult {
        guard let profile = Self.profile(for: source),
              let mapping = profile.mappings(for: manager).first else {
            return AgentUpdateExecutionResult(
                source: source,
                manager: manager,
                packageIdentifier: nil,
                success: false,
                exitCode: 127,
                stdout: "",
                stderr: "",
                detailMessage: "No update mapping exists for \(source.displayName) with \(manager.displayName)."
            )
        }

        guard let managerExecutable = managerExecutablePath(for: manager) else {
            return AgentUpdateExecutionResult(
                source: source,
                manager: manager,
                packageIdentifier: mapping.identifier,
                success: false,
                exitCode: 127,
                stdout: "",
                stderr: "",
                detailMessage: "\(manager.displayName) is not available on PATH."
            )
        }

        let updateIdentifier = packageIdentifier ?? mapping.identifier
        let command: [String]
        switch manager {
        case .brew:
            let isCask = runProcess([managerExecutable, "list", "--cask", updateIdentifier], timeout: 20).status == 0
            if isCask {
                command = [managerExecutable, "upgrade", "--cask", updateIdentifier]
            } else {
                command = [managerExecutable, "upgrade", updateIdentifier]
            }
        case .npm:
            command = [managerExecutable, "install", "-g", updateIdentifier]
        case .pipx:
            command = [managerExecutable, "upgrade", updateIdentifier]
        case .pip:
            command = [managerExecutable, "-m", "pip", "install", "-U", updateIdentifier]
        case .unknown:
            return AgentUpdateExecutionResult(
                source: source,
                manager: manager,
                packageIdentifier: updateIdentifier,
                success: false,
                exitCode: 127,
                stdout: "",
                stderr: "",
                detailMessage: "Unknown package manager."
            )
        }

        let result = runProcess(command, timeout: 180)
        let success = !result.timedOut && result.status == 0
        let detail: String = {
            if result.timedOut {
                return "Update timed out after 180s."
            }
            if success {
                return "Update command completed successfully using \(manager.displayName)."
            }
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.isEmpty {
                return "Update command failed with exit code \(result.status)."
            }
            return "Update command failed (exit \(result.status)): \(err)"
        }()

        return AgentUpdateExecutionResult(
            source: source,
            manager: manager,
            packageIdentifier: updateIdentifier,
            success: success,
            exitCode: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
            detailMessage: detail
        )
    }
}

private extension AgentUpdateService {
    struct AgentPackageMapping {
        let manager: AgentPackageManager
        let identifier: String
    }

    struct AgentUpdateProfile {
        let source: SessionSource
        let binaryNames: [String]
        let mappings: [AgentPackageMapping]

        func mappings(for manager: AgentPackageManager) -> [AgentPackageMapping] {
            mappings.filter { $0.manager == manager }
        }
    }

    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    static func profile(for source: SessionSource) -> AgentUpdateProfile? {
        switch source {
        case .codex:
            return AgentUpdateProfile(
                source: source,
                binaryNames: ["codex"],
                mappings: [
                    .init(manager: .brew, identifier: "codex"),
                    .init(manager: .npm, identifier: "@openai/codex"),
                    .init(manager: .npm, identifier: "@openai/codex-cli")
                ]
            )
        case .claude:
            return AgentUpdateProfile(
                source: source,
                binaryNames: ["claude"],
                mappings: [
                    .init(manager: .brew, identifier: "claude-code"),
                    .init(manager: .npm, identifier: "@anthropic/claude-cli")
                ]
            )
        case .gemini:
            return AgentUpdateProfile(
                source: source,
                binaryNames: ["gemini"],
                mappings: [
                    .init(manager: .brew, identifier: "gemini-cli"),
                    .init(manager: .npm, identifier: "@google/gemini-cli")
                ]
            )
        case .opencode:
            return AgentUpdateProfile(
                source: source,
                binaryNames: ["opencode"],
                mappings: [
                    .init(manager: .brew, identifier: "opencode"),
                    .init(manager: .npm, identifier: "opencode"),
                    .init(manager: .pipx, identifier: "opencode-ai"),
                    .init(manager: .pip, identifier: "opencode-ai")
                ]
            )
        case .copilot:
            return AgentUpdateProfile(
                source: source,
                binaryNames: ["copilot"],
                mappings: [
                    // Copilot CLI is typically installed as a Homebrew cask (copilot-cli).
                    .init(manager: .brew, identifier: "copilot-cli"),
                    .init(manager: .brew, identifier: "copilot")
                ]
            )
        case .droid:
            return AgentUpdateProfile(
                source: source,
                binaryNames: ["droid"],
                mappings: [
                    .init(manager: .brew, identifier: "droid"),
                    .init(manager: .npm, identifier: "droid"),
                    .init(manager: .pipx, identifier: "droid"),
                    .init(manager: .pip, identifier: "droid")
                ]
            )
        case .openclaw:
            return AgentUpdateProfile(
                source: source,
                binaryNames: ["openclaw", "clawdbot"],
                mappings: [
                    .init(manager: .brew, identifier: "openclaw"),
                    .init(manager: .npm, identifier: "clawdbot"),
                    .init(manager: .npm, identifier: "openclaw"),
                    .init(manager: .pipx, identifier: "openclaw"),
                    .init(manager: .pip, identifier: "openclaw")
                ]
            )
        }
    }

    func selectPrimaryManager(ownershipManagers: [AgentPackageManager],
                              installedManagers: [AgentPackageManager]) -> AgentPackageManager {
        // Prefer the highest-confidence ownership signal (already score-sorted).
        if let first = ownershipManagers.first {
            return first
        }

        let installedSet = Set(installedManagers)
        if !installedSet.isEmpty {
            for manager in Self.managerPreference where installedSet.contains(manager) {
                return manager
            }
        }

        return .unknown
    }

    func orderedUnique(_ managers: [AgentPackageManager]) -> [AgentPackageManager] {
        var seen = Set<AgentPackageManager>()
        var out: [AgentPackageManager] = []
        for manager in managers where !seen.contains(manager) {
            seen.insert(manager)
            out.append(manager)
        }
        return out.sorted {
            (Self.managerPreference.firstIndex(of: $0) ?? Int.max) < (Self.managerPreference.firstIndex(of: $1) ?? Int.max)
        }
    }

    func resolveBinaryPath(profile: AgentUpdateProfile,
                           resolvedBinaryPath: String?,
                           customBinaryPath: String?) -> String? {
        if let resolvedBinaryPath,
           !resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return resolvedBinaryPath
        }

        if let customBinaryPath,
           !customBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customBinaryPath as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        for name in profile.binaryNames {
            if let path = commandPath(name) {
                return path
            }
        }
        return nil
    }

    func managersFromBinaryOwnership(_ binaryPath: String?) -> [AgentPackageManager] {
        guard let binaryPath,
              !binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let resolvedPath = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
        let lower = resolvedPath.lowercased()
        var scores: [AgentPackageManager: Int] = [:]

        func bump(_ manager: AgentPackageManager, score: Int) {
            let current = scores[manager] ?? 0
            if score > current { scores[manager] = score }
        }

        if lower.contains("/cellar/") || lower.contains("/homebrew/") {
            bump(.brew, score: 100)
        } else if lower.hasPrefix("/opt/homebrew/bin/") || lower.hasPrefix("/usr/local/bin/") {
            bump(.brew, score: 60)
        }

        if lower.contains("/.nvm/") || lower.contains("/.volta/") || lower.contains("/node_modules/") || lower.contains("/.npm-global/") || lower.contains("/pnpm/") {
            bump(.npm, score: 95)
        }

        if lower.contains("/pipx/venvs/") || lower.contains("/.local/pipx/") || lower.contains("/.local/share/pipx/") {
            bump(.pipx, score: 95)
        }

        if lower.contains("/library/python/") || lower.contains("/site-packages/") {
            bump(.pip, score: 80)
        }

        if let shebang = readShebang(from: resolvedPath)?.lowercased() {
            if shebang.contains("node") {
                bump(.npm, score: 85)
            }
            if shebang.contains("python") {
                if lower.contains("pipx") {
                    bump(.pipx, score: 90)
                } else {
                    bump(.pip, score: 75)
                }
            }
        }

        return scores
            .sorted { $0.value > $1.value }
            .map { $0.key }
    }

    func installedManagers(for profile: AgentUpdateProfile) -> [AgentPackageManager] {
        var managers: [AgentPackageManager] = []
        for manager in orderedUnique(profile.mappings.map(\.manager)) {
            guard let executable = managerExecutablePath(for: manager) else { continue }
            let managerMappings = profile.mappings(for: manager)
            if managerMappings.contains(where: { isPackageInstalled(mapping: $0, managerExecutablePath: executable) }) {
                managers.append(manager)
            }
        }
        return managers
    }

    func managerExecutablePath(for manager: AgentPackageManager) -> String? {
        switch manager {
        case .brew:
            return commandPath("brew")
        case .npm:
            return commandPath("npm")
        case .pipx:
            return commandPath("pipx")
        case .pip:
            return commandPath("python3") ?? commandPath("python")
        case .unknown:
            return nil
        }
    }

    func commandPath(_ command: String) -> String? {
        let fm = FileManager.default
        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        for dir in binarySearchDirectories() {
            let candidate = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(command).path
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }

        for shell in shellCandidates() {
            let script = "command -v -- \(escapeForShell(command)) 2>/dev/null || which \(escapeForShell(command)) 2>/dev/null || true"
            let result = runProcess([shell, "-lc", script], timeout: 10)
            if let parsed = parseCommandPath(result.stdout, command: command) {
                return parsed
            }
        }

        return nil
    }

    func isPackageInstalled(mapping: AgentPackageMapping, managerExecutablePath: String) -> Bool {
        switch mapping.manager {
        case .brew:
            let result = runProcess([managerExecutablePath, "list", "--formula", mapping.identifier], timeout: 20)
            if result.status == 0 { return true }
            let cask = runProcess([managerExecutablePath, "list", "--cask", mapping.identifier], timeout: 20)
            return cask.status == 0
        case .npm:
            let result = runProcess([managerExecutablePath, "list", "-g", mapping.identifier, "--depth=0", "--json"], timeout: 30)
            if result.status == 0 { return true }
            guard let payload = parseJSONDictionary(result.stdout) else { return false }
            return packageExistsInNpmDependencies(payload, packageName: mapping.identifier)
        case .pipx:
            let result = runProcess([managerExecutablePath, "list", "--json"], timeout: 30)
            guard result.status == 0,
                  let payload = parseJSONDictionary(result.stdout),
                  let venvs = payload["venvs"] as? [String: Any] else { return false }
            return venvs.keys.contains(where: { pipPackageNamesEqual($0, mapping.identifier) })
        case .pip:
            let result = runProcess([managerExecutablePath, "-m", "pip", "show", mapping.identifier], timeout: 30)
            return result.status == 0
        case .unknown:
            return false
        }
    }

    func installedAndLatestVersions(mapping: AgentPackageMapping,
                                    managerExecutablePath: String) -> (installed: String?, latest: String?) {
        switch mapping.manager {
        case .brew:
            return brewInstalledAndLatest(formula: mapping.identifier, brewPath: managerExecutablePath)
        case .npm:
            let installed = npmInstalledVersion(package: mapping.identifier, npmPath: managerExecutablePath)
            let latest = npmLatestVersion(package: mapping.identifier, npmPath: managerExecutablePath)
            return (installed, latest)
        case .pipx:
            let installed = pipxInstalledVersion(package: mapping.identifier, pipxPath: managerExecutablePath)
            let latest = pipLatestVersion(package: mapping.identifier)
            return (installed, latest)
        case .pip:
            let installed = pipInstalledVersion(package: mapping.identifier, pythonPath: managerExecutablePath)
            let latest = pipLatestVersion(package: mapping.identifier)
            return (installed, latest)
        case .unknown:
            return (nil, nil)
        }
    }

    func resolveInstalledAndLatestVersions(manager: AgentPackageManager,
                                           identifiers: [String],
                                           managerExecutablePath: String) -> (identifier: String, installed: String?, latest: String?) {
        let candidates = identifiers.isEmpty ? [""] : identifiers
        var firstAttempt: (identifier: String, installed: String?, latest: String?)?
        for identifier in candidates where !identifier.isEmpty {
            let mapping = AgentPackageMapping(manager: manager, identifier: identifier)
            let versions = installedAndLatestVersions(mapping: mapping, managerExecutablePath: managerExecutablePath)
            let current = (identifier: identifier, installed: versions.installed, latest: versions.latest)
            if firstAttempt == nil {
                firstAttempt = current
            }
            if versions.installed != nil {
                return current
            }
        }
        return firstAttempt ?? (identifier: identifiers.first ?? "", installed: nil, latest: nil)
    }

    func inferredPackageIdentifier(from binaryPath: String?, manager: AgentPackageManager) -> String? {
        guard let binaryPath,
              !binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let resolvedPath = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path

        switch manager {
        case .npm:
            if let scoped = regexMatch(in: resolvedPath, pattern: "/node_modules/(@[^/]+/[^/]+)/") {
                return scoped
            }
            return regexMatch(in: resolvedPath, pattern: "/node_modules/([^/]+)/")
        case .brew:
            return regexMatch(in: resolvedPath.lowercased(), pattern: "/cellar/([^/]+)/")
        case .pipx:
            return regexMatch(in: resolvedPath, pattern: "/pipx/venvs/([^/]+)/")
        case .pip, .unknown:
            return nil
        }
    }

    func brewInstalledAndLatest(formula: String, brewPath: String) -> (installed: String?, latest: String?) {
        let result = runProcess([brewPath, "info", "--json=v2", formula], timeout: 45)
        guard result.status == 0,
              let payload = parseJSONDictionary(result.stdout) else { return (nil, nil) }

        if let formulae = payload["formulae"] as? [[String: Any]],
           let first = formulae.first {
            var installed: String?
            if let installedEntries = first["installed"] as? [[String: Any]],
               let version = installedEntries.first?["version"] as? String {
                installed = normalizeVersion(version)
            }

            var latest: String?
            if let versions = first["versions"] as? [String: Any],
               let stable = versions["stable"] as? String {
                latest = normalizeVersion(stable)
            }

            if installed != nil || latest != nil {
                return (installed, latest)
            }
        }

        if let casks = payload["casks"] as? [[String: Any]],
           let first = casks.first {
            let installed: String? = {
                if let raw = first["installed"] as? String { return raw }
                if let raw = first["installed"] as? [String] { return raw.first }
                return nil
            }()
            let latest = first["version"] as? String
            return (normalizeVersion(installed), normalizeVersion(latest))
        }

        return (nil, nil)
    }

    func npmInstalledVersion(package: String, npmPath: String) -> String? {
        let result = runProcess([npmPath, "list", "-g", package, "--depth=0", "--json"], timeout: 45)
        guard let payload = parseJSONDictionary(result.stdout) else { return nil }
        if let dependencies = payload["dependencies"] as? [String: Any] {
            for (name, value) in dependencies where pipPackageNamesEqual(name, package) {
                if let pkg = value as? [String: Any], let version = pkg["version"] as? String {
                    return normalizeVersion(version)
                }
            }
        }
        return nil
    }

    func npmLatestVersion(package: String, npmPath: String) -> String? {
        let result = runProcess([npmPath, "view", package, "version"], timeout: 45)
        guard result.status == 0 else { return nil }
        return normalizeVersion(result.stdout)
    }

    func pipInstalledVersion(package: String, pythonPath: String) -> String? {
        let result = runProcess([pythonPath, "-m", "pip", "show", package], timeout: 45)
        guard result.status == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.lowercased().hasPrefix("version:") {
                return normalizeVersion(String(text.dropFirst("Version:".count)))
            }
        }
        return nil
    }

    func pipxInstalledVersion(package: String, pipxPath: String) -> String? {
        let result = runProcess([pipxPath, "list", "--json"], timeout: 45)
        guard result.status == 0,
              let payload = parseJSONDictionary(result.stdout),
              let venvs = payload["venvs"] as? [String: Any] else { return nil }

        for (name, value) in venvs where pipPackageNamesEqual(name, package) {
            guard let entry = value as? [String: Any] else { continue }
            if let metadata = entry["metadata"] as? [String: Any],
               let main = metadata["main_package"] as? [String: Any],
               let version = main["package_version"] as? String {
                return normalizeVersion(version)
            }
            if let metadata = entry["metadata"] as? [String: Any],
               let version = metadata["package_version"] as? String {
                return normalizeVersion(version)
            }
        }
        return nil
    }

    func pipLatestVersion(package: String) -> String? {
        guard let pythonPath = managerExecutablePath(for: .pip) else { return nil }
        let result = runProcess([pythonPath, "-m", "pip", "index", "versions", package], timeout: 60)
        guard result.status == 0 else { return nil }
        let raw = result.stdout
        if let availableLine = raw
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.lowercased().contains("available versions:") }) {
            let pieces = availableLine.components(separatedBy: ":")
            if pieces.count >= 2 {
                let first = pieces[1]
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first
                if let first {
                    return normalizeVersion(first)
                }
            }
        }
        return normalizeVersion(raw)
    }

    func packageExistsInNpmDependencies(_ payload: [String: Any], packageName: String) -> Bool {
        guard let dependencies = payload["dependencies"] as? [String: Any] else { return false }
        return dependencies.keys.contains(where: { pipPackageNamesEqual($0, packageName) })
    }

    func parseJSONDictionary(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    func normalizeVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if let semver = extractSemver(from: trimmed) {
            return semver
        }

        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func extractSemver(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?i)v?(\\d+\\.\\d+\\.\\d+)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    func isNewerVersion(_ latest: String, than installed: String) -> Bool {
        guard let latestParts = semverParts(latest),
              let installedParts = semverParts(installed) else {
            return latest != installed
        }
        return latestParts.lexicographicallyPrecedes(installedParts) == false && latestParts != installedParts
    }

    func semverParts(_ value: String) -> [Int]? {
        guard let semver = extractSemver(from: value) else { return nil }
        let parts = semver.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts
    }

    func pipPackageNamesEqual(_ lhs: String, _ rhs: String) -> Bool {
        normalizePackageName(lhs) == normalizePackageName(rhs)
    }

    func normalizePackageName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    func binarySearchDirectories() -> [String] {
        var out: [String] = []
        var seen = Set<String>()

        func appendPath(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard !expanded.isEmpty, !seen.contains(expanded) else { return }
            seen.insert(expanded)
            out.append(expanded)
        }

        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            for component in path.split(separator: ":") {
                appendPath(String(component))
            }
        }

        for path in Self.fallbackBinarySearchPaths { appendPath(path) }
        for path in Self.userLevelBinarySearchPaths { appendPath(path) }
        return out
    }

    func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if seen.insert(value).inserted {
                out.append(value)
            }
        }
        return out
    }

    func shellCandidates() -> [String] {
        let fm = FileManager.default
        let envShell = ProcessInfo.processInfo.environment["SHELL"]
        let defaults = [envShell, "/bin/zsh", "/bin/bash", "/bin/sh"]
        var out: [String] = []
        var seen = Set<String>()
        for shell in defaults.compactMap({ $0 }) where !shell.isEmpty {
            if seen.contains(shell) { continue }
            seen.insert(shell)
            if fm.isExecutableFile(atPath: shell) {
                out.append(shell)
            }
        }
        return out
    }

    func parseCommandPath(_ output: String, command: String) -> String? {
        let fm = FileManager.default
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != command }

        for line in lines {
            if line.hasPrefix("/"), fm.isExecutableFile(atPath: line) {
                return line
            }
            if let marker = line.range(of: " is /") {
                let candidate = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.hasPrefix("/"), fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            let token = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if token.hasPrefix("/"), fm.isExecutableFile(atPath: token) {
                return token
            }
        }
        return nil
    }

    func escapeForShell(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if !value.contains("'") { return "'\(value)'" }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    func regexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    func resolvedUserHomeDirectory() -> String {
        if let byUser = NSHomeDirectoryForUser(NSUserName()), !byUser.isEmpty { return byUser }
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty { return envHome }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    func readShebang(from path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    func runProcess(_ command: [String], timeout: TimeInterval) -> CommandResult {
        guard let executable = command.first else {
            return CommandResult(status: 127, stdout: "", stderr: "No executable provided.", timedOut: false)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        var env = ProcessInfo.processInfo.environment
        if (env["HOME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env["HOME"] = resolvedUserHomeDirectory()
        }
        let executableDir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let mergedPaths = orderedUniqueStrings([executableDir] + binarySearchDirectories())
        if !mergedPaths.isEmpty {
            env["PATH"] = mergedPaths.joined(separator: ":")
        }
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(status: 127, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        let timedOut = waitResult == .timedOut
        if timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1.0)
        }

        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }
}
