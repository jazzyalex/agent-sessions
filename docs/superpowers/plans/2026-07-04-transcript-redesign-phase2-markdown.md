# Transcript Redesign Phase 2 — Markdown Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render user/assistant message bodies in the Rich block list as GFM markdown — inline styles, headers, code fences as dark inset cards, inline-code chips, lists, and tables — while keeping Phase 1's cross-block selection, ⌘F highlights, whole-session find counts, and height parity intact.

**Architecture:** Apple's `swift-markdown` (SPM) parses each body to a CommonMark+GFM AST; a custom `MarkdownBodyRenderer` walk emits an `NSAttributedString` plus a **source map** (`[SourceMapSegment]`) recording where each run of `block.text` landed in the rendered string. Find matches stay computed against `block.text` in `TranscriptDerivedState` (unchanged — Terminal parity preserved); the view maps each match range through the source map to paint highlights on the rendered body, falling back to the existing pill when a match lands in consumed syntax or an unmappable region (table cell). Bodies stay `SelectableBlockTextView` (NSTextView) so selection/find/copy are untouched in mechanism.

**Tech Stack:** Swift, AppKit (NSTextView, NSTextTable, NSLayoutManager, NSParagraphStyle), `swift-markdown` SPM package (Apple), XCTest.

## Global Constraints

