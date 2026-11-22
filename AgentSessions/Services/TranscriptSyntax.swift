import AppKit

enum TranscriptSyntaxLanguage: String, Hashable, Sendable {
    case swift, python, javascript, typescript, shell, json, yaml

    init?(tag: String) {
        switch tag.lowercased() {
        case "swift": self = .swift
        case "python", "py", "python3": self = .python
        case "javascript", "js", "jsx", "mjs", "cjs": self = .javascript
        case "typescript", "ts", "tsx", "mts", "cts": self = .typescript
        case "bash", "sh", "zsh", "shell": self = .shell
        case "json", "jsonl", "ndjson": self = .json
        case "yaml", "yml": self = .yaml
        default: return nil
        }
    }

    init?(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        if [".bashrc", ".zshrc", ".bash_profile", ".zprofile", ".profile"].contains(name) {
            self = .shell
        } else {
            self.init(tag: (name as NSString).pathExtension)
        }
    }
}

struct TranscriptSyntaxSpan: Equatable, Sendable {
    var source: NSRange
    var renderedLocation: Int
}

struct TranscriptSyntaxSnippet: Sendable {
    struct Key: Hashable, Sendable {
        var language: TranscriptSyntaxLanguage
        var text: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.language == rhs.language && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(language)
            hasher.combine(text)
        }
    }

    var key: Key
    /// Ordered, disjoint UTF-16 runs. Tool gutters and folds are gaps in rendered space.
    var spans: [TranscriptSyntaxSpan]

    static let snippetLimit = 50 * 1024
    static let bodyLimit = 128 * 1024
    static let snippetsPerBody = 128

    func projected(through rendered: [TranscriptSyntaxSpan]) -> Self? {
        var output: [TranscriptSyntaxSpan] = []
        var index = 0
        for span in spans {
            let decoded = NSRange(location: span.renderedLocation, length: span.source.length)
            while index < rendered.count && NSMaxRange(rendered[index].source) <= decoded.location {
                index += 1
            }
            var next = index
            while next < rendered.count && rendered[next].source.location < NSMaxRange(decoded) {
                let target = rendered[next]
                let overlap = NSIntersectionRange(decoded, target.source)
                if overlap.length > 0 {
                    output.append(TranscriptSyntaxSpan(
                        source: NSRange(location: span.source.location + overlap.location - decoded.location,
                                        length: overlap.length),
                        renderedLocation: target.renderedLocation + overlap.location - target.source.location))
                }
                next += 1
            }
        }
        return output.isEmpty ? nil : Self(key: key, spans: output)
    }

    func forEachVisibleToken(_ tokens: [TranscriptSyntax.Token],
                             _ apply: (NSRange, TranscriptSyntax.Kind) -> Void) {
        var first = 0
        for span in spans {
            while first < tokens.count && NSMaxRange(tokens[first].range) <= span.source.location {
                first += 1
            }
            var index = first
            while index < tokens.count && tokens[index].range.location < NSMaxRange(span.source) {
                let token = tokens[index]
                let overlap = NSIntersectionRange(span.source, token.range)
                if overlap.length > 0 {
                    apply(NSRange(location: span.renderedLocation + overlap.location - span.source.location,
                                  length: overlap.length), token.kind)
                }
                index += 1
            }
        }
    }
}

/// A bounded lexical tokenizer. A token consumes its entire string or comment, including newlines,
/// so folding does not restart lexical state. Foundation supplies UTF-16 offsets directly.
enum TranscriptSyntax {
    enum Kind: Int, CaseIterable, Sendable { case comment, keyword, literal, symbol }
    struct Token: Equatable, Sendable {
        var range: NSRange
        var kind: Kind
    }

    private struct Grammar: Sendable {
        var expression: NSRegularExpression
        var keywords: Set<String>
    }

    private static let grammars: [TranscriptSyntaxLanguage: Grammar] = {
        let slash = #"//[^\r\n]*|/\*(?:[^*]++|\*(?!/))*+(?:\*/|\z)"#
        let hash = #"#[^\r\n]*"#
        let double = #""(?:[^"\\\r\n]++|\\[^\r\n])*+(?:"|(?=\r?\n)|\z)"#
        let single = #"'(?:[^'\\\r\n]++|\\[^\r\n])*+(?:'|(?=\r?\n)|\z)"#
        let tripleDouble = #""""(?:(?!""")[\s\S])*+(?:"""|\z)"#
        let tripleSingle = #"'''(?:(?!''')[\s\S])*+(?:'''|\z)"#
        let template = #"`(?:[^`\\]++|\\[\s\S])*+(?:`|\z)"#
        let number = #"(?<![\p{L}\p{N}_])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?)(?![\p{L}\p{N}_])"#
        let word = #"[\p{L}_][\p{L}\p{M}\p{N}_]*"#
        func grammar(_ comments: String, _ strings: [String], _ keywords: String) -> Grammar {
            let pattern = "(\(comments))|(\(strings.joined(separator: "|")))|(\(number))|(\(word))"
            return Grammar(expression: try! NSRegularExpression(pattern: pattern),
                           keywords: Set(keywords.split(separator: " ").map(String.init)))
        }
        let js = "async await break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while with yield"
        return [
            .swift: grammar(slash, [tripleDouble, double],
                            "actor any as associatedtype async await break case catch class continue defer deinit do else enum extension fallthrough fileprivate for func guard if import in init inout internal is let mutating nonisolated open operator override package private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws try typealias var where while"),
            .python: grammar(hash, [tripleDouble, tripleSingle, double, single],
                             "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield"),
            .javascript: grammar(slash, [template, double, single], js),
            .typescript: grammar(slash, [template, double, single],
                                 js + " abstract any declare enum implements infer interface keyof namespace never override private protected public readonly satisfies type unknown"),
            .shell: grammar(hash, [double, single],
                            "case do done elif else esac export fi for function if in local readonly return select set then until while"),
            .json: grammar("(?!)", [double], ""),
            .yaml: grammar(hash, [double, single], "")
        ]
    }()

