import Foundation

@MainActor
final class CodexResumeSettings: ObservableObject {
    static let shared = CodexResumeSettings()

    enum Keys {
        static let defaultWorkingDirectory = "CodexResumeDefaultWorkingDirectory"
        static let defaultLaunchMode = "CodexResumeLaunchMode"
        static let binaryOverride = "CodexResumeBinaryOverride"
        static let sessionOverrides = "CodexResumeSessionWorkingDirectories"
    }

    @Published var defaultWorkingDirectory: String
    @Published var launchMode: CodexLaunchMode
    @Published var binaryOverride: String

    private var sessionWorkingDirectories: [String: String]
    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedDir = defaults.string(forKey: Keys.defaultWorkingDirectory) ?? ""
        defaultWorkingDirectory = storedDir

        if let raw = defaults.string(forKey: Keys.defaultLaunchMode), let mode = CodexLaunchMode(rawValue: raw) {
            launchMode = mode
        } else {
            launchMode = .terminal
        }

        binaryOverride = defaults.string(forKey: Keys.binaryOverride) ?? ""
        sessionWorkingDirectories = defaults.dictionary(forKey: Keys.sessionOverrides) as? [String: String] ?? [:]
    }

    func setDefaultWorkingDirectory(_ path: String) {
        defaultWorkingDirectory = path
        defaults.set(path, forKey: Keys.defaultWorkingDirectory)
    }

    func setLaunchMode(_ mode: CodexLaunchMode) {
        launchMode = mode
        defaults.set(mode.rawValue, forKey: Keys.defaultLaunchMode)
    }

    func setBinaryOverride(_ path: String) {
        binaryOverride = path
        defaults.set(path, forKey: Keys.binaryOverride)
    }

    func workingDirectory(for sessionID: String) -> String? {
        sessionWorkingDirectories[sessionID]
    }

    func setWorkingDirectory(_ path: String?, for sessionID: String) {
        if let path, !path.isEmpty {
            sessionWorkingDirectories[sessionID] = path
        } else {
            sessionWorkingDirectories.removeValue(forKey: sessionID)
        }
        defaults.set(sessionWorkingDirectories, forKey: Keys.sessionOverrides)
        objectWillChange.send()
    }

    func effectiveWorkingDirectory(for session: Session) -> String? {
        if let override = workingDirectory(for: session.id) {
            return override
        }
        if let sessionCwd = session.cwd {
            return sessionCwd
        }
        if !defaultWorkingDirectory.isEmpty { return defaultWorkingDirectory }
        return nil
    }
}

extension CodexResumeSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "CodexResumeTests") ?? .standard) -> CodexResumeSettings {
        CodexResumeSettings(defaults: defaults)
    }
}
