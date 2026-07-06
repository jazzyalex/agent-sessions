import XCTest
@testable import AgentSessions

/// C4a: Terminal was removed from the transcript view-mode menu and the old
/// "Session" (Terminal) view was renamed away, with Rich (.blocks) taking over
/// the "Session" name. `resolveViewMode` is the single source of truth for
/// mapping a persisted preference into a still-reachable view mode, so a user
/// who had Terminal selected doesn't land on a blank/unreachable view after
/// upgrading. These pins cover every persisted-state combination named in the
/// task's self-review checklist.
final class SessionViewModeMigrationTests: XCTestCase {

    // MARK: - viewModeRaw takes precedence when it's a valid, recognized value

    func testPersistedTerminalResolvesToBlocks() {
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: "terminal", renderModeRaw: "terminal"),
            .blocks
        )
    }

    func testPersistedBlocksStaysBlocks() {
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: "blocks", renderModeRaw: "normal"),
            .blocks
        )
    }

    func testPersistedTranscriptStaysTranscript() {
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: "transcript", renderModeRaw: "normal"),
            .transcript
        )
    }

    func testPersistedJSONStaysJSON() {
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: "json", renderModeRaw: "json"),
            .json
        )
    }

    // MARK: - Unknown/empty viewModeRaw falls back to legacy renderModeRaw

    func testEmptyViewModeRawFallsBackToLegacyRenderMode() {
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: "", renderModeRaw: "normal"),
            .transcript
        )
    }

    func testEmptyViewModeRawWithLegacyTerminalRenderModeResolvesToBlocks() {
        // A pre-C4a install that only ever wrote the legacy TranscriptRenderMode
        // key (never the newer SessionViewMode key) with "terminal" must also
        // land on Session (.blocks), not the now-unreachable Terminal view.
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: "", renderModeRaw: "terminal"),
            .blocks
        )
    }

    func testEmptyViewModeRawWithLegacyJSONRenderModeResolvesToJSON() {
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: "", renderModeRaw: "json"),
            .json
        )
    }

    func testUnknownViewModeRawAndUnknownRenderModeDefaultsToBlocks() {
        // Fully unrecognized/garbage state (e.g. a corrupted default) must not
        // crash or resolve to an unreachable mode; default to the new Session view.
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: "bogus", renderModeRaw: "also-bogus"),
            .blocks
        )
    }

    func testUnknownViewModeRawWithEmptyRenderModeDefaultsToBlocks() {
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: "", renderModeRaw: ""),
            .blocks
        )
    }

    // MARK: - New user (no persisted pref at all) gets the AppStorage default

    func testNewUserDefaultRawValueResolvesToBlocks() {
        // TranscriptPlainView's @AppStorage("SessionViewMode") default is
        // SessionViewMode.blocks.rawValue post-C4a; confirm that default
        // round-trips through resolveViewMode unchanged.
        XCTAssertEqual(
            resolveViewMode(viewModeRaw: SessionViewMode.blocks.rawValue, renderModeRaw: TranscriptRenderMode.terminal.rawValue),
            .blocks
        )
    }
}
