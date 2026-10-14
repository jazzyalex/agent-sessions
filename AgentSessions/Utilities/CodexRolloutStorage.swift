import Foundation
import CryptoKit
import libzstd

/// Where a Codex rollout's bytes live on disk.
///
/// Codex's `local_thread_store_compression` replaces a rollout that has not changed
/// for 7 days, `rollout-….jsonl`, with `rollout-….jsonl.zst` (one zstd stream of the
/// same bytes) and deletes the plain file. Resuming the thread reverses it. Codex's
/// own readers prefer the plain file when both exist.
///
/// The app keeps every Codex session on its canonical `.jsonl` path, whichever form
/// is on disk. Session ids are a hash of that path, so a session keeps its id, its
/// star, its pin and its index rows when Codex compresses or restores the file.
enum CodexRolloutStorage {
    static let compressedSuffix = ".zst"

    /// Cap for readers that decode a whole rollout into memory.
    static let maxInMemoryDecodedBytes = 512 * 1024 * 1024
    /// Cap for decoded copies kept for random-access readers (image spans).
    static let materializedCacheByteLimit: UInt64 = 1024 * 1024 * 1024

    // MARK: - Names

    static func isCompressedRollout(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("rollout-") && name.lowercased().hasSuffix(".jsonl.zst")
    }

