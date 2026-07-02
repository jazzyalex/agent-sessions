import Foundation

/// Reads the tail of a (potentially huge) JSONL file cheaply, without parsing
/// the whole file. Used to paint a disposable "last screen" of a monster
/// session while the full parse runs in the background (Task 9e, stage 0).
///
/// This is intentionally dumb: it seeks near the end, reads a bounded chunk,
/// and returns whole trailing lines. It never attempts to stitch identity
/// with a subsequent full parse — the caller treats its output as throwaway.
enum ReverseJSONLTailReader {

    /// Reads up to `maxLines` complete, non-empty, trimmed lines from the end
    /// of the file at `url`, scanning at most the last `maxBytes` bytes.
    ///
    /// - When the file is smaller than `maxBytes`, the whole file is read.
    /// - When the read starts mid-file (offset > 0), the first (necessarily
    ///   partial) line in the chunk is dropped.
    /// - When no newline is found anywhere in the chunk (a single oversize
    ///   line spans the whole window), returns `[]` — the full parse will
    ///   handle that file; stage 0 has nothing safe to show.
    /// - Returns `[]` for a missing/unreadable file.
    static func readLastLines(url: URL, maxBytes: Int = 2_097_152, maxLines: Int = 400) -> [String] {
        guard maxBytes > 0, maxLines > 0 else { return [] }

        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }

        let size: UInt64
        do {
            let end = try fh.seekToEnd()
            size = end
        } catch {
            return []
        }
        guard size > 0 else { return [] }

        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try fh.seek(toOffset: offset)
        } catch {
            return []
        }

        guard let data = (try? fh.readToEnd()) ?? nil, !data.isEmpty else { return [] }

        guard let text = String(data: data, encoding: .utf8) else { return [] }

        // Split into lines, preserving empties so we can tell "no newline at all"
        // apart from "trailing newline only".
        var lines = text.components(separatedBy: "\n")

        // If we started mid-file, the first fragment is a partial line — drop it.
        // If there's no newline anywhere in the chunk, `lines` has exactly one
        // element and that fragment is neither a complete leading nor trailing
        // line; per spec, return empty so the full parse handles it.
        if offset > 0 {
            if lines.count <= 1 {
                return []
            }
            lines.removeFirst()
        }

        let trimmed = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if trimmed.count > maxLines {
            return Array(trimmed.suffix(maxLines))
        }
        return trimmed
    }
}
