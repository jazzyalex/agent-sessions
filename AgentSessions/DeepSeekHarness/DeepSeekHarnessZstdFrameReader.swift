import Foundation
import libzstd

/// The bounded, in-process reader for DeepSeek Harness' concatenated Zstandard files.
///
/// A DSH `.jsonl.zstd` artifact is a sequence of independent Zstandard frames.  Keeping
/// frame boundaries here is intentional: the first frame has a stricter header contract,
/// and a later truncated frame must not be mistaken for a valid end of the stream.
struct DeepSeekHarnessZstdFrame: Sendable {
    let index: Int
    let compressedOffset: Int
    let compressedLength: Int
    let decoded: Data
}

enum DeepSeekHarnessZstdFrameReader {
    static let maxCompressedBytes = 128 * 1024 * 1024
    static let maxDecodedBytes = 128 * 1024 * 1024
    static let maxFrames = 100_000
    static let maxExpansionRatio = 1_000
    private static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static func readFrames(from data: Data) throws -> [DeepSeekHarnessZstdFrame] {
        guard data.count <= maxCompressedBytes else {
            throw DeepSeekHarnessFormatError.limitsExceeded("compressed artifact")
        }
        guard !data.isEmpty else { return [] }

        return try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return []
            }
            var offset = 0
            var frameIndex = 0
            var decodedTotal = 0
            var frames: [DeepSeekHarnessZstdFrame] = []

