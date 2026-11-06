import Foundation

/// The text Find searches for one tool invocation (spec §6.8): what the user can see or open.
///
/// Layout: `ToolInvocation.plainText` (each action's `plainText`, then the script output, joined by a
/// blank line), then, one per line, every footer fact word the renderer shows that the plain text
/// does not already hold (truncation, saved output, agent notes). Base64, ciphertext and envelope
/// text the decoders removed are not in it, so they never match.
enum ToolSearchText {
    /// Where one action's `plainText` (or the script output, `actionIndex == actions.count`) sits in
    /// the search text. Match ranges in it resolve to (action, range in that action's plain text),
    /// the source side of `RenderedToolBody.sourceMap`.
    struct Segment: Equatable, Sendable {
        var actionIndex: Int
        /// UTF-16, in the search text.
        var range: NSRange
    }

    static func text(of invocation: ToolInvocation) -> String {
        let plain = invocation.plainText
        let extras = extraFactWords(of: invocation, plain: plain)
        guard !extras.isEmpty else { return plain }
        return plain + "\n" + extras.joined(separator: "\n")
    }

    static func segments(of invocation: ToolInvocation) -> [Segment] {
        var out: [Segment] = []
        var location = 0
        for (index, action) in invocation.actions.enumerated() {
            if index > 0 { location += 2 }
            let length = action.plainText.utf16.count
            out.append(Segment(actionIndex: index, range: NSRange(location: location, length: length)))
            location += length
        }
        if let script = invocation.scriptOutput?.text, !script.isEmpty {
            if !invocation.actions.isEmpty { location += 2 }
            out.append(Segment(actionIndex: invocation.actions.count,
                               range: NSRange(location: location, length: script.utf16.count)))
        }
        return out
    }

    /// Footer chip words of every action that the plain text does not hold, each once, in order.
    static func extraFactWords(of invocation: ToolInvocation) -> [String] {
        extraFactWords(of: invocation, plain: invocation.plainText)
    }

    private static func extraFactWords(of invocation: ToolInvocation, plain: String) -> [String] {
        var out: [String] = []
        for action in invocation.actions {
            for word in ToolDetailRenderer.footerChipTexts(of: action, in: invocation)
            where !word.isEmpty && !out.contains(word) && !plain.contains(word) {
                out.append(word)
            }
        }
        return out
    }
}

/// Maps a decoded match (a range in `ToolSearchText.text`) to the ranges of a rendered L2 body
/// that show it, through `RenderedToolBody.sourceMap`. Built off the main thread with the body.
///
/// Source locations are not monotone in rendered order (footer chips map back to the bracket line
/// of the plain text), so entries are kept per action, sorted by source location.
struct ToolFindMap: Sendable {
    struct Entry: Sendable {
        /// In the action's `plainText` (the script output's text for the script pane).
        var source: NSRange
        var rendered: NSRange
    }

    static let empty = ToolFindMap(segments: [], sourceMap: [])

    let segments: [ToolSearchText.Segment]
    private let entries: [Int: [Entry]]

    init(segments: [ToolSearchText.Segment], sourceMap: [(rendered: NSRange, actionIndex: Int, source: NSRange)]) {
        self.segments = segments
        var byAction: [Int: [Entry]] = [:]
        for item in sourceMap where item.source.length > 0 {
            byAction[item.actionIndex, default: []].append(Entry(source: item.source, rendered: item.rendered))
        }
        for key in byAction.keys { byAction[key]?.sort { $0.source.location < $1.source.location } }
        entries = byAction
    }

