import Foundation
import UniformTypeIdentifiers

enum AntigravityMarkdownImageScanner {
    struct Attachment: Hashable, Sendable {
        let lineIndex: Int
        let fileURL: URL
        let mediaType: String
        let fileSizeBytes: Int64
    }

    static func fileContainsLocalMarkdownImage(at url: URL,
                                               shouldCancel: () -> Bool = { false }) -> Bool {
        (try? scanFile(at: url, maxMatches: 1, shouldCancel: shouldCancel).isEmpty == false) ?? false
    }

    static func scanFile(at url: URL,
                         maxMatches: Int,
                         shouldCancel: () -> Bool = { false }) throws -> [Attachment] {
        guard maxMatches > 0 else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let baseDirectory = url.deletingLastPathComponent()
        var out: [Attachment] = []
        out.reserveCapacity(min(maxMatches, 16))

        for (lineIndex, line) in text.components(separatedBy: .newlines).enumerated() {
            if shouldCancel() { break }
            for destination in markdownImageDestinations(in: line) {
                if shouldCancel() { break }
                guard let fileURL = localImageURL(from: destination, relativeTo: baseDirectory),
                      let mediaType = mediaType(for: fileURL),
                      let size = fileSizeBytes(for: fileURL) else {
                    continue
                }

                out.append(Attachment(lineIndex: lineIndex,
                                      fileURL: fileURL,
                                      mediaType: mediaType,
                                      fileSizeBytes: size))
                if out.count >= maxMatches { return out }
            }
        }

        return out
    }

    private static func markdownImageDestinations(in line: String) -> [String] {
        var destinations: [String] = []
        var searchStart = line.startIndex

        while let bang = line[searchStart...].firstIndex(of: "!") {
            guard line.index(after: bang) < line.endIndex,
                  line[line.index(after: bang)] == "[" else {
                searchStart = line.index(after: bang)
                continue
            }
            guard let closeBracket = line[line.index(after: bang)...].firstIndex(of: "]") else { break }
            let openParenIndex = line.index(after: closeBracket)
            guard openParenIndex < line.endIndex, line[openParenIndex] == "(" else {
                searchStart = openParenIndex
                continue
            }
            guard let closeParen = line[line.index(after: openParenIndex)...].firstIndex(of: ")") else { break }
            let raw = String(line[line.index(after: openParenIndex)..<closeParen])
            if let destination = normalizedDestination(raw) {
                destinations.append(destination)
            }
            searchStart = line.index(after: closeParen)
        }

        return destinations
    }

    private static func normalizedDestination(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        } else if let firstSpace = value.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            value = String(value[..<firstSpace])
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func localImageURL(from destination: String, relativeTo baseDirectory: URL) -> URL? {
        let lowercased = destination.lowercased()
        guard !lowercased.hasPrefix("http://"),
              !lowercased.hasPrefix("https://"),
              !lowercased.hasPrefix("data:") else {
            return nil
        }

        let stripped = stripFragmentAndQuery(from: destination)
        if stripped.lowercased().hasPrefix("file://") {
            guard let url = URL(string: stripped), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }

        let decoded = stripped.removingPercentEncoding ?? stripped
        if decoded.hasPrefix("/") || decoded.hasPrefix("~") {
            return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath).standardizedFileURL
        }
        return baseDirectory.appendingPathComponent(decoded).standardizedFileURL
    }

    private static func stripFragmentAndQuery(from value: String) -> String {
        var end = value.endIndex
        if let query = value.firstIndex(of: "?") {
            end = min(end, query)
        }
        if let fragment = value.firstIndex(of: "#") {
            end = min(end, fragment)
        }
        return String(value[..<end])
    }

    private static func mediaType(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if let mime = UTType(filenameExtension: ext)?.preferredMIMEType,
           mime.hasPrefix("image/") {
            return mime
        }
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "heic": return "image/heic"
        default: return nil
        }
    }

    private static func fileSizeBytes(for url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return nil }
            return Int64(values.fileSize ?? 0)
        } catch {
            return nil
        }
    }
}
