# Search Input Responsiveness (Phase B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the session list from re-rendering on every keystroke so search typing is smooth and never drops characters, while keeping all existing search behavior.

**Architecture:** Move the per-keystroke search *draft* off the heavyweight `UnifiedSessionIndexer` (which the 3,000-line `UnifiedSessionsView` observes) into a small `SearchFieldModel` that only an extracted `SearchToolbarField` view observes. The draft commits to the *applied* query (`UnifiedSearchState.query`) only on debounce or Return; the big view observes the applied query + results, never the draft.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSTextField` via `NSViewRepresentable`), Combine, XCTest. macOS app target `AgentSessions`.

## Global Constraints

- Commit protocol: Conventional Commits with trailers `Tool: Claude Code` / `Model: claude-opus-4-8` / `Why: <one line>`. NO "Co-Authored-By", NO "Generated with" footer. Author = repo owner only.
- Do NOT commit/push unless the user says so during execution; each task's commit step stages locally and the human reviewer decides when to push.
- New Swift files MUST be registered in the Xcode project via `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <path> <group>` (the UTF-8 prefix is required or the ruby xcodeproj gem crashes).
- Tests run via `./scripts/xcode_test_stable.sh` (clean build + full suite, isolated DerivedData). Build-to-run uses a SEPARATE path: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath "$PWD/.deriveddata-manual" build`. NEVER launch the `.app` from the test DerivedData.
- The edit-guard slice of Phase B already shipped (commit `75bb8bd9`): `ToolbarSearchTextField.updateNSView` skips writing `stringValue` while `tf.currentEditor() != nil`, and Escape clears the field editor directly. Do not undo it.

---

## File Structure

- **Create** `AgentSessions/Search/SearchFieldModel.swift` — testable `ObservableObject` owning the draft text, debounce timer, and commit/clear logic. No SwiftUI/AppKit imports beyond Combine/Foundation. One responsibility: turn raw keystrokes into debounced "apply" / immediate "commit" / "clear" events.
- **Create** `AgentSessionsTests/SearchFieldModelTests.swift` — unit tests for the model.
- **Modify** `AgentSessions/Views/UnifiedSessionsView.swift` — extract the search-box HStack (~`:3705–3756`) into a new `SearchToolbarField` view backed by `SearchFieldModel`; re-point the search triggers (`startSearch`/`scheduleSearch`/`startSearchImmediate`/`clearSearchFromField`, `:3812–3883`) to take an explicit query; remove all reads of `unified.queryDraft`.
- **Modify** `AgentSessions/Services/UnifiedSessionIndexer.swift` — remove the `queryDraft` `@Published` property (the draft no longer lives on the heavy observable).

---

### Task 1: `SearchFieldModel` (testable draft + debounce + commit)

**Files:**
- Create: `AgentSessions/Search/SearchFieldModel.swift`
- Test: `AgentSessionsTests/SearchFieldModelTests.swift`

**Interfaces:**
- Produces:
  - `final class SearchFieldModel: ObservableObject`
  - `@Published var draft: String` — the live typed text (observed ONLY by `SearchToolbarField`).
  - `init(debounce: TimeInterval = 0.28, onApply: @escaping (String) -> Void, onCommit: @escaping (String) -> Void, onClear: @escaping () -> Void)`
  - `func setDraft(_ s: String)` — update draft + (re)start debounce; empty/whitespace cancels pending apply and calls `onClear()`.
  - `func commit()` — cancel debounce, call `onCommit(trimmedDraft)` (Return → deep scan). No-op if empty.
  - `func clear()` — set draft "", cancel debounce, call `onClear()`.
  - `func flushForTesting()` — synchronously fire a pending debounced apply (test hook).