- **swift-markdown dependency APPROVED** (owner, 2026-07-04). Add via `XCRemoteSwiftPackageReference` in `project.pbxproj`, same mechanism as the existing Sparkle package. Apple-authored, pure Swift, macOS-14 compatible. Product: `Markdown`.
- **macOS deployment floor: 14.0.** No macOS-15-only APIs.
- **NO commits, NO push, NO branches without explicit owner request.** Work stays in the working tree on `feature/transcript-redesign-v5`; per-task diffs via controller `git write-tree` snapshots. Skip any "Commit" step — the controller snapshots instead.
- **Subagents NEVER run xcodebuild/swift build/tests.** ONE central verification in the main session: `./scripts/xcode_test_stable.sh` (full suite; currently 1268 green). Single suite: append `-only-testing:AgentSessionsTests/<ClassName>`.
- **New Swift files** registered via `RUBYOPT="-E UTF-8" ./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <FILE_PATH> <GROUP_PATH>` (the UTF-8 prefix avoids the pbxproj US-ASCII encoding error hit in Phase 1). App files → `AgentSessions` target; tests → `AgentSessionsTests`. Do NOT touch `AgentSessionsLogicTests` (three duplicate targets; unrelated).
- **Foreign in-flight files — never touch** (a concurrent session owns them): `AgentSessions/CodexStatus/UsageDisplayFormatter.swift`, `AgentSessions/CodexStatus/UsageDisplayMode.swift`, `AgentSessions/CodexStatus/CodexStatusService.swift`, `AgentSessions/ClaudeStatus/ClaudeUsageModel.swift`, `AgentSessions/Views/AgentCockpitHUDView.swift`, `AgentSessions/Views/Preferences/*`, `AgentSessionsTests/CodexUsageParserTests.swift`.
- **Locked scope exclusions (owner):** NO cost/token header badges; NO per-language syntax highlighting inside fences (tier-2 later — fences get dark-card styling only); NO Focused mode.
- **Only user + assistant + error(plain) bodies change.** Tool call/output bodies stay plain monospace (they're commands/JSON/logs — markdown would corrupt them). Meta stays a separator. This keeps tool-card find/selection shapes (`expandedSingleToolFull`/`Truncated`) on their identity source map, untouched.
- **Copy semantics = "copy what you see"** (rendered plain text, not markdown source) — consistent with Phase 1's truncated-tool-body rule. Markdown export path (`TranscriptMarkdownExporter`) must remain source-fidelity: it reads `block.text`, never `RenderedBody`.
- **Acceptance gates preserved:** ⌘F highlight+next/prev (incl. off-window widen), cross-block selection+copy, follow-tail, markdown export unchanged, the seven perf suites green.
- All paths repo-relative from `/Users/alexm/Repository/Codex-History`.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `AgentSessions/Services/RenderedBody.swift` | create (T12) | `SourceMapSegment`, `RenderedBody` (attributed + source map + unmappable ranges), `renderedRange(forSourceRange:)` mapping, `RenderKey` |
| `AgentSessions/Services/MarkdownBodyRenderer.swift` | create (T12) | swift-markdown AST walk → `RenderedBody`; inline styles + headers + paragraphs (T12), fences + inline-code chips (T13), lists (T14), tables (T15) |
| `AgentSessions/Views/TranscriptBlockListView.swift` | modify (T12–T15) | `renderedBodyCache`, `measuredHeight` LayoutManager path, `RowShape.markdownMessage` wiring, appearance observer, search-auto-expand |
| `AgentSessions/Services/TranscriptFindNavigator.swift` | modify (T12) | `RowShape.markdownMessage(RenderedBody)` case + `renderableRange` mapping |
| `AgentSessions.xcodeproj/project.pbxproj` | modify (T12) | swift-markdown package ref + product link; new source-file registrations |
| `AgentSessionsTests/MarkdownBodyRendererTests.swift` | create (T12) | source-map round-trip, inline styles, render-plain-text |
| `AgentSessionsTests/MarkdownSourceMapTests.swift` | create (T12) | `renderedRange` mapping incl. nil on syntax-boundary crossing |
| `AgentSessionsTests/MarkdownFenceListTableTests.swift` | create (T13–T15) | fence verbatim identity map, list markers, table cell → unmappable |

---

### Task 12: swift-markdown dependency + inline rendering + source-map foundation

The biggest and riskiest task — it establishes the seam. Inline-only keeps source-map deltas simple (only `**`/`_`/`` ` `` consumed) so the map is proven on the safe case before any structure-shifting feature depends on it.

**Files:**
- Modify: `AgentSessions.xcodeproj/project.pbxproj` (package ref + link + registrations)
- Create: `AgentSessions/Services/RenderedBody.swift`
- Create: `AgentSessions/Services/MarkdownBodyRenderer.swift`
- Modify: `AgentSessions/Services/TranscriptFindNavigator.swift`
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift`
- Test: `AgentSessionsTests/MarkdownBodyRendererTests.swift`, `AgentSessionsTests/MarkdownSourceMapTests.swift`

**Interfaces:**
- Consumes: `SessionTranscriptBuilder.LogicalBlock` (`.kind`, `.text`, `.eventID`); Phase-1 `TranscriptFindNavigator.RowShape` + `renderableRange(_:shape:)`; controller `heightCache`, `fontBucket(_:)`, the width observer, the `sessionID != self.sessionID` reset block, `applyRenderableFindHighlights`, `renderedSelectableText(for:)`.
- Produces (later tasks + the view rely on these EXACT names):
  - `struct SourceMapSegment: Equatable { var sourceRange: NSRange; var renderedLocation: Int }`
  - `struct RenderedBody { var attributed: NSAttributedString; var segments: [SourceMapSegment]; var renderedLength: Int; var unmappableSourceRanges: [NSRange]; func renderedRange(forSourceRange: NSRange) -> NSRange? }`
  - `struct RenderKey: Hashable { var eventID: String; var textHash: Int; var fontBucket: Int; var isDark: Bool }`
  - `enum MarkdownBodyRenderer { static func render(_ text: String, baseFont: NSFont, isDark: Bool) -> RenderedBody }`
  - `RowShape.markdownMessage(RenderedBody)` case
  - `BlockTableController.renderedBody(for: BlockRowModel) -> RenderedBody` (cache-backed)
  - `static func measuredHeight(of: NSAttributedString, width: CGFloat) -> CGFloat`

- [ ] **Step 1: Add the swift-markdown package to the Xcode project**

Add an `XCRemoteSwiftPackageReference` for `https://github.com/apple/swift-markdown.git` (branch `main` or a pinned release tag — check what tag exists; `swift-markdown` uses date/commit tags, pin to the latest release), add the `Markdown` product to the `AgentSessions` target's Frameworks build phase + `packageProductDependencies`, mirroring the existing Sparkle `XCRemoteSwiftPackageReference` blocks in `project.pbxproj`. Locate Sparkle's blocks first (`grep -n Sparkle AgentSessions.xcodeproj/project.pbxproj`) and copy their structure exactly. Since `xcode_add_file.rb` does not add package refs, edit the pbxproj directly (or use a Ruby `xcodeproj` snippet). Verify by grepping that `Markdown` appears in exactly one `packageProductDependencies` list (the app target).

- [ ] **Step 2: Write the failing source-map round-trip test**

`AgentSessionsTests/MarkdownSourceMapTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class MarkdownSourceMapTests: XCTestCase {
    private func body(_ md: String) -> RenderedBody {
        MarkdownBodyRenderer.render(md, baseFont: .monospacedSystemFont(ofSize: 13, weight: .regular), isDark: true)
    }

    // Every source offset NOT inside consumed syntax must map to a rendered
    // offset whose character equals the source character.
    func testSourceMapRoundTripPlainText() {
        let src = "hello world"
        let b = body(src)
        let srcNS = src as NSString
        let renderedNS = b.attributed.string as NSString
        for i in 0..<srcNS.length {
            guard let r = b.renderedRange(forSourceRange: NSRange(location: i, length: 1)) else { continue }
            XCTAssertEqual(renderedNS.substring(with: r), srcNS.substring(with: NSRange(location: i, length: 1)))
        }
    }

    func testBoldConsumedSyntaxMapsInnerText() {
        let src = "a **bold** b"          // '**' consumed; 'bold' preserved
        let b = body(src)
        let renderedNS = b.attributed.string as NSString
        // source offset of 'b' in 'bold' is 4
        let r = b.renderedRange(forSourceRange: NSRange(location: 4, length: 4)) // "bold"
        XCTAssertNotNil(r)
        XCTAssertEqual(renderedNS.substring(with: r!), "bold")
    }

    func testRangeSpanningConsumedSyntaxReturnsNil() {
        let src = "a **bold** b"
        let b = body(src)
        // a source range starting at the '*' (offset 2) crosses a consumed boundary
        XCTAssertNil(b.renderedRange(forSourceRange: NSRange(location: 2, length: 4)))
    }

    func testRenderedPlainTextDropsSyntax() {
        XCTAssertEqual(body("**hi**").attributed.string, "hi")
        XCTAssertEqual(body("a `code` b").attributed.string, "a code b")
    }
}
```

- [ ] **Step 3: Register the test file and run it to verify failure**

```bash
RUBYOPT="-E UTF-8" ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/MarkdownSourceMapTests.swift AgentSessionsTests
```
(Controller runs `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/MarkdownSourceMapTests` → FAIL: types not defined.)

- [ ] **Step 4: Implement `RenderedBody.swift`**

```swift
import Foundation

/// One contiguous source→rendered mapping segment. `sourceRange` is UTF-16 into
/// block.text; `renderedLocation` is where that source text begins in the
/// rendered attributed string. Segments are sorted by sourceRange.location and
/// non-overlapping. A gap in source coverage = consumed markdown syntax
/// (`**`, backticks, list markers) — never a mappable find target. A gap in
/// rendered coverage = inserted glyphs (bullets, table separators).
struct SourceMapSegment: Equatable {
    var sourceRange: NSRange
    var renderedLocation: Int
}

/// Per-block render product. Lives in the VIEW layer (controller cache), never
/// in TranscriptDerivedState — it carries resolved (appearance-baked) colors.
struct RenderedBody {
    var attributed: NSAttributedString
    var segments: [SourceMapSegment]
    var renderedLength: Int
    /// Source ranges that rendered into a non-highlightable region (table cell,
    /// group annotation). A match here → pill/count only, never a paint.
    var unmappableSourceRanges: [NSRange]

    /// Map a match range in block.text to the rendered range to highlight.
    /// nil when the source range spans a consumed-syntax boundary or lands in
    /// an unmappable region — caller falls back to the pill (like a collapsed card).
    func renderedRange(forSourceRange src: NSRange) -> NSRange? {
        if unmappableSourceRanges.contains(where: { NSIntersectionRange($0, src).length > 0 }) {
            return nil
        }
        guard let seg = segments.last(where: { $0.sourceRange.location <= src.location }),
              NSMaxRange(src) <= NSMaxRange(seg.sourceRange) else { return nil }
        let delta = seg.renderedLocation - seg.sourceRange.location
        return NSRange(location: src.location + delta, length: src.length)
    }
}

/// Cache key for a rendered body. eventID (not globalBlockIndex — indices shift
/// on prepend/widen; eventID is stable). textHash catches a streaming delta
/// mutating the same block. isDark because colors are baked at render time.
struct RenderKey: Hashable {
    var eventID: String
    var textHash: Int
    var fontBucket: Int
    var isDark: Bool
}
```

- [ ] **Step 5: Run the source-map test again (mapping logic only) — still fails on renderer**

`renderedRange` now exists but `MarkdownBodyRenderer.render` doesn't. Proceed.

- [ ] **Step 6: Write the failing renderer test**

`AgentSessionsTests/MarkdownBodyRendererTests.swift`:

```swift
import XCTest
import AppKit
@testable import AgentSessions

final class MarkdownBodyRendererTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func testEmphasisAttributeApplied() {
        let b = MarkdownBodyRenderer.render("*italic*", baseFont: font, isDark: true)
        XCTAssertEqual(b.attributed.string, "italic")
        var found = false
        b.attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: b.attributed.length)) { v, _, _ in
            if let f = v as? NSFont, f.fontDescriptor.symbolicTraits.contains(.italic) { found = true }
        }
        XCTAssertTrue(found)
    }

    func testHeaderIsLargerThanBody() {
        let b = MarkdownBodyRenderer.render("# Title", baseFont: font, isDark: true)
        let f = b.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(f)
        XCTAssertGreaterThan(f!.pointSize, font.pointSize)
        XCTAssertEqual(b.attributed.string, "Title")
    }

    func testParagraphsSeparatedByNewline() {
        let b = MarkdownBodyRenderer.render("one\n\ntwo", baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("one"))
        XCTAssertTrue(b.attributed.string.contains("two"))
    }

    func testInlineCodeMonospacedChip() {
        let b = MarkdownBodyRenderer.render("call `foo()` now", baseFont: font, isDark: true)
        XCTAssertEqual(b.attributed.string, "call foo() now")
        // the code run carries a background color chip attribute
        let codeLoc = (b.attributed.string as NSString).range(of: "foo()").location
        let bg = b.attributed.attribute(.backgroundColor, at: codeLoc, effectiveRange: nil)
        XCTAssertNotNil(bg)
    }
}
```

- [ ] **Step 7: Register and implement `MarkdownBodyRenderer.swift` (inline + headers + paragraphs)**

```bash
RUBYOPT="-E UTF-8" ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Services/RenderedBody.swift AgentSessions/Services
RUBYOPT="-E UTF-8" ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Services/MarkdownBodyRenderer.swift AgentSessions/Services
RUBYOPT="-E UTF-8" ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/MarkdownBodyRendererTests.swift AgentSessionsTests
```

Implement the AST walk with `import Markdown`. Structure:
- Parse `let document = Document(parsing: text)`.
- Walk block children, appending to an `NSMutableAttributedString`, tracking a `[SourceMapSegment]` and the current rendered length. For each inline text run, record a segment mapping its `block.text` source offset (swift-markdown gives source ranges via `SourceRange` when parsed with source info — parse with `Document(parsing: text, options: .parseBlockDirectives)` is NOT needed; use the default and compute offsets by matching literal text, OR parse and use `markup.range`). **Implementer note:** swift-markdown's `Markup.range` gives `SourceLocation` (line/column) — convert to UTF-16 offsets via a precomputed line-start table over `text`. If range info proves unreliable for inline nodes, fall back to a forward-scan matching each `Text` node's `string` in `block.text` starting from the last consumed offset (monotonic scan — robust because rendered order follows source order). Document which approach you used.
- Inline handlers: `Text` → plain run (segment recorded); `Emphasis` → italic trait; `Strong` → bold trait; `InlineCode` → monospaced run + `.backgroundColor` chip (`NSColor.quaternaryLabelColor`); `Link` → `.link` attribute (destination). Base font: proportional system font for prose (headers/paragraphs), but keep `baseFont` (monospaced) as the fallback for inline code so AS monospace identity holds — **decision: prose uses `NSFont.systemFont(ofSize: baseFont.pointSize)`, inline code / fences use `baseFont` (monospaced).**
- Block handlers (T12 scope): `Heading` → size ramp (`baseFont.pointSize + (7 - level) * 2`, bold); `Paragraph` → run + `\n\n` separator (the separator is rendered-only, no source segment). `Text` inside these recorded in the map.
- Build `RenderedBody(attributed:, segments:, renderedLength: attributed.length, unmappableSourceRanges: [])` (empty unmappable for T12 — no tables yet).

Delete any nil-returning stubs once tests pass.

- [ ] **Step 8: Wire `RowShape.markdownMessage` into TranscriptFindNavigator**

In `TranscriptFindNavigator.swift`, add the case and mapping:
```swift
enum RowShape: Equatable {
    case message
    case markdownMessage(RenderedBody)          // NEW
    case expandedSingleToolFull
    case expandedSingleToolTruncated(visibleUTF16Len: Int)
    case nonRenderable
}
```
(Note: `RenderedBody` is not `Equatable` by default — either make `RowShape` non-Equatable if nothing needs it, or give `RenderedBody`/`SourceMapSegment` `Equatable` conformance excluding `attributed`, OR store an id. Check what currently requires `RowShape: Equatable` and choose the least-invasive option; document it.)
In `renderableRange(_:shape:)` add:
```swift
case .markdownMessage(let body):
    return body.renderedRange(forSourceRange: matchRange)
```

- [ ] **Step 9: Controller — render cache, measurement, and shape selection**

In `BlockTableController` (`TranscriptBlockListView.swift`):
- Add `private var renderedBodyCache = LRUCache<RenderKey, RenderedBody>(capacity: 400)` (reuse the existing `LRUCache`; check its exact init signature and adapt). If `LRUCache` is class-keyed only, key by `RenderKey` (Hashable — fine).
- Add `func renderedBody(for row: BlockRowModel) -> RenderedBody?` returning nil for non-markdown shapes (tool/meta/error), else cache-lookup-or-render with `RenderKey(eventID:, textHash: block.text.hashValue, fontBucket: fontBucket(fontSize), isDark: effectiveAppearanceIsDark)`.
- Add `static func measuredHeight(of attributed: NSAttributedString, width: CGFloat) -> CGFloat` using the NSLayoutManager stack from the memo (lineFragmentPadding 0, `ensureLayout`, `ceil(usedRect.height)`).
- In the message-body configure path: if the row is a user/assistant block, set `bodyText.textStorage.setAttributedString(renderedBody.attributed)` instead of `bodyText.string = block.text`, compute height via `measuredHeight`, and set the row's `RowShape` to `.markdownMessage(renderedBody)`. Tool/error/meta unchanged.
- `renderedSelectableText(for:)`: for a markdown row return `renderedBody.attributed.string`; else unchanged.
- Reset: clear `renderedBodyCache` in the `sessionID != self.sessionID` block and in the `fontChanged` branch (next to `heightCache` clears).

- [ ] **Step 10: Appearance observer for baked colors**

Add an effective-appearance change path: the cell's `viewDidChangeEffectiveAppearance` posts to the controller (or the controller observes its own view's appearance), which clears `renderedBodyCache`, calls `reconfigureVisibleRows()`, and `noteAllHeightsChanged()` (or the existing equivalent). Verify against the Phase-1 `DynamicFillView` appearance handling so the two don't fight; place the observer teardown in `dismantleNSView`/`tearDown`.

- [ ] **Step 11: Central verification**

Controller runs `./scripts/xcode_test_stable.sh`. Expected: full suite green + the new markdown suites. Watch the seven perf suites and the Phase-1 find/selection tests (a source-map bug would surface as a highlight test failure if any exist; most are runtime-QA).

- [ ] **Step 12: Controller tree snapshot (no commit) + owner visual QA hand-off**

Controller builds Debug and relaunches. Owner QA: assistant message with bold/italic/inline-code/headers renders; ⌘F highlights land ON the rendered words (not shifted); drag-select across a rendered paragraph + a plain tool card copies sensible text; A−/A+ and dark/light re-render correctly.

---

### Task 13: Code fences (dark inset cards) + inline-code chips polish

~80% of the code-readability win per the proposal. Fences render verbatim → identity source-map segment, so ⌘F works *inside* code.

**Files:**
- Modify: `AgentSessions/Services/MarkdownBodyRenderer.swift`
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift` (fence background drawing if needed)
- Test: `AgentSessionsTests/MarkdownFenceListTableTests.swift`

**Interfaces:**
- Consumes: T12's `MarkdownBodyRenderer.render`, `RenderedBody`, `measuredHeight`.
- Produces: fenced code blocks as a distinct dark-background paragraph run; the fence's inner text is a single identity `SourceMapSegment` (source offset == rendered offset shift is constant).

- [ ] **Step 1: Failing fence tests**

`AgentSessionsTests/MarkdownFenceListTableTests.swift`:
```swift
import XCTest
import AppKit
@testable import AgentSessions

final class MarkdownFenceListTableTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func testFenceContentVerbatimAndMonospaced() {
        let md = "```\nlet x = 1\n```"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("let x = 1"))
        // fence content carries a dark background attribute
        let loc = (b.attributed.string as NSString).range(of: "let x").location
        XCTAssertNotNil(b.attributed.attribute(.backgroundColor, at: loc, effectiveRange: nil))
        let f = b.attributed.attribute(.font, at: loc, effectiveRange: nil) as? NSFont
        XCTAssertTrue(f?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
    }

    func testFenceContentIsFindableViaSourceMap() {
        let md = "text before\n```\nneedle here\n```"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        let src = md as NSString
        let needleSrc = src.range(of: "needle")
        let r = b.renderedRange(forSourceRange: needleSrc)
        XCTAssertNotNil(r)   // fence inner text is mappable (identity segment)
        XCTAssertEqual((b.attributed.string as NSString).substring(with: r!), "needle")
    }
}
```

- [ ] **Step 2: Register the test file, run to verify failure**

```bash
RUBYOPT="-E UTF-8" ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/MarkdownFenceListTableTests.swift AgentSessionsTests
```

- [ ] **Step 3: Implement `CodeBlock` handler**

In the walk: `CodeBlock` node → emit its `.code` string verbatim (swift-markdown gives the literal fence content, trailing newline included — trim exactly one trailing `\n` to avoid a blank line; document the choice) as a run with: monospaced `baseFont`, `.backgroundColor` = a dark inset color (`NSColor.textBackgroundColor` blended toward black in dark mode / a light-gray inset in light mode — pick via `isDark`), a `NSParagraphStyle` with head/tail indent (~8pt) and paragraph spacing so it reads as a card. Record ONE `SourceMapSegment` covering the entire fence-content source range → its rendered location (identity shift). The fence's info-string (language) is captured but NOT rendered/highlighted (tier-2). No source segment for the consumed ` ``` ` delimiters.

