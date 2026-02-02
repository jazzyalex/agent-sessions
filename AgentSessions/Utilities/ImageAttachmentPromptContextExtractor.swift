import Foundation
import ImageIO

enum ImageAttachmentPromptContextExtractor {
    static func extractPromptText(url: URL,
                                  span: Base64ImageDataURLScanner.Span,
                                  maxSideBytes: Int = 128 * 1024) -> String? {
        guard maxSideBytes > 0 else { return nil }

        do {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }

            let startOffset = span.startOffset
            let endOffset = span.endOffset

            let prefixStart = startOffset > UInt64(maxSideBytes) ? (startOffset - UInt64(maxSideBytes)) : 0
            let prefixLen = Int(min(UInt64(Int.max), startOffset - prefixStart))

            try fh.seek(toOffset: prefixStart)
            let prefixData = try fh.read(upToCount: prefixLen) ?? Data()

            try fh.seek(toOffset: endOffset)
            let suffixData = try fh.read(upToCount: maxSideBytes) ?? Data()

            let prefixText = String(decoding: prefixData, as: UTF8.self)
            let suffixText = String(decoding: suffixData, as: UTF8.self)

            var pieces: [String] = []
            pieces.append(contentsOf: extractTextFields(from: prefixText).suffix(3))
            pieces.append(contentsOf: extractTextFields(from: suffixText).prefix(1))

            let deduped = dedupe(pieces)
            let joined = deduped
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !joined.isEmpty else { return nil }
            if joined.count <= 2400 { return joined }
            return String(joined.prefix(2400)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        } catch {
            return nil
        }
    }

    static func dimensionsText(for imageData: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? ((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? ((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        guard let w, let h, w > 0, h > 0 else { return nil }
        return "\(w) × \(h)"
    }

    private static func extractTextFields(from text: String) -> [String] {
        // Match JSON string values for `"text":"..."` while supporting escaped quotes/backslashes.
        // Captures the raw JSON-escaped string payload.
        let pattern = #""text"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = re.matches(in: text, options: [], range: range)

        var out: [String] = []
        out.reserveCapacity(min(matches.count, 4))

        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let r = m.range(at: 1)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            let raw = ns.substring(with: r)
            guard let decoded = decodeJSONStringValue(rawPayload: raw) else { continue }
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count > 8000 { continue }
            out.append(trimmed)
            if out.count >= 6 { break }
        }

        return out
    }

    private static func decodeJSONStringValue(rawPayload: String) -> String? {
        // Wrap the raw payload in quotes so JSONSerialization can decode escapes.
        let wrapped = "\"" + rawPayload + "\""
        guard let data = wrapped.data(using: .utf8) else { return nil }
        guard let v = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { return nil }
        return v
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        out.reserveCapacity(values.count)
        for v in values {
            if seen.contains(v) { continue }
            seen.insert(v)
            out.append(v)
        }
        return out
    }
}

