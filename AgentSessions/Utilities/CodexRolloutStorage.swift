import Foundation
import CoreFoundation
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
    /// not apply and the whole stream is read. `maximumDecodedBytes`
    /// instead caps either form at a logical history offset.
    ///
    /// `onDecodedBytes` receives the size of each decoded chunk of a compressed
    /// rollout, before line splitting, so a caller can count the exact decoded size.
    static func lineReader(for url: URL,
                           chunkSize: Int = 64 * 1024,
                           maximumBytes: UInt64? = nil,
                           maximumDecodedBytes: UInt64? = nil,
                           propagatesReadErrors: Bool = false,
                           onDecodedBytes: ((Int) -> Void)? = nil) -> JSONLReader? {
        guard let storage = storageURL(for: url) else { return nil }
        guard isCompressedRollout(storage) else {
            return JSONLReader(url: storage,
                               chunkSize: chunkSize,
                               maximumBytes: maximumDecodedBytes ?? maximumBytes,
                               propagatesReadErrors: propagatesReadErrors)
        }
        let decoder = ZstdStreamDecoder()
        return JSONLReader(url: storage,
                           chunkSize: chunkSize,
                           maximumBytes: maximumDecodedBytes,
                           propagatesReadErrors: propagatesReadErrors,
                           readChunk: { handle, count in
                               let chunk = try decoder.read(from: handle, upTo: count,
                                                            stopAtFrameBoundary: maximumDecodedBytes != nil)
                               onDecodedBytes?(chunk.count)
                               return chunk
                           })
    }

    /// The retained prefix of one earlier file in a paginated Codex rollout.
    struct HistoryPage: Equatable, Sendable {
        let url: URL
        let decodedBytes: UInt64
    }

    private struct HistoryBase {
        let pageID: String
        let decodedBytes: UInt64
    }

    private static func historyBase(in url: URL) -> HistoryBase? {
        guard let reader = lineReader(for: url, maximumDecodedBytes: 1_048_576) else { return nil }
        var head: String?
        _ = try? reader.forEachLineWhile { line in
            head = line
            return false
        }
        guard let head, let record = (try? JSONSerialization.jsonObject(with: Data(head.utf8))) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any],
              payload["history_mode"] as? String == "paginated",
              let base = payload["history_base"] as? [String: Any],
              let pageID = base["thread_id"] as? String, UUID(uuidString: pageID) != nil,
              // The byte cut belongs to the decoded file, even after Codex compresses it.
              let bytes = base["end_byte_offset"] as? NSNumber,
              CFGetTypeID(bytes) != CFBooleanGetTypeID(),
              let offset = UInt64(bytes.stringValue), offset > 0 else { return nil }
        return HistoryBase(pageID: pageID, decodedBytes: offset)
    }

    /// A contiguous chain, newest ancestor first. The caller stops at an
    /// unreadable prefix, so it never joins across a missing page.
    static func precedingHistoryPages(of url: URL, knownPaths: @autoclosure () -> [String]) -> [HistoryPage] {
        let canonical = canonicalURL(for: url)
        let name = canonical.lastPathComponent
        guard isRolloutFile(canonical),
              let range = name.range(of: "[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", options: .regularExpression),
              var base = historyBase(in: canonical) else { return [] }
        let sessionID = String(name[range])
        var known = canonicalRolloutURLs(knownPaths().filter { $0.contains(sessionID) }.map { URL(fileURLWithPath: $0) })
        var searched = false
        var seen: Set<URL> = [canonical]
        var pages: [HistoryPage] = []
        while pages.count < 64 {
            let suffix = base.pageID.caseInsensitiveCompare(sessionID) == .orderedSame
                ? "-\(sessionID).jsonl" : "-\(sessionID)_\(base.pageID).jsonl"
            func findPage() -> URL? {
                known.first { path in
                    path.lastPathComponent.lowercased().hasSuffix(suffix.lowercased()) && storageURL(for: path) != nil
                }
            }
            if findPage() == nil, !searched {
                searched = true
                known += nearbyHistoryRollouts(to: canonical, sessionID: sessionID)
            }
            guard let page = findPage(), seen.insert(page).inserted else { break }
            pages.append(HistoryPage(url: page, decodedBytes: base.decodedBytes))
            guard let next = historyBase(in: page) else { break }
            base = next
        }
        return pages
    }

    private static func nearbyHistoryRollouts(to url: URL, sessionID: String) -> [URL] {
        let manager = FileManager.default
        let day = url.deletingLastPathComponent()
        let month = day.deletingLastPathComponent()
        let year = month.deletingLastPathComponent()
        func children(of folder: URL) -> [URL] {
            (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        func numberedChildren(of folder: URL) -> [URL] {
            children(of: folder).filter { $0.lastPathComponent.allSatisfy(\.isNumber) }
        }
        let isDayTree = [year, month, day].allSatisfy { $0.lastPathComponent.allSatisfy(\.isNumber) }
        let folders = isDayTree
            ? numberedChildren(of: year.deletingLastPathComponent()).flatMap(numberedChildren).flatMap(numberedChildren)
            : [day]
        return canonicalRolloutURLs(folders.flatMap(children).filter {
            isRolloutFile($0) && $0.lastPathComponent.contains(sessionID)
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
    static func decodedStreamContains(_ needle: String, for url: URL,
                                      maximumDecodedBytes: UInt64? = nil) -> Bool {
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
        var read: UInt64 = 0
        while maximumDecodedBytes.map({ read < $0 }) ?? true {
            let count = maximumDecodedBytes.map { Int(min(1024 * 1024, $0 - read)) } ?? 1024 * 1024
            guard let chunk = try? decoder.read(from: handle, upTo: count, stopAtFrameBoundary: maximumDecodedBytes != nil),
                  !chunk.isEmpty else { break }
            read += UInt64(chunk.count)
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
    static func randomAccessURL(for url: URL, decodedPrefixBytes: UInt64? = nil,
                                fileManager: FileManager = .default) throws -> URL {
        guard let storage = storageURL(for: url, fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard isCompressedRollout(storage) else { return storage }

        let attrs = try fileManager.attributesOfItem(atPath: storage.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let prefixKey = decodedPrefixBytes.map { "-prefix-\($0)" } ?? ""
        let key = sha256(canonicalURL(for: storage).path) + "-\(size)-\(Int64(mtime * 1000))" + prefixKey
        let directory = try materializedCacheDirectory(fileManager: fileManager)
        let target = directory.appendingPathComponent(key + ".jsonl")

        try withMaterializationLock(forKey: key) {
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                return
            }
            if let expected = decodedPrefixBytes ?? frameContentSize(of: storage), expected > materializedCacheByteLimit {
                throw ZstdStreamDecoder.DecodeError.limitExceeded
            }
            let temp = directory.appendingPathComponent(key + ".\(UUID().uuidString).tmp")
            // After a successful move the temp path is gone and this is a no-op.
            defer { try? fileManager.removeItem(at: temp) }
            try decodeCompressed(storage, to: temp, limit: materializedCacheByteLimit,
                                 decodedPrefixBytes: decodedPrefixBytes, fileManager: fileManager)
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
    static func seekableURLForImageScan(forPath path: String, decodedPrefixBytes: UInt64? = nil) -> URL? {
        let url = URL(fileURLWithPath: path)
        guard isStoredCompressed(url) else { return url }
        guard decodedStreamContains("data:image", for: url, maximumDecodedBytes: decodedPrefixBytes) else { return nil }
        return try? randomAccessURL(for: url, decodedPrefixBytes: decodedPrefixBytes)
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
                                         decodedPrefixBytes: UInt64? = nil,
                                         fileManager: FileManager) throws {
        let input = try FileHandle(forReadingFrom: storage)
        defer { try? input.close() }
        try decodeCompressed(from: input, to: destination, limit: limit,
                             decodedPrefixBytes: decodedPrefixBytes, fileManager: fileManager)
    }

    private static func decodeCompressed(from input: FileHandle,
                                         to destination: URL,
                                         limit: UInt64?,
                                         decodedPrefixBytes: UInt64? = nil,
                                         fileManager: FileManager) throws {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let decoder = ZstdStreamDecoder()
        var written: UInt64 = 0
        while decodedPrefixBytes.map({ written < $0 }) ?? true {
            let count = decodedPrefixBytes.map { Int(min(1024 * 1024, $0 - written)) } ?? 1024 * 1024
            let chunk = try decoder.read(from: input, upTo: count, stopAtFrameBoundary: decodedPrefixBytes != nil)
            if chunk.isEmpty { break }
            written += UInt64(chunk.count)
            if let limit, written > limit { throw ZstdStreamDecoder.DecodeError.limitExceeded }
            try output.write(contentsOf: chunk)
        }
        if let decodedPrefixBytes, written != decodedPrefixBytes { throw ZstdStreamDecoder.DecodeError.truncated }
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

    private let maximumWindowLog: Int32?
    private let inputChunkSize: Int
    init(maximumWindowLog: Int32? = nil, inputChunkSize: Int = 128 * 1024) {
        self.maximumWindowLog = maximumWindowLog
        self.inputChunkSize = inputChunkSize
    }
    var physicalBytesRead: UInt64 { bytesReadFromHandle }
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

    func read(from handle: FileHandle, upTo count: Int, stopAtFrameBoundary: Bool = false) throws -> Data {
        guard count > 0, !finished else { return Data() }
        if stream == nil {
            guard let created = ZSTD_createDStream() else { throw DecodeError.allocationFailed }
            stream = created
            let result = ZSTD_initDStream(created)
            guard ZSTD_isError(result) == 0 else { throw DecodeError.corrupt(Self.errorName(result)) }
            if let maximumWindowLog {
                let limit = ZSTD_DCtx_setParameter(created, ZSTD_d_windowLogMax, maximumWindowLog)
                guard ZSTD_isError(limit) == 0 else { throw DecodeError.limitExceeded }
            }
        }

        var output = [UInt8](repeating: 0, count: count)
        var produced = 0
        while produced < count {
            try Task.checkCancellation()
            if inputPosition >= input.count, !reachedEndOfInput {
                let chunk = try handle.read(upToCount: inputChunkSize) ?? Data()
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
            if stopAtFrameBoundary, frameComplete, produced > 0 { break }

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
