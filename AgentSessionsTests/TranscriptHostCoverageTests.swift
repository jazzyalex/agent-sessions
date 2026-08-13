import XCTest
@testable import AgentSessions

/// `TranscriptHostView` keeps one layer per provider in a single `ZStack` and reveals the
/// selected one with `opacity`, so that switching providers does not reset the split
/// layout. The cost of that design is that the compiler cannot tell when a provider has
/// no layer: the view still builds, and every layer sits at zero opacity, so the session
/// opens to a blank transcript.
///
/// Grok shipped that way — its indexer was declared on the view, passed in from the
/// caller, and never referenced in the body. The list, the hierarchy and the search index
/// were all correct; only the transcript was empty.
final class TranscriptHostCoverageTests: XCTestCase {

    func testTranscriptHostCoversEverySource() {
        let missing = Set(SessionSource.allCases).subtracting(TranscriptHostView.coveredSources)
        XCTAssertTrue(missing.isEmpty,
                      "no transcript layer for \(missing.map(\.rawValue).sorted()) — the session will open blank; add a layer in TranscriptHostView's ZStack and list the source in coveredSources")

        let unknown = TranscriptHostView.coveredSources.subtracting(Set(SessionSource.allCases))
        XCTAssertTrue(unknown.isEmpty,
                      "coveredSources lists \(unknown.map(\.rawValue).sorted()), which are not real sources")
    }
}