    static func tokenize(_ key: TranscriptSyntaxSnippet.Key) -> [Token] {
        guard key.text.utf8.count <= TranscriptSyntaxSnippet.snippetLimit,
              let grammar = grammars[key.language] else { return [] }
        let text = key.text as NSString
        var tokens: [Token] = []
        grammar.expression.enumerateMatches(in: key.text, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match, match.range.length > 0 else { return }
            let kind: Kind
            if match.range(at: 1).location != NSNotFound {
                kind = .comment
            } else if match.range(at: 2).location != NSNotFound || match.range(at: 3).location != NSNotFound {
                kind = .literal
            } else {
                let word = text.substring(with: match.range)
                if grammar.keywords.contains(word) {
                    kind = .keyword
                } else if ["true", "false", "nil", "null", "undefined", "True", "False", "None"].contains(word) {
                    kind = .literal
                } else if word.first?.isUppercase == true
                            || (NSMaxRange(match.range) < text.length && text.character(at: NSMaxRange(match.range)) == 40) {
                    kind = .symbol
                } else {
                    return
                }
            }
            tokens.append(Token(range: match.range, kind: kind))
        }
        return tokens
    }

    static func palette(appearance: NSAppearance, increaseContrast: Bool) -> [NSColor] {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let values: [UInt32]
        switch (dark, increaseContrast) {
        case (true, true): values = [0xDCE2EC, 0xFFC9F6, 0xBEF4CB, 0xC5DAFF]
        case (true, false): values = [0xAEBAC8, 0xF4A7E5, 0x8DDAA3, 0xA2C3FF]
        case (false, true): values = [0x455261, 0x74146E, 0x16522B, 0x153E7F]
        case (false, false): values = [0x556372, 0x881783, 0x1C6132, 0x224D97]
        }
        return values.map {
            NSColor(srgbRed: CGFloat(($0 >> 16) & 255) / 255, green: CGFloat(($0 >> 8) & 255) / 255,
                    blue: CGFloat($0 & 255) / 255, alpha: 1)
        }
    }

    static func findForeground(tint: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var foreground = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                guard let tint = tint.usingColorSpace(.sRGB),
                      let base = NSColor.textBackgroundColor.usingColorSpace(.sRGB) else { return }
                let alpha = tint.alphaComponent
                func luminanceChannel(_ tint: CGFloat, _ base: CGFloat) -> CGFloat {
                    let channel = tint * alpha + base * (1 - alpha)
                    return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * luminanceChannel(tint.redComponent, base.redComponent)
                    + 0.7152 * luminanceChannel(tint.greenComponent, base.greenComponent)
                    + 0.0722 * luminanceChannel(tint.blueComponent, base.blueComponent)
                // The contrast ratios of black and white cross at this luminance.
                foreground = luminance > 0.179 ? .black : .white
            }
            return foreground
        }
    }
}

/// The table supplies its current visible keys. A worker can finish after a scroll or an edit,
/// but its completion only asks the table to revisit cells that are still visible.
final class TranscriptSyntaxScheduler {
    typealias Key = TranscriptSyntaxSnippet.Key
    private final class CacheKey: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? CacheKey)?.key == key }
    }
    private final class Cached: NSObject {
        let tokens: [TranscriptSyntax.Token]
        init(_ tokens: [TranscriptSyntax.Token]) { self.tokens = tokens }
    }

    private let cache = NSCache<CacheKey, Cached>()
    private var active: Set<Key> = []
    private var pending: [Key] = []
    private var didFinish: (() -> Void)?
    #if DEBUG
    private(set) var peakActive = 0
    private(set) var peakPending = 0
    #endif

    init() {
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 256
    }

    func tokens(for key: Key) -> [TranscriptSyntax.Token]? {
        cache.object(forKey: CacheKey(key))?.tokens
    }

    func update(visible keys: [Key], didFinish: @escaping () -> Void) {
        self.didFinish = didFinish
        var seen = active
        let available = 10 - active.count
        pending.removeAll(keepingCapacity: true)
        for key in keys where seen.insert(key).inserted {
            pending.append(key)
            if pending.count == available { break }
        }
        startPending()
        #if DEBUG
        peakActive = max(peakActive, active.count)
        peakPending = max(peakPending, pending.count)
        #endif
    }

    private func startPending() {
        while active.count < 2, !pending.isEmpty {
            let key = pending.removeFirst()
            active.insert(key)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let tokens = TranscriptSyntax.tokenize(key)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.active.remove(key)
                    self.cache.setObject(Cached(tokens), forKey: CacheKey(key),
                                         cost: key.text.utf16.count * 2 + tokens.count * MemoryLayout<TranscriptSyntax.Token>.stride)
                    self.didFinish?()
                }
            }
        }
    }
}
