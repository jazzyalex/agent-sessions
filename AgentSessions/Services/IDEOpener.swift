import Foundation
import AppKit

struct IDEOpener {
    enum Target: String, CaseIterable, Sendable {
        case systemDefault
        case cursor
        case vscode
    }

    static func open(path: String, line: Int?, column: Int?, target: Target, binaryOverride: String? = nil) {
        switch target {
        case .systemDefault:
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .cursor:
            if openWithCLI(path: path, line: line, column: column, cliName: "cursor", binaryOverride: binaryOverride) {
                return
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .vscode:
            if openWithCLI(path: path, line: line, column: column, cliName: "code", binaryOverride: binaryOverride) {
                return
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private static func openWithCLI(path: String,
                                    line: Int?,
                                    column: Int?,
                                    cliName: String,
                                    binaryOverride: String?) -> Bool {
        let binary = (binaryOverride?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? cliName
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        let gotoTarget: String = {
            guard let line else { return path }
            if let column {
                return "\(path):\(line):\(column)"
            }
            return "\(path):\(line)"
        }()

        process.arguments = [binary, "--goto", gotoTarget]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