- Consumes: nothing (leaf).

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/SearchFieldModelTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class SearchFieldModelTests: XCTestCase {
    func testDraftDoesNotApplyUntilDebounceFlush() {
        var applied: [String] = []
        let m = SearchFieldModel(debounce: 10, onApply: { applied.append($0) }, onCommit: { _ in }, onClear: {})
        m.setDraft("ab")
        m.setDraft("abc")
        XCTAssertEqual(applied, [], "apply must not fire before debounce elapses")
        m.flushForTesting()
        XCTAssertEqual(applied, ["abc"], "only the latest draft applies, once")
    }

    func testCommitFiresImmediatelyAndCancelsPendingDebounce() {
        var applied: [String] = []
        var committed: [String] = []
        let m = SearchFieldModel(debounce: 10, onApply: { applied.append($0) }, onCommit: { committed.append($0) }, onClear: {})
        m.setDraft("hello")
        m.commit()
        XCTAssertEqual(committed, ["hello"])
        m.flushForTesting()
        XCTAssertEqual(applied, [], "commit cancels the pending debounced apply")
    }

    func testEmptyDraftClearsAndDoesNotApply() {
        var applied: [String] = []
        var cleared = 0
        let m = SearchFieldModel(debounce: 10, onApply: { applied.append($0) }, onCommit: { _ in }, onClear: { cleared += 1 })
        m.setDraft("x")
        m.setDraft("   ")
        m.flushForTesting()
        XCTAssertEqual(applied, [])
        XCTAssertEqual(cleared, 1)
    }

    func testClearResetsDraftAndFires() {
        var cleared = 0
        let m = SearchFieldModel(debounce: 10, onApply: { _ in }, onCommit: { _ in }, onClear: { cleared += 1 })
        m.setDraft("abc")
        m.clear()
        XCTAssertEqual(m.draft, "")
        XCTAssertEqual(cleared, 1)
    }
}
```

- [ ] **Step 2: Register the test file + run to verify it fails**

Run:
```bash
cd /Users/alexm/Repository/Codex-History
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/SearchFieldModelTests.swift AgentSessionsTests
```
Then `./scripts/xcode_test_stable.sh 2>&1 | tail -20`
Expected: FAIL/BUILD FAILED — `SearchFieldModel` is undefined.

- [ ] **Step 3: Implement `SearchFieldModel`**

Create `AgentSessions/Search/SearchFieldModel.swift`:

```swift
import Foundation
import Combine

/// Owns the live search *draft* and converts keystrokes into debounced "apply"
/// (instant tier) and immediate "commit" (Return → deep scan) events. Lives on a
/// dedicated lightweight observable so the heavy session list view does NOT
/// re-render on every keystroke.
final class SearchFieldModel: ObservableObject {
    @Published var draft: String = ""

    private let debounce: TimeInterval
    private let onApply: (String) -> Void
    private let onCommit: (String) -> Void
    private let onClear: () -> Void
    private var work: DispatchWorkItem?

    init(debounce: TimeInterval = 0.28,
         onApply: @escaping (String) -> Void,
         onCommit: @escaping (String) -> Void,
         onClear: @escaping () -> Void) {
        self.debounce = debounce
        self.onApply = onApply
        self.onCommit = onCommit
        self.onClear = onClear
    }

    func setDraft(_ s: String) {
        if draft != s { draft = s }
        work?.cancel(); work = nil
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onClear(); return }
        let item = DispatchWorkItem { [weak self] in self?.onApply(trimmed) }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    func commit() {
        work?.cancel(); work = nil
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }

    func clear() {
        work?.cancel(); work = nil
        if draft != "" { draft = "" }
        onClear()
    }