    /// The rendered ranges that show `range`, in rendered order, adjacent pieces merged. Empty when
    /// none of it is shown (folded, past a cut, or text the body does not render).
    func renderedRanges(forSearchRange range: NSRange) -> [NSRange] {
        guard range.length > 0 else { return [] }
        var pieces: [NSRange] = []
        for segment in segments {
            let overlap = NSIntersectionRange(segment.range, range)
            guard overlap.length > 0, let list = entries[segment.actionIndex], !list.isEmpty else { continue }
            let local = NSRange(location: overlap.location - segment.range.location, length: overlap.length)
            let end = NSMaxRange(local)
            // First entry that starts at or after the range, then back over one that straddles its start.
            var low = 0, high = list.count
            while low < high {
                let mid = (low + high) / 2
                if list[mid].source.location < local.location { low = mid + 1 } else { high = mid }
            }
            while low > 0, NSMaxRange(list[low - 1].source) > local.location { low -= 1 }
            var i = low
            while i < list.count, list[i].source.location < end {
                let entry = list[i]
                let hit = NSIntersectionRange(entry.source, local)
                if hit.length > 0 {
                    pieces.append(NSRange(location: entry.rendered.location + hit.location - entry.source.location,
                                          length: hit.length))
                }
                i += 1
            }
        }
        pieces.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for piece in pieces {
            if let last = merged.last, NSMaxRange(last) == piece.location {
                merged[merged.count - 1].length += piece.length
            } else {
                merged.append(piece)
            }
        }
        return merged
    }
}

/// The fold Find opens to show a match the L2 body hides (spec §6.8).
enum ToolFindFolds {
    /// The pane state that shows more of `range` (a range in `ToolSearchText.text(of: invocation)`),
    /// or nil when nothing more can open (the match is past the Show-all caps, in a footer word, or
    /// already open): then the row's pill counts it.
    ///
    /// - Output pane (an action's output or the script output): the cut long line when the body
    ///   offers its "… +N chars" control (`foldLinks`), else Show all.
    /// - Command, heredoc and input fields: the command pane's Show all (`commandShowAll`).
    static func opening(forSearchRange range: NSRange, in invocation: ToolInvocation, folds: [Int: FoldState],
                        foldLinks: [ToolFoldLink]) -> (key: Int, state: FoldState)? {
        guard let segment = ToolSearchText.segments(of: invocation).first(where: {
            NSLocationInRange(range.location, $0.range)
        }) else { return nil }
        let key = segment.actionIndex
        let local = range.location - segment.range.location
        let output: String?
        let outputStart: Int
        if key < invocation.actions.count {
            let action = invocation.actions[key]
            let plainLength = action.plainText.utf16.count
            if let text = action.output?.text, !text.isEmpty, action.plainText.hasSuffix(text) {
                output = text
                outputStart = plainLength - text.utf16.count
            } else {
                output = nil
                outputStart = plainLength
            }
        } else {
            output = invocation.scriptOutput?.text
            outputStart = 0
        }
        var state = folds[key] ?? FoldState()
        if let output, local >= outputStart {
            let line = lineIndex(of: local - outputStart, in: output)
            if foldLinks.contains(.openLongLine(action: key, line: line)), !state.openedLongLines.contains(line) {
                state.openedLongLines.insert(line)
                return (key, state)
            }
            guard !state.showAll else { return nil }
            state.showAll = true
            return (key, state)
        }
        guard key < invocation.actions.count, !state.commandShowAll else { return nil }
        state.commandShowAll = true
        return (key, state)
    }

    /// The 0-based logical line (split on "\n", as `ToolTextBudget` does) of UTF-16 `offset`.
    private static func lineIndex(of offset: Int, in text: String) -> Int {
        var line = 0
        var position = 0
        for unit in text.utf16 {
            if position >= offset { break }
            if unit == 0x0A { line += 1 }
            position += 1
        }
        return line
    }
}

