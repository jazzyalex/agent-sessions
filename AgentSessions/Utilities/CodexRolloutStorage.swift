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
    ///
    /// `onDecodedBytes` receives the size of each decoded chunk of a compressed
    /// rollout, before line splitting, so a caller can count the exact decoded size.
    static func lineReader(for url: URL,
                           chunkSize: Int = 64 * 1024,
                           maximumBytes: UInt64? = nil,
                           propagatesReadErrors: Bool = false,
                           onDecodedBytes: ((Int) -> Void)? = nil) -> JSONLReader? {
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
                           readChunk: { handle, count in
                               let chunk = try decoder.read(from: handle, upTo: count)
                               onDecodedBytes?(chunk.count)
                               return chunk
                           })
    }

    /// The decoded size a compressed rollout's first frame header records. Codex
    /// pledges the source size, so its files carry it. Nil when the header has no
    /// size or cannot be read.
    static func frameContentSize(of storage: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: storage) else { return nil }
        defer { try? handle.close() }
        return frameContentSize(from: handle)
    }

    /// The frame-header decoded size and mtime of a compressed rollout, read without
    /// following a symlink: the path is opened `O_NOFOLLOW | O_NONBLOCK` and must be a
    /// regular file. Nil for a symlink, a FIFO or other special file, or no file.
    /// `decodedSize` is nil when the header records no size.
    static func regularCompressedFileInfo(at path: URL) -> (decodedSize: UInt64?, modified: Date)? {
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (frameContentSize(from: handle), modified)
    }

    private static func frameContentSize(from handle: FileHandle) -> UInt64? {
        guard let header = try? handle.read(upToCount: 18), !header.isEmpty else { return nil }
        let size = header.withUnsafeBytes { raw in
            ZSTD_getFrameContentSize(raw.baseAddress, raw.count)
        }
        // ZSTD_CONTENTSIZE_UNKNOWN is UInt64.max and ZSTD_CONTENTSIZE_ERROR is one less.
        guard size < UInt64.max - 1 else { return nil }
        return size
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

    /// True when the decoded rollout contains `needle`. Streams the bytes and keeps
    /// nothing on disk. A decode error ends the search with what was read so far.
    static func decodedStreamContains(_ needle: String, for url: URL) -> Bool {
        let pattern = Data(needle.utf8)
        guard !pattern.isEmpty,
              let storage = storageURL(for: url),
              let handle = try? FileHandle(forReadingFrom: storage) else { return false }
        defer { try? handle.close() }
        guard isCompressedRollout(storage) else {
            var carry = Data()
            while let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                carry.append(chunk)
                if carry.range(of: pattern) != nil { return true }
                carry = carry.suffix(pattern.count - 1)
            }
            return false
        }
        let decoder = ZstdStreamDecoder()
        var carry = Data()
        while let chunk = try? decoder.read(from: handle, upTo: 1024 * 1024), !chunk.isEmpty {
            carry.append(chunk)
            if carry.range(of: pattern) != nil { return true }
            carry = carry.suffix(pattern.count - 1)
        }
        return false
    }

    /// A plain-file URL that supports seeking: the rollout itself when it is plain,
    /// else a decoded copy in the app's cache.
    ///
    /// Copies are keyed by the canonical path and the compressed file's size and
    /// modification time. One caller decodes a given key at a time; the others wait
    /// and reuse its copy. A rollout that decodes to more than
    /// `materializedCacheByteLimit` throws `limitExceeded`. Copies are evicted
    /// oldest first past the limit, except copies used in the last minute, so a
    /// caller that was just handed a URL can still open it.
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

        try withMaterializationLock(forKey: key) {
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                return
            }
            if let known = frameContentSize(of: storage), known > materializedCacheByteLimit {
                throw ZstdStreamDecoder.DecodeError.limitExceeded
            }
            let temp = directory.appendingPathComponent(key + ".\(UUID().uuidString).tmp")
            // After a successful move the temp path is gone and this is a no-op.
            defer { try? fileManager.removeItem(at: temp) }
            try decodeCompressed(storage, to: temp, limit: materializedCacheByteLimit, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: temp, to: target)
            } catch {
                // Another process published the same key first; its copy is identical.
                guard fileManager.fileExists(atPath: target.path) else { throw error }
            }
        }

        cacheLock.lock()
        evictMaterializedCopies(in: directory, keeping: target, fileManager: fileManager)
        cacheLock.unlock()
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

    /// `seekableURL(forPath:)` for image scanners. Returns nil for a compressed
    /// rollout that holds no `data:image` payload, so sessions without images are
    /// never decoded to disk. The prefix is the one `Base64ImageDataURLScanner`
    /// starts from, which also accepts a JSON-escaped `data:image\/png`.
    static func seekableURLForImageScan(forPath path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        guard isStoredCompressed(url) else { return url }
        guard decodedStreamContains("data:image", for: url) else { return nil }
        return try? randomAccessURL(for: url)
    }

    /// Decodes a compressed rollout into a new temporary file that the caller owns
    /// and deletes. The file gets the compressed file's modification time.
    ///
    /// Opens the `.zst` with `O_NOFOLLOW` and requires a regular file whose size and
    /// mtime do not change while it is decoded, the same source rules the archive
    /// manager applies to the files it copies.
    static func decodedTemporaryCopy(for url: URL, fileManager: FileManager = .default) throws -> URL {
        guard let storage = storageURL(for: url, fileManager: fileManager), isCompressedRollout(storage) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: compressedSibling(of: url).path])
        }
        // O_NONBLOCK keeps a FIFO at this path from blocking the open; fstat rejects it.
        let descriptor = Darwin.open(storage.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: storage.path])
        }

        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("AgentSessions-codex-\(UUID().uuidString).jsonl")
        do {
            try decodeCompressed(from: input, to: temp, limit: nil, fileManager: fileManager)
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: storage.path])
            }
            let mtime = Date(timeIntervalSince1970: TimeInterval(before.st_mtimespec.tv_sec)
                             + TimeInterval(before.st_mtimespec.tv_nsec) / 1_000_000_000)
            try fileManager.setAttributes([.modificationDate: mtime], ofItemAtPath: temp.path)
            return temp
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    private static func decodeCompressed(_ storage: URL,
                                         to destination: URL,
                                         limit: UInt64?,
                                         fileManager: FileManager) throws {
        let input = try FileHandle(forReadingFrom: storage)
        defer { try? input.close() }
        try decodeCompressed(from: input, to: destination, limit: limit, fileManager: fileManager)
    }

    private static func decodeCompressed(from input: FileHandle,
                                         to destination: URL,
                                         limit: UInt64?,
                                         fileManager: FileManager) throws {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let decoder = ZstdStreamDecoder()
        var written: UInt64 = 0
        while true {
            let chunk = try decoder.read(from: input, upTo: 1024 * 1024)
            if chunk.isEmpty { break }
            written += UInt64(chunk.count)
            if let limit, written > limit { throw ZstdStreamDecoder.DecodeError.limitExceeded }
            try output.write(contentsOf: chunk)
        }
    }

    // MARK: - Materialized cache

    /// Serializes eviction passes.
    private static let cacheLock = NSLock()
    /// A fixed set of locks; a key always maps to the same one, so one caller decodes
    /// a given key at a time. Two keys can share a lock and then wait for each other.
    private static let keyLocks: [NSLock] = (0..<16).map { _ in NSLock() }

    private static func withMaterializationLock(forKey key: String, _ body: () throws -> Void) throws {
        // The key starts with a hex SHA-256, so its first digit spreads keys evenly.
        let stripe = (Int(String(key.prefix(1)), radix: 16) ?? 0) % keyLocks.count
        let lock = keyLocks[stripe]
        lock.lock()
        defer { lock.unlock() }
        try body()
    }

    private static func materializedCacheDirectory(fileManager: FileManager) throws -> URL {
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.triada.AgentSessions", isDirectory: true)
            .appendingPathComponent("CodexRollouts", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Removes temp files left by a crash (older than an hour), then decoded copies
    /// oldest first until the total fits `materializedCacheByteLimit`. Copies used
    /// in the last minute are kept even when that leaves the total over the limit.
    static func evictMaterializedCopies(in directory: URL,
                                        keeping keep: URL,
                                        now: Date = Date(),
                                        fileManager: FileManager = .default) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: UInt64, date: Date)] = []
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if url.pathExtension == "tmp" {
                if now.timeIntervalSince(date) > 3600 { try? fileManager.removeItem(at: url) }
                continue
            }
            guard url.pathExtension == "jsonl" else { continue }
            files.append((url, UInt64(values.fileSize ?? 0), date))
        }
        var total = files.reduce(UInt64(0)) { $0 + $1.size }
        guard total > materializedCacheByteLimit else { return }
        files.sort { $0.date < $1.date }
        for file in files where total > materializedCacheByteLimit {
            guard file.url.path != keep.path, now.timeIntervalSince(file.date) > 60 else { continue }
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
        /// The file holds no zstd frame at all (zero bytes).
        case empty
    }

    private var stream: OpaquePointer?
    private var input: [UInt8] = []
    private var inputPosition = 0
    private var reachedEndOfInput = false
    private var frameComplete = true
    /// Set once the decoder consumes any input; EOF before that is not a stream.
    private var consumedInput = false
    private var finished = false
    private var bytesReadFromHandle: UInt64 = 0

    /// Compressed bytes the decoder has consumed so far. Excludes input read ahead
    /// from the file handle but not yet decoded.
    var compressedBytesConsumed: UInt64 {
        bytesReadFromHandle - UInt64(max(0, input.count - inputPosition))
    }

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
                    bytesReadFromHandle += UInt64(chunk.count)
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
            if inputPosition > inputBefore { consumedInput = true }
            if inputPosition > inputBefore || produced > outputBefore {
                frameComplete = (result == 0)
            }

            let madeProgress = inputPosition > inputBefore || produced > outputBefore
            if !madeProgress && inputPosition >= input.count && reachedEndOfInput {
                guard consumedInput else { throw DecodeError.empty }
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
