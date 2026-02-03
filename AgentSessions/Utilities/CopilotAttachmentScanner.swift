import Foundation
import UniformTypeIdentifiers

/// Scans Copilot CLI session-state JSONL files for file attachments referenced by path.
///
/// Copilot stores user message attachments as:
/// `{ "type": "user.message", "data": { "attachments": [ { "type": "file", "path": "...", "displayName": "..." } ] } }`
enum CopilotAttachmentScanner {
    struct Attachment: Hashable, Sendable {
        let eventSequenceIndex: Int // 1-based, matching CopilotSessionParser baseID suffix
        let fileURL: URL
        let mediaType: String
        let fileSizeBytes: Int64
    }

    static func scanFile(at url: URL, maxMatches: Int = 200, shouldCancel: () -> Bool = { false }) throws -> [Attachment] {
        guard maxMatches > 0 else { return [] }
        let reader = JSONLReader(url: url)

        var out: [Attachment] = []
        out.reserveCapacity(min(maxMatches, 16))

        var idx = 0
        try reader.forEachLine { rawLine in
            if shouldCancel() { return }
            if out.count >= maxMatches { return }

            idx += 1
            guard let obj = decodeObject(rawLine) else { return }
            guard (obj["type"] as? String) == "user.message" else { return }
            guard let data = obj["data"] as? [String: Any] else { return }
            guard let attachments = data["attachments"] as? [[String: Any]], !attachments.isEmpty else { return }

            for att in attachments {
                if shouldCancel() { return }
                if out.count >= maxMatches { return }
                guard (att["type"] as? String) == "file" else { continue }
                guard let path = att["path"] as? String, !path.isEmpty else { continue }
                let fileURL = URL(fileURLWithPath: path)

                let mediaType = inferredImageMIMEType(fileURL: fileURL)
                guard mediaType.hasPrefix("image/") else { continue }

                let sizeBytes: Int64 = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                out.append(Attachment(eventSequenceIndex: idx, fileURL: fileURL, mediaType: mediaType, fileSizeBytes: sizeBytes))
            }
        }

        return out
    }
}

private extension CopilotAttachmentScanner {
    static func decodeObject(_ rawLine: String) -> [String: Any]? {
        guard let data = rawLine.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func inferredImageMIMEType(fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        guard !ext.isEmpty else { return "application/octet-stream" }
        if let ut = UTType(filenameExtension: ext), ut.conforms(to: .image) {
            return ut.preferredMIMEType ?? ("image/" + ext)
        }
        return "application/octet-stream"
    }
}

