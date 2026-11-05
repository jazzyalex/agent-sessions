import AppKit
import Foundation

/// What the user has opened in one text pane. Value type; the renderer keeps one per pane.
struct FoldState: Equatable, Sendable {
    /// Logical lines added to the visible head by "Show 500 more" (error mode: added to the tail).
    var extraLinesShown: Int = 0
    var showAll = false
    /// Logical line indexes whose "… +N chars" cut was opened. An opened line renders in full but
    /// still counts as its cut size (`longLineVisualLines`) in every budget, so opening it never
    /// moves a fold boundary.
    var openedLongLines: Set<Int> = []
    /// Command and heredoc panes only: every line, cut lines opened, up to the Show-all caps.
    var commandShowAll = false
}

/// The result of folding a text. `segments` describe the text in order, top to bottom.
///
/// Segment grammar (Task 11 renders it):
/// - Line indexes are 0-based logical lines (split on "\n"; one trailing "\n" ends the last line and
///   does not add an empty one). An empty text has no lines and no segments.
/// - `.lines(range)` — render logical lines `range` in full. A range never holds a cut line.
/// - `.longLineCut(line:hiddenChars:)` — render the first `columns * 4` visual columns of logical line
///   `line` (whole Characters), then a "… +hiddenChars chars" control that adds `line` to
///   `FoldState.openedLongLines`. `hiddenChars` is the count of Characters after the cut.
///   The line does not also appear in a `.lines` range.
/// - `.fold(hiddenLines:)` — the lines between the previous and the next segment are hidden.
///   `hiddenLines` is their count in logical lines. Its index range is implied: it starts after the
///   last line of the segment before it and ends before the first line of the segment after it
///   (to the end of the text when it is the last segment).
/// - Order: segments are in text order. A cut line sits between `.lines` ranges, e.g.
///   `[.lines(0..<3), .longLineCut(line: 3, hiddenChars: 680), .lines(4..<10)]`.
/// - Normal mode: `[.lines(all)]`, or `[head..., .fold, tail...]`. Error mode: `[.fold, tail...]` or all.
///   `foldCommand`: `[head...]` or `[head..., .fold]`; with `commandShowAll`, every line with no cut,
///   up to the Show-all caps. A fold with 0 hidden lines is never emitted.
/// - Budgets count a line longer than 4 visual lines as 4, opened or not, so `openedLongLines` only
///   turns a `.longLineCut` into part of a `.lines` range and never moves a fold boundary.
/// - `hitShowAllCap` is true when "Show all" (or `commandShowAll`) stopped at 20,000 lines or 2 MB;
///   the last segment is then the `.fold` for the rest, and the pane offers Copy output and Show Raw Event.
struct FoldedText: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        case lines(Range<Int>)
        case fold(hiddenLines: Int)
        case longLineCut(line: Int, hiddenChars: Int)
    }
    var segments: [Segment]
    var hitShowAllCap: Bool
}

/// Visual-line budgets for tool text panes (spec §6.5). Pure; no layout pass.
enum ToolTextBudget {
    static let headLines = 12, tailLines = 4, errorTailLines = 18, longLineVisualLines = 4
    static let showMoreStep = 500, showAllLineCap = 20_000, showAllByteCap = 2 * 1024 * 1024
    /// Command input / heredoc pane budget (spec §6.5).
    static let commandLines = 12

    /// Monospace columns that fit in `width`: floor(width / advance of "0"), at least 1.
    static func columns(width: CGFloat, font: NSFont) -> Int {
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        guard advance > 0, width.isFinite else { return 1 }
        return max(1, Int((width / advance).rounded(.down)))
    }

    /// Display width of one line in monospace columns. East Asian Wide/Fullwidth and emoji
    /// presentation count 2; combining marks, zero-width characters and controls count 0;
    /// a tab advances to the next multiple of 4.
    static func visualWidth(of line: Substring) -> Int {
        width(of: line, stopping: Int.max).width
    }

