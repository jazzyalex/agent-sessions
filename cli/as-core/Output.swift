import Foundation

// stdout carries JSON only, one object per line. Core code logs with `print` (parser
// errors, DEBUG traces), so `redirectLogsToStderr()` keeps a private handle on the real
// stdout for results and points fd 1 at stderr.

private var jsonOut = FileHandle.standardOutput

func redirectLogsToStderr() {
    jsonOut = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
    dup2(STDERR_FILENO, STDOUT_FILENO)
}

/// Current JSON output schema. Bump when a field changes meaning or is removed.
let outputSchema = 1

func emit(_ object: [String: Any]) {
    var object = object
    object["schema"] = outputSchema
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    jsonOut.write(data + Data("\n".utf8))
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("as-core: \(message)\n".utf8))
    exit(code)
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func iso(_ date: Date?) -> Any {
    date.map { isoFormatter.string(from: $0) } ?? NSNull()
}

func iso(epochSeconds: Int64) -> Any {
    epochSeconds > 0 ? isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds))) : NSNull()
}

func orNull(_ value: Any?) -> Any { value ?? NSNull() }