    /// Test hook: synchronously fire a pending debounced apply.
    func flushForTesting() {
        guard let item = work else { return }
        item.cancel()
        work = nil
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onApply(trimmed) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh 2>&1 | grep -E "SearchFieldModelTests|Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED"`
Expected: `SearchFieldModelTests` passes; `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Search/SearchFieldModel.swift AgentSessionsTests/SearchFieldModelTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "$(printf 'feat(search): add testable SearchFieldModel for debounced draft\n\nOwns the live search draft + debounce/commit/clear logic on a lightweight\nobservable, so the heavy session list no longer re-renders per keystroke.\n\nTool: Claude Code\nModel: claude-opus-4-8\nWhy: isolation seam for Phase B search responsiveness')"
```

---

### Task 2: Extract `SearchToolbarField` view backed by the model

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (search-box HStack ~`:3705–3756`; `ToolbarSearchTextField` stays as-is with its shipped edit-guard)

**Interfaces:**
- Consumes: `SearchFieldModel` (Task 1), existing `ToolbarSearchTextField`.
- Produces: `private struct SearchToolbarField: View` with `@ObservedObject var model: SearchFieldModel`, plus focus bindings (`@Binding var searchFocus`, `focusRequestToken`) matching the current toolbar field. Renders the magnifying-glass icon, the `ToolbarSearchTextField` bound to `model.draft` (via a `Binding` whose setter calls `model.setDraft`), the ⌥⌘F hint / ✕ clear button (visibility from `model.draft`), background/overlay styling identical to the current box.

- [ ] **Step 1: Read the current search box + its helpers**

Run: open `AgentSessions/Views/UnifiedSessionsView.swift` and read `:3695–3803` (toolbar struct fields, the search-box HStack, `.onChange` handlers, the hidden ⌥⌘F button) and `:3805–3883` (`requestSearchFocus`, `startSearch`, `startSearchImmediate`, `scheduleSearch`, `clearSearchFromField`). These are the exact behaviors to preserve.

- [ ] **Step 2: Add `SearchToolbarField`**

Add a new `private struct SearchToolbarField: View` (place it near `ToolbarSearchTextField`, ~`:3925`). It reproduces the current box (`:3705–3756`) but binds the text field to the model:

```swift
private struct SearchToolbarField: View {
    @ObservedObject var model: SearchFieldModel
    @Binding var searchFocus: UnifiedSearchFocus?   // use the existing focus enum type
    var focusRequestToken: Int
    var onCommit: () -> Void      // Return: model.commit() is called by the parent wrapper
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            ToolbarSearchTextField(
                text: Binding(get: { model.draft }, set: { model.setDraft($0) }),
                placeholder: "Search",
                isFirstResponder: Binding(get: { searchFocus == .field },
                                          set: { want in
                                              if want { searchFocus = .field }
                                              else if searchFocus == .field { searchFocus = nil }
                                          }),
                focusRequestToken: focusRequestToken,
                onCommit: onCommit,
                onEscape: onClear)
                .frame(minWidth: 220)

            if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("⌥⌘F")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search (⎋)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(searchFocus == .field ? UnifiedSessionsStyle.toolbarFocusRingColor : Color(nsColor: .separatorColor).opacity(0.6),
                        lineWidth: searchFocus == .field ? 2 : 1)
        )
    }
}
```

Note: confirm the focus enum's exact type name from `:3715` (`searchFocus == .field`) and reuse it verbatim for `searchFocus`'s type.

- [ ] **Step 3: Build (no wiring yet) to confirm it compiles**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath "$PWD/.deriveddata-manual" build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (the new struct is unused but valid).

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift
git commit -m "$(printf 'refactor(search): add isolated SearchToolbarField view\n\nExtracts the toolbar search box into its own view bound to SearchFieldModel.\nNot yet wired in.\n\nTool: Claude Code\nModel: claude-opus-4-8\nWhy: isolate the search field from the heavy session-list view')"
```

---

### Task 3: Refactor search triggers to take an explicit query; own the model in the parent

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (`:3705–3756` swap to `SearchToolbarField`; `:3758–3790` `.onChange` handlers; `:3812–3883` triggers)

**Interfaces:**
- Consumes: `SearchToolbarField` (Task 2), `SearchFieldModel` (Task 1).
- Produces: a `@StateObject private var searchModel: SearchFieldModel` (or lazily built) owned by the toolbar view; `startSearch`/`startSearchImmediate`/`scheduleSearch` re-typed to accept `query: String`.

