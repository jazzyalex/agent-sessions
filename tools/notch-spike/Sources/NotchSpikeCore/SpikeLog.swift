import Foundation

/// Plain file log; the spike's only evidence channel (os_log does not reach `log show` here).
public final class SpikeLog: @unchecked Sendable {
    public static let shared = SpikeLog(url: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/AgentSessions-NotchSpike/spike.log"))

    private let url: URL
    private let queue = DispatchQueue(label: "notch-spike.log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public init(url: URL) {
        self.url = url
    }

    public func write(_ event: String, _ fields: [String: String] = [:]) {
        let now = Date()
        queue.async { [self] in
            let pairs = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
            let line = "\(formatter.string(from: now))\t\(event)\t\(pairs)\n"
            append(Data(line.utf8))
        }
    }

    public func flushForTesting() {
        queue.sync {}
    }

    private func append(_ data: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