- [ ] **Step 4: Inline-code chip polish**

Confirm the T12 inline-code chip reads well against both appearances (adjust the `.backgroundColor` per `isDark`); add horizontal padding illusion via a thin space or a subtle `.baselineOffset` if needed (keep minimal — a background run is enough).

- [ ] **Step 5: Central verification + QA hand-off + snapshot**

`./scripts/xcode_test_stable.sh`. Owner QA: a fenced code block renders as a dark card, ⌘F finds text inside it, copy of the fence yields the code without backticks.

---

### Task 14: Lists (bullet + numbered, ≥1 nesting level)

First feature that inserts marker glyphs → first real rendered-side source-map gaps. Ships only after T12's map is proven.

**Files:**
- Modify: `AgentSessions/Services/MarkdownBodyRenderer.swift`
- Test: `AgentSessionsTests/MarkdownFenceListTableTests.swift` (extend)

**Interfaces:**
- Consumes: T12 renderer + source map.
- Produces: `UnorderedList`/`OrderedList` handlers emitting `•\t`/`N.\t` marker glyphs (rendered-only, no source segment) + `NSParagraphStyle` indents; list item text recorded in the source map.

- [ ] **Step 1: Failing list tests (extend the file)**

```swift
func testBulletListMarkersAndText() {
    let md = "- first\n- second"
    let b = MarkdownBodyRenderer.render(md, baseFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), isDark: true)
    let s = b.attributed.string
    XCTAssertTrue(s.contains("first"))
    XCTAssertTrue(s.contains("second"))
    XCTAssertTrue(s.contains("•"))   // marker glyph present
}

func testListItemTextIsFindable() {
    let md = "- alpha\n- beta"
    let b = MarkdownBodyRenderer.render(md, baseFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), isDark: true)
    let betaSrc = (md as NSString).range(of: "beta")
    let r = b.renderedRange(forSourceRange: betaSrc)
    XCTAssertNotNil(r)
    XCTAssertEqual((b.attributed.string as NSString).substring(with: r!), "beta")
}

func testOrderedListNumbers() {
    let md = "1. one\n2. two"
    let b = MarkdownBodyRenderer.render(md, baseFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), isDark: true)
    XCTAssertTrue(b.attributed.string.contains("1."))
    XCTAssertTrue(b.attributed.string.contains("2."))
}
```