            while offset < data.count {
                guard !Task.isCancelled else { throw CancellationError() }
                guard frameIndex < maxFrames else {
                    throw DeepSeekHarnessFormatError.limitsExceeded("frame count")
                }
                let remaining = data.count - offset
                if remaining < magic.count {
                    throw DeepSeekHarnessFormatError.incompleteFrame(
                        frame: frameIndex,
                        offset: offset
                    )
                }
                guard Array(UnsafeBufferPointer(start: base.advanced(by: offset), count: magic.count)) == magic else {
                    throw DeepSeekHarnessFormatError.corruptFrame(
                        frame: frameIndex,
                        offset: offset,
                        reason: "missing Zstandard frame header"
                    )
                }

                guard let stream = ZSTD_createDStream() else {
                    throw DeepSeekHarnessFormatError.corruptFrame(
                        frame: frameIndex,
                        offset: offset,
                        reason: "could not allocate decoder"
                    )
                }
                defer { _ = ZSTD_freeDStream(stream) }
                let initResult = ZSTD_initDStream(stream)
                guard ZSTD_isError(initResult) == 0 else {
                    throw DeepSeekHarnessFormatError.corruptFrame(
                        frame: frameIndex,
                        offset: offset,
                        reason: zstdError(initResult)
                    )
                }

                var input = ZSTD_inBuffer(
                    src: UnsafeRawPointer(base.advanced(by: offset)),
                    size: data.count - offset,
                    pos: 0
                )
                var decoded = Data()
                var completed = false
                while input.pos < input.size {
                    guard !Task.isCancelled else { throw CancellationError() }
                    var outputStorage = [UInt8](repeating: 0, count: 64 * 1024)
                    var producedBytes = 0
                    let produced = outputStorage.withUnsafeMutableBytes { outputRaw in
                        var output = ZSTD_outBuffer(
                            dst: outputRaw.baseAddress,
                            size: outputRaw.count,
                            pos: 0
                        )
                        let result = ZSTD_decompressStream(stream, &output, &input)
                        producedBytes = output.pos
                        return result
                    }
                    if producedBytes > 0 {
                        decoded.append(contentsOf: outputStorage.prefix(producedBytes))
                    }
                    guard ZSTD_isError(produced) == 0 else {
                        throw DeepSeekHarnessFormatError.corruptFrame(
                            frame: frameIndex,
                            offset: offset + Int(input.pos),
                            reason: zstdError(produced)
                        )
                    }
                    // `decoded` is the complete plaintext accumulated for this
                    // frame.  Count only the bytes produced by this decoder
                    // call; adding `decoded.count` here would count every
                    // earlier chunk again and could reject a valid frame as an
                    // expansion-limit violation.
                    decodedTotal += producedBytes
                    guard decodedTotal <= maxDecodedBytes,
                          decoded.count <= max(1, (Int(input.pos) * maxExpansionRatio)) else {
                        throw DeepSeekHarnessFormatError.limitsExceeded("decoded expansion")
                    }
                    if produced == 0 {
                        completed = true
                        break
                    }
                }

                guard completed else {
                    throw DeepSeekHarnessFormatError.incompleteFrame(
                        frame: frameIndex,
                        offset: offset
                    )
                }
                let consumed = Int(input.pos)
                guard consumed > 0 else {
                    throw DeepSeekHarnessFormatError.corruptFrame(
                        frame: frameIndex,
                        offset: offset,
                        reason: "decoder consumed no input"
                    )
                }
                frames.append(DeepSeekHarnessZstdFrame(
                    index: frameIndex,
                    compressedOffset: offset,
                    compressedLength: consumed,
                    decoded: decoded
                ))
                offset += consumed
                frameIndex += 1
            }
            return frames
        }
    }

    /// Read only the first frame from a file. DSH reserves that frame for the
    /// session header, so discovery does not need to map or decompress the
    /// remainder of a large generation just to build Session metadata.
    static func readFirstFrame(
        from url: URL,
        decodedByteLimit: Int = maxDecodedBytes
    ) throws -> DeepSeekHarnessZstdFrame {
        guard decodedByteLimit > 0, decodedByteLimit <= maxDecodedBytes else {
            throw DeepSeekHarnessFormatError.limitsExceeded("decoded header")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try readFirstFrame(from: handle, decodedByteLimit: decodedByteLimit)
    }

    static func readFirstFrame(
        from handle: FileHandle,
        decodedByteLimit: Int = maxDecodedBytes
    ) throws -> DeepSeekHarnessZstdFrame {
        guard decodedByteLimit > 0, decodedByteLimit <= maxDecodedBytes else {
            throw DeepSeekHarnessFormatError.limitsExceeded("decoded header")
        }

        guard let stream = ZSTD_createDStream() else {
            throw DeepSeekHarnessFormatError.corruptFrame(
                frame: 0, offset: 0, reason: "could not allocate decoder")
        }
        defer { _ = ZSTD_freeDStream(stream) }
        let initResult = ZSTD_initDStream(stream)
        guard ZSTD_isError(initResult) == 0 else {
            throw DeepSeekHarnessFormatError.corruptFrame(
                frame: 0, offset: 0, reason: zstdError(initResult))
        }

        var pending = Data()
        var pendingOffset = 0
        var fileOffset = 0
        var decoded = Data()
        var decodedTotal = 0

        while true {
            try checkCancellation()
            if pending.isEmpty {
                pending = try handle.read(upToCount: 64 * 1024) ?? Data()
                guard !pending.isEmpty else {
                    throw DeepSeekHarnessFormatError.incompleteFrame(frame: 0, offset: fileOffset)
                }
                guard fileOffset + pending.count <= maxCompressedBytes else {
                    throw DeepSeekHarnessFormatError.limitsExceeded("compressed artifact")
                }
                pendingOffset = fileOffset
                fileOffset += pending.count
            }

            var completedLength: Int?
            let consumed = try pending.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                var input = ZSTD_inBuffer(
                    src: base,
                    size: pending.count,
                    pos: 0
                )
                while input.pos < input.size {
                    try checkCancellation()
                    var outputStorage = [UInt8](repeating: 0, count: 64 * 1024)
                    var producedBytes = 0
                    let produced = outputStorage.withUnsafeMutableBytes { outputRaw in
                        var output = ZSTD_outBuffer(
                            dst: outputRaw.baseAddress,
                            size: outputRaw.count,
                            pos: 0
                        )
                        let result = ZSTD_decompressStream(stream, &output, &input)
                        producedBytes = output.pos
                        return result
                    }
                    if producedBytes > 0 {
                        decoded.append(contentsOf: outputStorage.prefix(producedBytes))
                    }
                    guard ZSTD_isError(produced) == 0 else {
                        throw DeepSeekHarnessFormatError.corruptFrame(
                            frame: 0,
                            offset: pendingOffset + Int(input.pos),
                            reason: zstdError(produced)
                        )
                    }
                    decodedTotal += producedBytes
                    guard decodedTotal <= decodedByteLimit,
                          decoded.count <= max(1, (pendingOffset + Int(input.pos)) * maxExpansionRatio) else {
                        throw DeepSeekHarnessFormatError.limitsExceeded(
                            decodedTotal > decodedByteLimit ? "decoded header" : "decoded expansion")
                    }
                    if produced == 0 {
                        completedLength = pendingOffset + Int(input.pos)
                        return Int(input.pos)
                    }
                }
                return Int(input.pos)
            }

            if let completedLength {
                return DeepSeekHarnessZstdFrame(
                    index: 0,
                    compressedOffset: 0,
                    compressedLength: completedLength,
                    decoded: decoded)
            }
            guard consumed > 0 else {
                throw DeepSeekHarnessFormatError.corruptFrame(
                    frame: 0, offset: pendingOffset, reason: "decoder consumed no input")
            }
            pending.removeFirst(consumed)
            pendingOffset += consumed
        }
    }

    private static func checkCancellation() throws {
        guard !Task.isCancelled else { throw CancellationError() }
    }

    private static func zstdError(_ code: size_t) -> String {
        guard let name = ZSTD_getErrorName(code) else { return "decoder error" }
        return String(cString: name)
    }
}