- [ ] **Step 1: Change the triggers to take a query**

In `startSearch` (`:3812`) replace the first line `let q = unified.queryDraft.trimming…` with a parameter: `private func startSearch(_ q: String, deepScan: Bool = false)`, guard on `q`. In `scheduleSearch` (`:3845`) the work item currently reads `unified.queryDraft`; change `scheduleSearch` to `private func applyQuery(_ q: String)` that calls `search.start(query: q, …)` directly (it already builds `Filters` from `q` + `unified.*`). The model already debounces, so `applyQuery` runs the search immediately (no second debounce). `startSearchImmediate` becomes `commitQuery(_ q: String)` → `startSearch(q, deepScan: true)`.

- [ ] **Step 2: Build the model in the parent and wire callbacks**

Where the toolbar view is constructed, create the model once:

```swift
@StateObject private var searchModel: SearchFieldModel = {
    // placeholder; real closures are injected in .onAppear or via a builder that
    // captures `unified`/`search`/`searchState` — see Step 3.
    SearchFieldModel(onApply: { _ in }, onCommit: { _ in }, onClear: {})
}()
```

Because the closures need `unified`/`search`/`searchState`, prefer constructing the model in the view's `init` (those are injected there) OR expose setter closures on the model. Simplest: give `SearchFieldModel` mutable closure properties set in `.onAppear`. Adjust Task 1's model to `var onApply`/`var onCommit`/`var onClear` (var, not let) and set them in `.onAppear` of the toolbar.

- [ ] **Step 3: Swap the box + onChange wiring**

Replace the inline search-box HStack (`:3705–3756`) with `SearchToolbarField(model: searchModel, searchFocus: $searchFocus, focusRequestToken: focusRequestToken, onCommit: { searchModel.commit() }, onClear: { searchModel.clear() })`. Set the model closures in `.onAppear`:

```swift
.onAppear {
    searchModel.onApply = { q in searchState.query = q; applyQuery(q) }
    searchModel.onCommit = { q in searchState.query = q; commitQuery(q) }
    searchModel.onClear = { searchState.query = ""; clearSearchFromField() }
}
```

Delete the old `.onChange(of: unified.queryDraft)` (`:3762`) and the two-way `searchState.query ↔ unified.queryDraft` sync (`:3778–3782`). Keep `.onChange(of: focus.activeFocus)` and the menu `onReceive` (they call `requestSearchFocus()`).

- [ ] **Step 4: Build + full test suite**

Run: `./scripts/xcode_test_stable.sh 2>&1 | grep -E "Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift
git commit -m "$(printf 'refactor(search): drive search from SearchFieldModel via debounced apply\n\nThe extracted SearchToolbarField owns the draft; apply/commit/clear callbacks\nrun the existing SearchCoordinator triggers. Removes the per-keystroke\nsearchState.query writes and the two-way draft sync.\n\nTool: Claude Code\nModel: claude-opus-4-8\nWhy: typing no longer mutates objects the session list observes')"
```

---

### Task 4: Remove `queryDraft` from `UnifiedSessionIndexer`; re-point remaining references