- [ ] **Step 2: Run to verify failure** (controller `-only-testing`).

- [ ] **Step 3: Implement list handlers**

`UnorderedList`/`OrderedList` → for each `ListItem`, emit marker (`"•\t"` or `"\(n).\t"`, rendered-only — advance rendered length WITHOUT adding a source segment) then walk the item's inline/paragraph children (recording segments as normal), then `\n`. Indent via `NSParagraphStyle.headIndent`/`firstLineHeadIndent` scaled by nesting depth (track depth in the walk; support ≥1 level). Ensure the source map stays monotonic (marker glyphs create rendered gaps, which `renderedRange`'s segment lookup already tolerates — the delta jumps at each segment boundary).

- [ ] **Step 4: Central verification + QA + snapshot**

`./scripts/xcode_test_stable.sh`. Owner QA: nested bullet + numbered lists render with indents; ⌘F highlights list item text correctly (the marker-glyph rendered gap must not shift the highlight — this is the source-map's first real test in the app).

---

### Task 15: GFM tables

Highest risk, lowest frequency — ships last so a table bug can't block the inline/fence/list wins. Table cells are unmappable (find → pill), copy yields tab-separated cells.

**Files:**
- Modify: `AgentSessions/Services/MarkdownBodyRenderer.swift`
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift` (confirm `measuredHeight` LayoutManager path covers tables)
- Test: `AgentSessionsTests/MarkdownFenceListTableTests.swift` (extend)

**Interfaces:**
- Consumes: T12 renderer + `measuredHeight` (LayoutManager path — becomes load-bearing here); `RenderedBody.unmappableSourceRanges`.
- Produces: `Table` handler using `NSTextTable`/`NSTextTableBlock`; table source ranges added to `unmappableSourceRanges` → find falls back to pill.

- [ ] **Step 1: Failing table tests (extend the file)**

```swift
func testTableCellsRenderedAndUnmappable() {
    let md = "| a | b |\n|---|---|\n| 1 | 2 |"
    let b = MarkdownBodyRenderer.render(md, baseFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), isDark: true)
    let s = b.attributed.string
    XCTAssertTrue(s.contains("a")); XCTAssertTrue(s.contains("1")); XCTAssertTrue(s.contains("2"))
    // a match inside a table cell is unmappable → renderedRange nil (falls back to pill)
    let cellSrc = (md as NSString).range(of: "1")
    XCTAssertNil(b.renderedRange(forSourceRange: cellSrc))
    XCTAssertFalse(b.unmappableSourceRanges.isEmpty)
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `Table` handler**

`Table` node → build an `NSTextTable` (columns = header cell count), each cell an `NSTextTableBlock` with border/padding, walk header + body rows emitting cell text into cell paragraphs. Add each cell's source range to `unmappableSourceRanges` (so `renderedRange` returns nil → pill count still works via `findMatchCount`). Confirm markdown row height for a table routes through the `measuredHeight` LayoutManager path (tables mismeasure under `boundingRect` — the memo's R2). If T12 routed ALL markdown bodies through `measuredHeight`, this is already covered — verify and note.