    /// End of the part of a cut long line that stays visible: the first `columns * longLineVisualLines`
    /// visual columns, whole Characters. `.longLineCut(hiddenChars:)` counts the Characters after this
    /// index, so the shown prefix and `hiddenChars` always agree. Pass the line the way `fold` sees
    /// it: the UTF-8 bytes between two "\n", decoded on their own (a "\r" before the "\n" stays).
    static func keptPrefixEnd(of line: Substring, columns: Int) -> String.Index {
        let limit = max(1, columns) * longLineVisualLines
        if line.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x80 }) {
            return line.utf8.index(line.startIndex, offsetBy: min(limit, line.utf8.count))
        }
        return line.index(line.startIndex, offsetBy: width(of: line, stopping: limit).kept)
    }

    static func fold(_ text: String, columns: Int, isError: Bool, state: FoldState) -> FoldedText {
        var text = text
        let columns = max(1, columns)
        return text.withUTF8 { bytes in
            let scan = Scan(bytes: bytes, columns: columns, opened: state.openedLongLines, openAll: false)
            let n = scan.count
            if n == 0 { return FoldedText(segments: [], hitShowAllCap: false) }
            if state.showAll { return scan.showAll() }

            if isError {
                if scan.total <= errorTailLines { return FoldedText(segments: scan.emit(0..<n), hitShowAllCap: false) }
                var tailStart = scan.tailStart(from: n, budget: errorTailLines, floor: 0)
                tailStart = max(0, tailStart - max(0, state.extraLinesShown))
                var segments: [FoldedText.Segment] = []
                if tailStart > 0 { segments.append(.fold(hiddenLines: tailStart)) }
                segments += scan.emit(tailStart..<n)
                return FoldedText(segments: segments, hitShowAllCap: false)
            }

            if scan.total <= headLines + tailLines { return FoldedText(segments: scan.emit(0..<n), hitShowAllCap: false) }
            var headEnd = scan.headEnd(budget: headLines)
            let tailStart = scan.tailStart(from: n, budget: tailLines, floor: headEnd)
            headEnd = min(headEnd + max(0, state.extraLinesShown), tailStart)
            if headEnd >= tailStart { return FoldedText(segments: scan.emit(0..<n), hitShowAllCap: false) }
            var segments = scan.emit(0..<headEnd)
            segments.append(.fold(hiddenLines: tailStart - headEnd))
            segments += scan.emit(tailStart..<n)
            return FoldedText(segments: segments, hitShowAllCap: false)
        }
    }

    /// Command and heredoc panes: full up to 12 visual lines, else the first 12 plus a fold (no tail).
    /// `commandShowAll` shows every line with no cut, up to the Show-all caps.
    static func foldCommand(_ text: String, columns: Int, state: FoldState) -> FoldedText {
        var text = text
        let columns = max(1, columns)
        return text.withUTF8 { bytes in
            let scan = Scan(bytes: bytes, columns: columns, opened: state.openedLongLines, openAll: state.commandShowAll)
            let n = scan.count
            if n == 0 { return FoldedText(segments: [], hitShowAllCap: false) }
            if state.commandShowAll { return scan.showAll() }
            if scan.total <= commandLines {
                return FoldedText(segments: scan.emit(0..<n), hitShowAllCap: false)
            }
            let headEnd = scan.headEnd(budget: commandLines)
            var segments = scan.emit(0..<headEnd)
            if headEnd < n { segments.append(.fold(hiddenLines: n - headEnd)) }
            return FoldedText(segments: segments, hitShowAllCap: false)
        }
    }

    // MARK: - Line scan

    /// One pass over the UTF-8 bytes. Per line: byte range, full visual lines and a plain-ASCII flag.
    private struct Scan {
        let bytes: UnsafeBufferPointer<UInt8>
        let columns: Int
        let opened: Set<Int>
        /// Every line is opened (`commandShowAll`), without a set over all lines.
        let openAll: Bool
        var starts: [Int] = []
        var ends: [Int] = []
        var visual: [Int] = []
        var plain: [Bool] = []
        /// Budget size of the text: visual lines, each long line counted as 4 (opened or not).
        var total = 0
        var count: Int { starts.count }

        init(bytes: UnsafeBufferPointer<UInt8>, columns: Int, opened: Set<Int>, openAll: Bool) {
            self.bytes = bytes
            self.columns = columns
            self.opened = opened
            self.openAll = openAll
            guard let base = bytes.baseAddress else { return }
            let n = bytes.count
            var pos = 0
            while pos < n {
                var end = n
                if let hit = memchr(base + pos, 10, n - pos) {
                    end = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                }
                var isPlain = true
                var i = pos
                while i < end {
                    let b = base[i]
                    if b < 0x20 || b >= 0x80 { isPlain = false; break }
                    i += 1
                }
                let width: Int
                if isPlain {
                    width = end - pos
                } else {
                    let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[pos..<end]), as: UTF8.self)
                    width = ToolTextBudget.width(of: Substring(line), stopping: Int.max).width
                }
                let v = max(1, (width + columns - 1) / columns)
                starts.append(pos)
                ends.append(end)
                visual.append(v)
                plain.append(isPlain)
                total += min(v, ToolTextBudget.longLineVisualLines)
                pos = end + 1
            }
        }

        /// Rendered as a cut: long and not opened.
        func isCut(_ i: Int) -> Bool {
            visual[i] > ToolTextBudget.longLineVisualLines && !openAll && !opened.contains(i)
        }

        /// Budget size of line `i`: its visual lines, at most 4. Opening a line does not change it.
        func shown(_ i: Int) -> Int { min(visual[i], ToolTextBudget.longLineVisualLines) }

        /// "Show all": every line up to 20,000 lines or 2 MB, then a fold for the rest.
        func showAll() -> FoldedText {
            var end = 0
            var used = 0
            while end < count {
                let size = ends[end] - starts[end] + 1
                if end >= ToolTextBudget.showAllLineCap || (used + size > ToolTextBudget.showAllByteCap && end > 0) { break }
                used += size
                end += 1
            }
            var segments = emit(0..<end)
            if end < count { segments.append(.fold(hiddenLines: count - end)) }
            return FoldedText(segments: segments, hitShowAllCap: end < count)
        }

        /// End (exclusive) of the head: whole lines from the top while they fit in `budget`; at least one.
        func headEnd(budget: Int) -> Int {
            var i = 0
            var used = 0
            while i < count {
                let e = shown(i)
                if used + e > budget && i > 0 { break }
                used += e
                i += 1
            }
            return i
        }

        /// Start of the tail: whole lines from `end` upward while they fit in `budget`; at least one,
        /// never below `floor`.
        func tailStart(from end: Int, budget: Int, floor: Int) -> Int {
            var j = end
            var used = 0
            while j > floor {
                let e = shown(j - 1)
                if used + e > budget && j < end { break }
                used += e
                j -= 1
            }
            return j
        }

        /// Segments for lines `range`: runs of whole lines, with each cut line as its own segment.
        func emit(_ range: Range<Int>) -> [FoldedText.Segment] {
            var out: [FoldedText.Segment] = []
            var runStart = range.lowerBound
            for i in range {
                guard isCut(i) else { continue }
                if runStart < i { out.append(.lines(runStart..<i)) }
                out.append(.longLineCut(line: i, hiddenChars: hiddenChars(afterCutOf: i)))
                runStart = i + 1
            }
            if runStart < range.upperBound { out.append(.lines(runStart..<range.upperBound)) }
            return out
        }

        /// Characters after the first `columns * 4` visual columns of line `i` (`keptPrefixEnd`'s rule;
        /// a plain line takes the byte shortcut of its ASCII branch).
        func hiddenChars(afterCutOf i: Int) -> Int {
            let limit = columns * ToolTextBudget.longLineVisualLines
            if plain[i] { return max(0, ends[i] - starts[i] - limit) }
            let line = Substring(String(decoding: UnsafeBufferPointer(rebasing: bytes[starts[i]..<ends[i]]), as: UTF8.self))
            return line.distance(from: ToolTextBudget.keptPrefixEnd(of: line, columns: columns), to: line.endIndex)
        }
    }

    // MARK: - Width

    /// Width of `line`, counting Characters while the running width stays within `stopping`.
    /// `kept` is the number of Characters that fit within `stopping`; `width` is the total width
    /// (only complete when `stopping` is `Int.max`).
    private static func width(of line: Substring, stopping limit: Int) -> (width: Int, kept: Int) {
        var column = 0
        var kept = 0
        for ch in line {
            let w: Int
            if ch == "\t" { w = 4 - column % 4 } else { w = characterWidth(ch) }
            if column + w > limit { break }
            column += w
            kept += 1
        }
        return (column, kept)
    }

    private static func characterWidth(_ ch: Character) -> Int {
        var sawVisible = false
        var wide = false
        for scalar in ch.unicodeScalars {
            let p = scalar.properties
            switch p.generalCategory {
            case .control, .nonspacingMark, .enclosingMark, .format, .lineSeparator, .paragraphSeparator:
                continue
            default:
                break
            }
            sawVisible = true
            if p.isEmojiPresentation || (p.isEmoji && ch.unicodeScalars.contains("\u{FE0F}")) || isWideScalar(scalar.value) {
                wide = true
            }
        }
        if !sawVisible { return 0 }
        return wide ? 2 : 1
    }

    /// East Asian Wide / Fullwidth blocks (Unicode.Scalar.Properties has no width property).
    private static func isWideScalar(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
