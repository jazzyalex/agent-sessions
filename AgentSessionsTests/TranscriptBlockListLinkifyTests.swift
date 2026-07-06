import XCTest
@testable import AgentSessions

/// Task C3 (Rich linkify parity). Pure-logic tests for
/// `BlockTableController.computeLinkAttributes(in:sessionCwd:repoRootPath:)` —
/// the Rich-mode equivalent of `SessionTerminalView.Coordinator.linkAttributes`,
/// tested without a table, cell, or controller instance (mirrors
/// `TranscriptBlockListReviewCardTests`'s static-method testing pattern).
final class TranscriptBlockListLinkifyTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptBlockListLinkifyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    /// `path:line:column` against a file that exists relative to `sessionCwd`
    /// resolves to a match with a decodable payload carrying the same
    /// path/line/column — the core round-trip the click handler depends on.
    func testResolvesPathLineColumnRelativeToSessionCwd() throws {
        let fileURL = tempDir.appendingPathComponent("Foo.swift")
        try "// hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let text = "See Foo.swift:12:3 for details"
        let results = BlockTableController.computeLinkAttributes(in: text, sessionCwd: tempDir.path, repoRootPath: nil)

        XCTAssertEqual(results.count, 1)
        let decoded = try XCTUnwrap(TranscriptLinkifier.decodePayload(results[0].payload))
        XCTAssertEqual(decoded.path, fileURL.path)
        XCTAssertEqual(decoded.line, 12)
        XCTAssertEqual(decoded.column, 3)
    }

    /// A match whose path doesn't resolve against either cwd or repoRoot is
    /// dropped entirely (never surfaces as a dead link).
    func testUnresolvablePathProducesNoLinks() {
        let text = "See Missing.swift:5:1 for details"
        let results = BlockTableController.computeLinkAttributes(in: text, sessionCwd: tempDir.path, repoRootPath: nil)
        XCTAssertTrue(results.isEmpty)
    }

    /// Ordinary prose with no path-like tokens never reaches `matches` at all
    /// (the `mightContainFileLink` pre-filter short-circuits) — asserted here
    /// via the empty-result contract, matching `TranscriptLinkifier`'s own
    /// fast-path tests.
    func testPlainProseYieldsNoLinks() {
        let text = "The plan looks good, let's proceed with the next step."
        XCTAssertTrue(BlockTableController.computeLinkAttributes(in: text, sessionCwd: tempDir.path, repoRootPath: nil).isEmpty)
    }

    /// Resolution falls back to `repoRootPath` when `sessionCwd` doesn't
    /// contain the file — same fallback order as `TranscriptLinkifier.resolve`.
    func testFallsBackToRepoRootWhenNotFoundUnderCwd() throws {
        let repoRoot = tempDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let fileURL = repoRoot.appendingPathComponent("Bar.swift")
        try "// hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let otherCwd = tempDir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCwd, withIntermediateDirectories: true)

        let text = "Bar.swift:1"
        let results = BlockTableController.computeLinkAttributes(in: text, sessionCwd: otherCwd.path, repoRootPath: repoRoot.path)

        XCTAssertEqual(results.count, 1)
        let decoded = try XCTUnwrap(TranscriptLinkifier.decodePayload(results[0].payload))
        XCTAssertEqual(decoded.path, fileURL.path)
        XCTAssertEqual(decoded.line, 1)
        XCTAssertNil(decoded.column)
    }
}