- [ ] **Step 4: Central verification + QA + snapshot**

`./scripts/xcode_test_stable.sh`. Owner QA (the AgentsView-parity moment): a GFM table renders as an actual table with borders; row height is correct (no clipping — the Phase-1 ShowAll bug class); ⌘F on a term inside a table shows the header pill/count (no in-cell highlight, by design); copy of a table yields tab/newline-separated cells.

---

### Task 16: Search-auto-expand of collapsed tool cards

Replaces the Phase-1 interim pill-only behavior: a *navigated* match inside a collapsed tool card auto-expands it. Independent of markdown — could run any time after Phase 1, placed here to close the Phase 2 plan's find story.

**Files:**
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift`

**Interfaces:**
- Consumes: Phase-1 `scrollToCurrentFindMatch`, `expandedToolRowIDs`, `toggleToolExpansion`, `scrollToBlock`, `rebuildFindMatchesByRowIDIfActive`, `showAllRowIDs`, the `applyFind` empty-query clear branch, the session-switch reset.
- Produces: `autoExpandedByFind: Set<Int>` tracking; expand-on-navigate; Esc/clear re-collapse of only-auto-expanded-untouched rows.

- [ ] **Step 1: Add auto-expand in `scrollToCurrentFindMatch`**

Before the `scrollToBlock(target)` call: resolve the current match's row id; if it's a collapsed tool row (or a merged group) not already expanded, `expandedToolRowIDs.insert(rowID)`, `autoExpandedByFind.insert(rowID)`, `noteHeightOfRows` (zero-duration, pre-scroll), and `rebuildFindMatchesByRowIDIfActive()` so the row now paints in-body highlights. If the match is past the 20-line truncation fold, also `showAllRowIDs.insert(rowID)`. This MUST precede `scrollToBlock` so the row's expanded height is settled when `scrollToBlock`'s `layoutSubtreeIfNeeded`/`scrollRowToVisible` run (memo Q6). No animation on the expand (a find jump lands instantly; `flashRow` gives confirmation).

- [ ] **Step 2: Re-collapse on Esc/clear**

In `applyFind`'s empty-query clear branch: for each id in `autoExpandedByFind` still present AND not manually re-toggled, remove from `expandedToolRowIDs` (and `showAllRowIDs` if auto-set), then `noteAllHeightsChanged()`. Clear `autoExpandedByFind`.

- [ ] **Step 3: Respect manual override**

In `toggleToolExpansion`: if the user manually toggles a row that's in `autoExpandedByFind`, remove it from that set so their explicit choice survives an Esc.

- [ ] **Step 4: Reset seam**

Clear `autoExpandedByFind` in the `sessionID != self.sessionID` reset block, next to the other find/expansion resets.

- [ ] **Step 5: Central verification + QA + snapshot**

`./scripts/xcode_test_stable.sh` (this task is view-logic; if the expand/collapse decision is factored into a pure helper, add a unit test — else runtime-QA). Owner QA: ⌘F to a hit inside a collapsed tool card → it auto-expands and highlights; next past it and Esc → it re-collapses; manually expand a card during find then Esc → it stays open.

---

### Task 17: Phase 2 final gate

- [ ] **Step 1: Full suite** — `./scripts/xcode_test_stable.sh`. Everything green incl. all markdown suites and the seven perf suites.
- [ ] **Step 2: Export-unchanged regression check** — confirm `TranscriptMarkdownExporter` output is byte-identical to pre-Phase-2 for a fixture session (it must read `block.text`, never `RenderedBody`). Add/confirm a test asserting this.
- [ ] **Step 3: Perf sanity on a monster session** — Debug build; owner opens the largest local session in Rich mode with markdown. Bar: open stays fast (render is cached, off the paint path); scrolling smooth; a live streaming assistant delta doesn't jank (only the mutating block re-renders per `textHash`). If it janks, apply memo R7: render `isDelta` blocks plain, re-render on finalize.
- [ ] **Step 4: Acceptance checklist with owner (Rich mode, markdown):** rendered inline styles/headers/fences/lists/tables; ⌘F highlights on rendered prose + inside fences + pills for table cells; cross-block selection+copy = readable "what you see"; dark/light flip re-renders; export unchanged.
- [ ] **Step 5: Update docs** — mark Phase 2 done in the HANDOVER doc; note Phase 3 (turn timing badges) is next; record the copy-what-you-see semantics + swift-markdown dependency in release-notes material.
- [ ] **Step 6: Ask the owner** about the commit/merge conversation for the whole Phase 0+1+2 body of work (nothing committed yet; foreign usage-display files excluded).

---

## Appendix — adopted architecture decisions (Opus memo, 2026-07-04)

1. **Stack:** swift-markdown (SPM, Apple, owner-approved) → custom `NSAttributedString` builder. `NSAttributedString(markdown:)` rejected (macOS 14 drops block elements + no source map); SwiftUI renderers rejected (bodies must stay NSTextView for selection/find/copy).
2. **Range mapping (the crux):** find matches stay computed against `block.text` in `TranscriptDerivedState` (Terminal parity untouched); the view owns a per-block source map; highlights map source→rendered through it; unmappable spots (consumed syntax, table cells) fall back to the existing pill. Copy = rendered plain text ("what you see").
3. **Which blocks:** user + assistant only (no code-detection heuristic); tool/error stay plain monospace; meta stays separator.
4. **Height:** all markdown bodies measured via an `NSLayoutManager` stack (matches display exactly; avoids the `boundingRect`-vs-`NSTextTable` gap). `boundingRect` stays only for plain bodies.
5. **Cache:** per-block `RenderedBody` LRU in the controller, keyed `eventID+textHash+fontBucket+isDark`; invalidated on font change, appearance flip, live-append (via textHash), session switch.
6. **Auto-expand:** trigger in `scrollToCurrentFindMatch` before `scrollToBlock`; Esc re-collapses only auto-expanded-untouched rows.
7. **Task order:** inline+source-map (T12) → fences+chips (T13) → lists (T14) → tables (T15) → auto-expand (T16) → gate (T17). Source map proven on the low-risk inline case before any structure-shifting feature depends on it.
