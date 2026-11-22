import XCTest
@testable import AgentSessions

final class SearchQueryTests: XCTestCase {
    private func makeQuery(_ input: String) throws -> (SearchQuery, SearchTokenizer) {
        let tokenizer = try SearchTokenizer()
        return (try SearchQuery(input, tokenizer: tokenizer), tokenizer)
    }

    func testNativeUnicode61CaseAccentAndTokenBoundaries() throws {
        let tokenizer = try SearchTokenizer()

        XCTAssertEqual(try tokenizer.tokens("ÉCOLE"), ["ecole"])
        XCTAssertEqual(try tokenizer.tokens("café"), try tokenizer.tokens("cafe\u{301}"))
        XCTAssertEqual(try tokenizer.tokens("foo_bar"), ["foo", "bar"])
        XCTAssertEqual(try tokenizer.tokens("foo-bar"), ["foo", "bar"])
        XCTAssertEqual(try tokenizer.tokens("foo.bar"), ["foo", "bar"])
    }

    func testImplicitTermsMatchAcrossFieldsButPhraseCannotCrossBoundary() throws {
        let (implicit, implicitTokenizer) = try makeQuery("alpha beta")
        let implicitAccumulator = SearchPredicateAccumulator(query: implicit, tokenizer: implicitTokenizer)
        try implicitAccumulator.consume(field: "alpha")
        try implicitAccumulator.consume(field: "beta")
        XCTAssertTrue(implicitAccumulator.truth(complete: true) == .yes)
        XCTAssertEqual(implicit.atoms.map(\.prefix), [true, true])

        let (phrase, phraseTokenizer) = try makeQuery("\"alpha beta\"")
        let splitAccumulator = SearchPredicateAccumulator(query: phrase, tokenizer: phraseTokenizer)
        try splitAccumulator.consume(field: "alpha")
        try splitAccumulator.consume(field: "beta")
        XCTAssertTrue(splitAccumulator.witnesses.isEmpty)
        XCTAssertTrue(splitAccumulator.truth(complete: true) == .no)

        let sameFieldAccumulator = SearchPredicateAccumulator(query: phrase, tokenizer: phraseTokenizer)
        try sameFieldAccumulator.consume(field: "alpha beta")
        XCTAssertTrue(sameFieldAccumulator.truth(complete: true) == .yes)
    }

    func testBooleanPrecedenceAndIncompleteThreeValuedEvaluation() throws {
        let (query, _) = try makeQuery("alpha OR beta AND NOT gamma")

        XCTAssertEqual(query.predicate, .or(.atom(0), .and(.atom(1), .not(.atom(2)))))
        XCTAssertEqual(query.atoms.map(\.prefix), [false, false, false])
        XCTAssertTrue(query.truth(witnesses: [0], complete: false) == .yes)
        XCTAssertTrue(query.truth(witnesses: [1], complete: false) == .unknown)
        XCTAssertTrue(query.truth(witnesses: [1], complete: true) == .yes)

        let (negative, _) = try makeQuery("alpha NOT beta")
        XCTAssertTrue(negative.truth(witnesses: [0], complete: false) == .unknown)
        XCTAssertTrue(negative.truth(witnesses: [0], complete: true) == .yes)
        XCTAssertTrue(negative.truth(witnesses: [0, 1], complete: false) == .no)
    }

    func testPunctuationAtomAndExplicitPhrasePrefixApplyOnlyToFinalToken() throws {
        let (automatic, automaticTokenizer) = try makeQuery("foo_bar")
        XCTAssertEqual(automatic.atoms.count, 1)
        XCTAssertEqual(automatic.atoms[0].tokens, ["foo", "bar"])
        XCTAssertTrue(automatic.atoms[0].prefix)

        let automaticMatch = SearchPredicateAccumulator(query: automatic, tokenizer: automaticTokenizer)
        try automaticMatch.consume(field: "foo barista")
        XCTAssertTrue(automaticMatch.truth(complete: true) == .yes)

        let firstTokenMustStayExact = SearchPredicateAccumulator(query: automatic, tokenizer: automaticTokenizer)
        try firstTokenMustStayExact.consume(field: "fooz barista")
        XCTAssertTrue(firstTokenMustStayExact.truth(complete: true) == .no)

        let (explicit, _) = try makeQuery("\"foo bar\"*")
        XCTAssertEqual(explicit.atoms[0].tokens, ["foo", "bar"])
        XCTAssertTrue(explicit.atoms[0].prefix)
        XCTAssertEqual(explicit.atoms[0].fts, "\"foo bar\"*")
    }

    func testMetadataQuotesLiteralsAndRepeatedValuesUseLastValue() throws {
        let (pathQuery, _) = try makeQuery("path:\"my repo\" alpha")
        XCTAssertEqual(pathQuery.metadata.path, "my repo")
        XCTAssertNil(pathQuery.metadata.repo)
        XCTAssertEqual(pathQuery.freeText, "alpha")
        XCTAssertEqual(pathQuery.atoms.count, 1)

        let (literal, _) = try makeQuery("\"path:needle\"")
        XCTAssertNil(literal.metadata.path)
        XCTAssertEqual(literal.atoms.count, 1)
        XCTAssertEqual(literal.atoms[0].tokens, ["path", "needle"])
        XCTAssertFalse(literal.atoms[0].prefix)

        let (repeated, _) = try makeQuery("repo:first path:old repo:second path:\"last value\" #side \"path:literal\"")
        XCTAssertEqual(repeated.metadata.repo, "second")
        XCTAssertEqual(repeated.metadata.path, "last value")
        XCTAssertTrue(repeated.metadata.sideChatsOnly)
        XCTAssertEqual(repeated.freeText, "\"path:literal\"")
        XCTAssertEqual(repeated.atoms[0].tokens, ["path", "literal"])
    }

    func testValidationRejectsTooManyTermsOversizedEmptyAndUnsupportedQueries() throws {
        let tokenizer = try SearchTokenizer()
        let atLimit = try SearchQuery(Array(repeating: "x", count: 128).joined(separator: " "), tokenizer: tokenizer)
        XCTAssertEqual(atLimit.atoms.count, 128)

        XCTAssertThrowsError(try SearchQuery(Array(repeating: "x", count: 129).joined(separator: " "), tokenizer: tokenizer))
        XCTAssertThrowsError(try SearchQuery(String(repeating: "x", count: 8193), tokenizer: tokenizer))
        XCTAssertThrowsError(try SearchQuery("\"\"", tokenizer: tokenizer))
        XCTAssertThrowsError(try SearchQuery("alpha NEAR beta", tokenizer: tokenizer))
        XCTAssertThrowsError(try SearchQuery("alpha (beta)", tokenizer: tokenizer))
        XCTAssertThrowsError(try SearchQuery("path:", tokenizer: tokenizer))
    }

    func testNegativeOnlyQueryHasNoFTSCandidate() throws {
        let (query, _) = try makeQuery("NOT alpha")
        XCTAssertNil(query.ftsCandidate)
    }
}