    /// True for `rollout-*.jsonl` and `rollout-*.jsonl.zst`.
    static func isRolloutFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("rollout-") else { return false }
        let lower = name.lowercased()
        return lower.hasSuffix(".jsonl") || lower.hasSuffix(".jsonl.zst")
    }

    /// The `.jsonl` path a rollout is known by. Plain paths are returned unchanged.
    static func canonicalURL(for url: URL) -> URL {
        guard isCompressedRollout(url) else { return url }
        let name = url.lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(String(name.dropLast(compressedSuffix.count)))
    }

    static func compressedSibling(of url: URL) -> URL {
        let canonical = canonicalURL(for: url)
        return canonical.deletingLastPathComponent()
            .appendingPathComponent(canonical.lastPathComponent + compressedSuffix)
    }

    /// Maps discovered rollout files to canonical URLs, dropping a compressed file
    /// whose plain sibling was also found. Order of first appearance is kept.
    static func canonicalRolloutURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            let canonical = canonicalURL(for: url)
            if seen.insert(canonical.path).inserted {
                result.append(canonical)
            }
        }
        return result
    }

    // MARK: - Resolution

    /// The file that holds the rollout now: the plain file when it exists, else the
    /// compressed sibling. Nil when neither exists. Paths that are not Codex
    /// rollouts resolve only to themselves.
    static func storageURL(for url: URL, fileManager: FileManager = .default) -> URL? {
        let canonical = canonicalURL(for: url)
        if fileManager.fileExists(atPath: canonical.path) { return canonical }
        guard canonical.lastPathComponent.hasPrefix("rollout-"),
              canonical.pathExtension.lowercased() == "jsonl" else { return nil }
        let compressed = compressedSibling(of: canonical)
        return fileManager.fileExists(atPath: compressed.path) ? compressed : nil
    }

    static func exists(atPath path: String, fileManager: FileManager = .default) -> Bool {
        storageURL(for: URL(fileURLWithPath: path), fileManager: fileManager) != nil
    }

    static func isStoredCompressed(_ url: URL) -> Bool {
        guard let storage = storageURL(for: url) else { return false }
        return isCompressedRollout(storage)
    }

    // MARK: - Readers

    /// A line reader over the rollout's decoded bytes.
    ///
    /// `maximumBytes` bounds a plain read to a stat snapshot. A compressed file is
    /// never appended in place (Codex restores it to plain first), so the bound does
    /// not apply and the whole stream is read.
    static func lineReader(for url: URL,
                           chunkSize: Int = 64 * 1024,
                           maximumBytes: UInt64? = nil,
                           propagatesReadErrors: Bool = false) -> JSONLReader? {
        guard let storage = storageURL(for: url) else { return nil }
        guard isCompressedRollout(storage) else {
            return JSONLReader(url: storage,
                               chunkSize: chunkSize,
                               maximumBytes: maximumBytes,
                               propagatesReadErrors: propagatesReadErrors)
        }
        let decoder = ZstdStreamDecoder()
        return JSONLReader(url: storage,
                           chunkSize: chunkSize,
                           maximumBytes: nil,
                           propagatesReadErrors: propagatesReadErrors,
                           readChunk: { handle, count in try decoder.read(from: handle, upTo: count) })
    }

    /// The rollout's decoded bytes. Throws when a compressed rollout decodes to more
    /// than `limit` bytes.
    static func readAllData(for url: URL, limit: Int = maxInMemoryDecodedBytes) throws -> Data {
        guard let storage = storageURL(for: url) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard isCompressedRollout(storage) else {
            return try Data(contentsOf: storage, options: .mappedIfSafe)
        }
        let handle = try FileHandle(forReadingFrom: storage)
        defer { try? handle.close() }
        let decoder = ZstdStreamDecoder()
        var output = Data()
        while true {
            let chunk = try decoder.read(from: handle, upTo: 1024 * 1024)
            if chunk.isEmpty { break }
            output.append(chunk)
            if output.count > limit { throw ZstdStreamDecoder.DecodeError.limitExceeded }
        }
        return output
    }

    /// At most `maxBytes` decoded bytes from the start of the rollout.
    static func readHead(for url: URL, maxBytes: Int) throws -> Data {
        guard let storage = storageURL(for: url) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forReadingFrom: storage)
        defer { try? handle.close() }
        guard isCompressedRollout(storage) else {
            return try handle.read(upToCount: maxBytes) ?? Data()
        }
        let decoder = ZstdStreamDecoder()
        var output = Data()
        while output.count < maxBytes {
            let chunk = try decoder.read(from: handle, upTo: min(256 * 1024, maxBytes - output.count))
            if chunk.isEmpty { break }
            output.append(chunk)
        }
        return output
    }

    /// The decoded head (up to `headBytes`) and tail (the last `tailBytes`) of a
    /// compressed rollout, plus its decoded size. Decodes the stream once.
    static func readCompressedHeadAndTail(_ storage: URL,
                                          headBytes: Int,
                                          tailBytes: Int) throws -> (head: Data, tail: Data, decodedSize: UInt64) {
        let handle = try FileHandle(forReadingFrom: storage)
        defer { try? handle.close() }
        let decoder = ZstdStreamDecoder()
        var head = Data()
        var tail = Data()
        var total: UInt64 = 0
        while true {
            let chunk = try decoder.read(from: handle, upTo: 256 * 1024)
            if chunk.isEmpty { break }
            total += UInt64(chunk.count)
            if head.count < headBytes {
                head.append(chunk.prefix(headBytes - head.count))
            }
            tail.append(chunk)
            if tail.count > tailBytes * 2 {
                tail = tail.suffix(tailBytes)
            }
        }
        if tail.count > tailBytes { tail = tail.suffix(tailBytes) }
        return (Data(head), Data(tail), total)
    }

    /// A plain-file URL that supports seeking: the rollout itself when it is plain,
    /// else a decoded copy in the app's cache. Copies are keyed by the compressed
    /// file's size and modification time and evicted oldest first past
    /// `materializedCacheByteLimit`.
    static func randomAccessURL(for url: URL, fileManager: FileManager = .default) throws -> URL {
        guard let storage = storageURL(for: url, fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard isCompressedRollout(storage) else { return storage }

        let attrs = try fileManager.attributesOfItem(atPath: storage.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = sha256(canonicalURL(for: storage).path) + "-\(size)-\(Int64(mtime * 1000))"
        let directory = try materializedCacheDirectory(fileManager: fileManager)
        let target = directory.appendingPathComponent(key + ".jsonl")
        if fileManager.fileExists(atPath: target.path) {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }

        let temp = directory.appendingPathComponent(key + ".\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        do {
            let input = try FileHandle(forReadingFrom: storage)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            let decoder = ZstdStreamDecoder()
            while true {
                let chunk = try decoder.read(from: input, upTo: 1024 * 1024)
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
        if fileManager.fileExists(atPath: target.path) {
            try? fileManager.removeItem(at: temp)
        } else {
            try fileManager.moveItem(at: temp, to: target)
        }
        evictMaterializedCopies(in: directory, keeping: target, fileManager: fileManager)
        return target
    }

    /// A URL for readers that seek by byte offset (image spans). For a compressed
    /// Codex rollout this is the decoded cache copy; every other path is returned
    /// as-is, so callers keep their own missing-file handling.
    static func seekableURL(forPath path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        guard isStoredCompressed(url) else { return url }
        return (try? randomAccessURL(for: url)) ?? url
    }

    private static func materializedCacheDirectory(fileManager: FileManager) throws -> URL {
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.triada.AgentSessions", isDirectory: true)
            .appendingPathComponent("CodexRollouts", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func evictMaterializedCopies(in directory: URL, keeping keep: URL, fileManager: FileManager) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var files = entries.compactMap { url -> (url: URL, size: UInt64, date: Date)? in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, UInt64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(UInt64(0)) { $0 + $1.size }
        guard total > materializedCacheByteLimit else { return }
        files.sort { $0.date < $1.date }
        for file in files where total > materializedCacheByteLimit && file.url.path != keep.path {
            if (try? fileManager.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Incremental zstd decoder over a file handle. Each `read` returns up to `count`
/// decoded bytes and an empty `Data` only at the end of the stream. Concatenated
/// frames are decoded in order; a stream that ends inside a frame throws.
final class ZstdStreamDecoder {
    enum DecodeError: Error, Equatable {
        case allocationFailed
        case corrupt(String)
        case truncated
        case limitExceeded
    }

    private var stream: OpaquePointer?
    private var input: [UInt8] = []
    private var inputPosition = 0
    private var reachedEndOfInput = false
    private var frameComplete = true
    private var finished = false

    deinit {
        if let stream { _ = ZSTD_freeDStream(stream) }
    }

    func read(from handle: FileHandle, upTo count: Int) throws -> Data {
        guard count > 0, !finished else { return Data() }
        if stream == nil {
            guard let created = ZSTD_createDStream() else { throw DecodeError.allocationFailed }
            stream = created
            let result = ZSTD_initDStream(created)
            guard ZSTD_isError(result) == 0 else { throw DecodeError.corrupt(Self.errorName(result)) }
        }

        var output = [UInt8](repeating: 0, count: count)
        var produced = 0
        while produced < count {
            if inputPosition >= input.count, !reachedEndOfInput {
                let chunk = try handle.read(upToCount: 128 * 1024) ?? Data()
                if chunk.isEmpty {
                    reachedEndOfInput = true
                } else {
                    input = [UInt8](chunk)
                    inputPosition = 0
                }
            }

            let inputBefore = inputPosition
            let outputBefore = produced
            let result: Int = input.withUnsafeBytes { inputRaw in
                output.withUnsafeMutableBytes { outputRaw in
                    var inBuffer = ZSTD_inBuffer(
                        src: inputRaw.baseAddress,
                        size: input.count,
                        pos: inputPosition
                    )
                    var outBuffer = ZSTD_outBuffer(
                        dst: outputRaw.baseAddress,
                        size: outputRaw.count,
                        pos: produced
                    )
                    let code = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                    inputPosition = inBuffer.pos
                    produced = outBuffer.pos
                    return code
                }
            }
            guard ZSTD_isError(result) == 0 else { throw DecodeError.corrupt(Self.errorName(result)) }
            if inputPosition > inputBefore || produced > outputBefore {
                frameComplete = (result == 0)
            }

            let madeProgress = inputPosition > inputBefore || produced > outputBefore
            if !madeProgress && inputPosition >= input.count && reachedEndOfInput {
                guard frameComplete else { throw DecodeError.truncated }
                finished = true
                break
            }
        }
        return Data(output.prefix(produced))
    }

    private static func errorName(_ code: Int) -> String {
        guard let name = ZSTD_getErrorName(code) else { return "zstd error \(code)" }
        return String(cString: name)
    }
}