/// Decoded search text per tool invocation for Find (spec §6.8 cost rule).
///
/// `start` runs one pass over every invocation of a snapshot off the main thread at utility
/// priority, from the viewport outward: it reuses a `ToolInvocation` from `invocationCache` (the
/// L2 renderer shares it) and caches what it builds there, so opening a row later needs no build.
/// A text stays valid while its invocation's key ("session|id|contentStamp|status") holds, so a
/// restart after a live append decodes only what changed. Opening a session never waits for a
/// pass: Find searches the raw block text of an invocation until its text is ready.
///
/// Thread-safe: the maps are guarded by one lock; `text(forBlock:)` is called on the main thread
/// while a pass writes.
final class ToolSearchTextStore: @unchecked Sendable {
    typealias Block = SessionTranscriptBuilder.LogicalBlock
    typealias Build = @Sendable (_ ref: ToolInvocationRef, _ blocks: [Block], _ index: ToolInvocationIndex,
                                 _ source: SessionSource, _ duration: Double?) -> ToolInvocation

    /// Built invocations, shared with the Session view's L2 renderer (keys from `invocationKey`).
    let invocationCache: NSCacheMemo<ToolInvocation>
    private let build: Build

    private let lock = NSLock()
    // Guarded by `lock`.
    private var idByBlock: [Int: Int] = [:]
    private var keyByID: [Int: String] = [:]
    private var texts: [Int: (key: String, text: String)] = [:]
    private var generation = 0
    private var complete = false
    private var builds = 0
    private var task: Task<Void, Never>?

    init(invocationCache: NSCacheMemo<ToolInvocation> = NSCacheMemo(countLimit: 512, totalCostLimit: 8_000_000),
         build: @escaping Build = { ToolInvocationBuilder.build($0, blocks: $1, index: $2, source: $3, duration: $4) }) {
        self.invocationCache = invocationCache
        self.build = build
    }

    // MARK: Keys

    /// The `ToolInvocationBuilder.build` cache key of `ref`: it changes when an output arrives or
    /// grows, or the status changes. Session-qualified, because block indices repeat across sessions.
    static func invocationKey(sessionID: String, ref: ToolInvocationRef, blocks: [Block]) -> String {
        "\(sessionID)|\(ref.id)|\(contentStamp(of: ref, blocks: blocks))|\(ref.status)"
    }

    /// `TranscriptToolRows.contentStamp` over the member blocks in the full stream.
    static func contentStamp(of ref: ToolInvocationRef, blocks: [Block]) -> Int {
        let members = memberBlocks(of: ref)
        var length = 0
        for member in members where blocks.indices.contains(member) {
            length += blocks[member].text.utf16.count
        }
        return TranscriptToolRows.contentStamp(memberCount: members.count, utf16Length: length)
    }

    static func memberBlocks(of ref: ToolInvocationRef) -> [Int] {
        (ref.callBlockIndex.map { [$0] } ?? []) + ref.outputBlockIndices
    }

    /// Every invocation of the stream: the index's, plus a lone invocation for each tool block the
    /// index does not know (as `TranscriptToolRows.emit` treats it).
    static func invocationRefs(blocks: [Block], index: ToolInvocationIndex) -> [ToolInvocationRef] {
        var refs = index.invocations
        var lone = false
        for block in blocks where block.kind.isTool && index.invocationIDByBlock[block.globalBlockIndex] == nil {
            let id = block.globalBlockIndex
            let isCall = block.kind == .toolCall
            refs.append(ToolInvocationRef(id: id, callBlockIndex: isCall ? id : nil,
                                          outputBlockIndices: isCall ? [] : [id], status: .unknown))
            lone = true
        }
        if lone { refs.sort { $0.id < $1.id } }
        return refs
    }

    // MARK: Pass