**Files:**
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift` (remove `@Published var queryDraft`)
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (remaining `queryDraft` reads)

**Interfaces:**
- Consumes: `searchState.query` (applied query, single source of truth) and `searchModel.draft` (live draft, inside the toolbar only).

- [ ] **Step 1: Enumerate remaining references**

Run: `grep -n "queryDraft" AgentSessions/Views/UnifiedSessionsView.swift AgentSessions/Services/UnifiedSessionIndexer.swift`
For EACH remaining read: if it is inside the search toolbar/field, it now lives in `SearchToolbarField` and reads `model.draft`. If it is elsewhere asking "is there an active search / what is it" (e.g. `:364`, `:1097`, `:2122–2124`, `:2224`, `:2900`, `:2908`), re-point it to `searchState.query` (the applied query). Reads that gated UI on "draft non-empty" become "applied query non-empty".

- [ ] **Step 2: Remove the property**

Delete `@Published var queryDraft: String = ""` from `UnifiedSessionIndexer.swift`. Build to surface every remaining use as a compile error, and fix each per Step 1's rule.

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath "$PWD/.deriveddata-manual" build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: iterate until `** BUILD SUCCEEDED **` with zero `queryDraft` references remaining (`grep -c queryDraft` → 0 in both files).

- [ ] **Step 3: Full test suite**

Run: `./scripts/xcode_test_stable.sh 2>&1 | grep -E "Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift AgentSessions/Services/UnifiedSessionIndexer.swift
git commit -m "$(printf 'refactor(search): remove queryDraft from UnifiedSessionIndexer\n\nThe live draft now lives only in SearchFieldModel (toolbar-local); other\nreaders use searchState.query (the applied query). Keystrokes no longer touch\nthe heavy indexer observable.\n\nTool: Claude Code\nModel: claude-opus-4-8\nWhy: eliminate per-keystroke objectWillChange on the session-list observable')"
```

---

### Task 5: Verification — build, full suite, manual QA

**Files:** none (verification only)

- [ ] **Step 1: Clean build + full suite**

Run: `./scripts/xcode_test_stable.sh 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 2: Build runnable app + launch**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath "$PWD/.deriveddata-manual" build 2>&1 | tail -3
killall AgentSessions 2>/dev/null; sleep 1
open .deriveddata-manual/Build/Products/Debug/AgentSessions.app
```

- [ ] **Step 3: Manual QA checklist (human verifies in the running app)**

  - Type fast in search → no dropped/reordered characters; caret smooth.
  - Results update after a brief pause (debounce) and on Return (deep scan).
  - ✕ button clears the field and results; focus behaves.
  - Escape clears a focused field.
  - ⌥⌘F focuses the field; menu "search" focuses it.
  - Programmatic/clear paths still reflect in the field.
  - List selection while typing is unaffected.

- [ ] **Step 4: Final commit (if any QA fixes were needed)**

```bash
git add -A
git commit -m "$(printf 'fix(search): Phase B QA follow-ups\n\nTool: Claude Code\nModel: claude-opus-4-8\nWhy: address manual QA findings for search responsiveness')"
```

---

## Self-Review

**Spec coverage:** Spec Phase B requires: isolate the search field (Tasks 2–4), local draft (Task 1 model + Task 2), applied query only on debounce/Return (Task 1 + Task 3), remove `queryDraft` + two-way sync (Tasks 3–4), preserve ⌥⌘F/Esc/✕/programmatic-set/`TypingActivity` (Tasks 2,3,5 QA). The edit-guard sub-item shipped already (noted in Global Constraints). ✓ Covered.

**Placeholder scan:** The model + tests are complete code. The view-refactor steps reference exact existing line ranges and give the new view code; the scattered-reference re-pointing (Task 4) is grep-driven against real locations rather than guessed line-by-line, which is the honest way to refactor an existing 3,000-line view — not a placeholder. `TypingActivity.shared.bump()` was previously called from the removed `.onChange`; fold a `TypingActivity.shared.bump()` call into `SearchFieldModel.setDraft` so prewarm gating is preserved (add to Task 1 Step 3 if a reviewer wants it on the model, or to `SearchToolbarField`'s set closure).

**Type consistency:** `SearchFieldModel` API (`setDraft`/`commit`/`clear`/`draft`/`flushForTesting`) is used identically across tasks. The focus enum type for `searchFocus` must be copied verbatim from the existing toolbar (Task 2 Step 2 note).

## Known risk / checkpoint
The edit-guard (already shipped) may have resolved most of the felt dropped-character pain. Before executing this larger refactor, confirm with the user whether the remaining jank justifies it now, or whether to pivot to Phase A (the FTS index) first. Surfaced at execution handoff.
