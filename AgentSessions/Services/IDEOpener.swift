import Foundation
import AppKit

struct IDEOpener {
    enum Target: String, CaseIterable, Sendable {
        case systemDefault
        case cursor
        case vscode
    }

    static var cliLaunchTimeout: TimeInterval = 3.0
    static var cliLaunchQueue: DispatchQueue = DispatchQueue(label: "com.triada.AgentSessions.ide-opener",
                                                             qos: .utility,
                                                             attributes: .concurrent)
    static var openURLHandler: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    static var cliRunner: (_ binary: String, _ gotoTarget: String, _ timeout: TimeInterval) -> Bool = runCLIProcess

    static func open(path: String, line: Int?, column: Int?, target: Target, binaryOverride: String? = nil) {
        switch target {
        case .systemDefault:
            openURLHandler(URL(fileURLWithPath: path))
        case .cursor:
            openWithCLIAsync(path: path, line: line, column: column, cliName: "cursor", binaryOverride: binaryOverride)
        case .vscode:
            openWithCLIAsync(path: path, line: line, column: column, cliName: "code", binaryOverride: binaryOverride)
        }
    }

    private static func openWithCLIAsync(path: String,
                                         line: Int?,
                                         column: Int?,
                                         cliName: String,
                                         binaryOverride: String?) {
        let binary = (binaryOverride?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? cliName
        let fileURL = URL(fileURLWithPath: path)

        let gotoTarget: String = {
            guard let line else { return path }
            if let column {
                return "\(path):\(line):\(column)"
            }
            return "\(path):\(line)"
        }()

        cliLaunchQueue.async {
            let didOpenWithCLI = cliRunner(binary, gotoTarget, cliLaunchTimeout)
            guard !didOpenWithCLI else { return }
            DispatchQueue.main.async {
                openURLHandler(fileURL)
            }
        }
    }

    static func resetTestingHooks() {
        cliLaunchTimeout = 3.0
        cliLaunchQueue = DispatchQueue(label: "com.triada.AgentSessions.ide-opener",
                                       qos: .utility,
                                       attributes: .concurrent)
        openURLHandler = { url in
            NSWorkspace.shared.open(url)
        }
        cliRunner = runCLIProcess
    }

    private static func runCLIProcess(binary: String, gotoTarget: String, timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binary, "--goto", gotoTarget]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            done.signal()
        }

        do {
            try process.run()
        } catch {
            return false
        }

        let timeoutResult = done.wait(timeout: .now() + timeout)
        if timeoutResult == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            return false
        }

        return process.terminationStatus == 0
    }
}