    /// Starts a pass over `blocks` (the full stream of one snapshot), cancelling a running one.
    /// `onComplete` runs on the main actor once, when this pass decoded every invocation, unless
    /// `start` or `cancel` ran since.
    func start(blocks: [Block], index: ToolInvocationIndex, source: SessionSource, sessionID: String,
               viewportBlock: Int, onComplete: @escaping @MainActor () -> Void) {
        lock.lock()
        task?.cancel()
        generation &+= 1
        let pass = generation
        complete = false
        lock.unlock()

        let build = self.build
        let cache = invocationCache
        let running = Task.detached(priority: .utility) { [weak self] in
            let refs = Self.invocationRefs(blocks: blocks, index: index)
            var idByBlock: [Int: Int] = [:]
            var keyByID: [Int: String] = [:]
            for ref in refs {
                for member in Self.memberBlocks(of: ref) { idByBlock[member] = ref.id }
                keyByID[ref.id] = Self.invocationKey(sessionID: sessionID, ref: ref, blocks: blocks)
            }
            guard let self, self.install(pass: pass, idByBlock: idByBlock, keyByID: keyByID) else { return }
            let durations = TranscriptTurnTiming.compute(blocks: blocks, index: index).tools
            for ref in Self.viewportOutward(refs, from: viewportBlock) {
                if Task.isCancelled { return }
                guard let key = keyByID[ref.id], !self.hasText(id: ref.id, key: key) else { continue }
                let invocation: ToolInvocation
                if let cached = cache.object(forKey: key as NSString) {
                    invocation = cached
                } else {
                    let duration = ref.outputBlockIndices.last.flatMap { durations[$0]?.durationSeconds }
                    invocation = build(ref, blocks, index, source, duration)
                    cache.setObject(invocation, forKey: key as NSString, cost: ToolPresentationRenderer.cost(of: invocation))
                    self.noteBuild()
                }
                guard self.store(ToolSearchText.text(of: invocation), id: ref.id, key: key, pass: pass) else { return }
            }
            guard self.finish(pass: pass) else { return }
            await MainActor.run {
                guard self.isCurrent(pass) else { return }
                onComplete()
            }
        }
        lock.lock()
        if generation == pass { task = running }
        lock.unlock()
    }

    /// Stops the running pass and drops every decoded text (a session change).
    func cancel() {
        lock.lock()
        task?.cancel()
        task = nil
        generation &+= 1
        complete = false
        idByBlock = [:]
        keyByID = [:]
        texts = [:]
        lock.unlock()
    }

    // MARK: Reading

    /// For the id block of a decoded invocation: its search text. "" for the invocation's other
    /// member blocks (each match is reported once, at the block of the row that shows it). Nil for
    /// a block that is not a tool block, or whose invocation is not decoded yet (Find then
    /// searches the block's raw text).
    func text(forBlock globalBlockIndex: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = idByBlock[globalBlockIndex], let key = keyByID[id], let entry = texts[id],
              entry.key == key else { return nil }
        return globalBlockIndex == id ? entry.text : ""
    }

    /// The last started pass decoded every invocation.
    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }

    /// Invocations this store built (cache misses), for tests.
    var buildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return builds
    }

    // MARK: Locked steps

    private func install(pass: Int, idByBlock: [Int: Int], keyByID: [Int: String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pass == generation else { return false }
        self.idByBlock = idByBlock
        self.keyByID = keyByID
        texts = texts.filter { keyByID[$0.key] == $0.value.key }
        return true
    }

    private func hasText(id: Int, key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return texts[id]?.key == key
    }

    private func store(_ text: String, id: Int, key: String, pass: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pass == generation else { return false }
        texts[id] = (key, text)
        return true
    }

    private func noteBuild() {
        lock.lock()
        builds += 1
        lock.unlock()
    }

    private func finish(pass: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pass == generation else { return false }
        complete = true
        task = nil
        return true
    }

    private func isCurrent(_ pass: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pass == generation
    }

    /// Nearest to `viewportBlock` first; at equal distance the later invocation first.
    private static func viewportOutward(_ refs: [ToolInvocationRef], from viewportBlock: Int) -> [ToolInvocationRef] {
        refs.sorted { a, b in
            let da = abs(a.id - viewportBlock), db = abs(b.id - viewportBlock)
            return da != db ? da < db : a.id > b.id
        }
    }
}
