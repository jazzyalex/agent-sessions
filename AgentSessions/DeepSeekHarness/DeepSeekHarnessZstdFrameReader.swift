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

    private static func zstdError(_ code: size_t) -> String {
        guard let name = ZSTD_getErrorName(code) else { return "decoder error" }
        return String(cString: name)
    }
}
