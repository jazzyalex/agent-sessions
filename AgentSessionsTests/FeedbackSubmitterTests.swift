import XCTest
@testable import AgentSessions

/// Captures the outgoing request body and returns a canned response so the POST
/// payload can be asserted without touching the network.
final class MockFeedbackURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var failWithError: Bool = false

    static func reset() {
        capturedBody = nil
        statusCode = 200
        failWithError = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves httpBody into a stream; capture it either way.
        if let body = request.httpBody {
            Self.capturedBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            Self.capturedBody = data
        }

        if Self.failWithError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FeedbackSubmitterTests: XCTestCase {
    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockFeedbackURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        MockFeedbackURLProtocol.reset()
    }

    /// Percent-decodes one field from an `application/x-www-form-urlencoded` body.
    private func formValue(_ body: String, name: String) -> String? {
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.first == name {
                return (kv.count > 1 ? kv[1] : "").removingPercentEncoding
            }
        }
        return nil
    }

    func testSubmitPostsFeedbackAndContextInParagraphField() async throws {
        let submitter = FeedbackSubmitter(
            endpoint: URL(string: "https://mock.local/formResponse")!,
            entryField: "entry.999",
            session: mockSession()
        )
        let payload = FeedbackPayload(
            feedback: "Please add tags",
            email: "user@example.com",
            appVersion: "4.3",
            macOSMajorVersion: 15
        )

        try await submitter.submit(payload)

        let body = String(decoding: try XCTUnwrap(MockFeedbackURLProtocol.capturedBody), as: UTF8.self)
        let value = try XCTUnwrap(formValue(body, name: "entry.999"))
        XCTAssertTrue(value.contains("Please add tags"))
        XCTAssertTrue(value.contains("Agent Sessions 4.3"))
        XCTAssertTrue(value.contains("macOS 15"))
        XCTAssertTrue(value.contains("user@example.com"))
    }

    func testSubmitOmitsEmailTagWhenBlank() async throws {
        let submitter = FeedbackSubmitter(
            endpoint: URL(string: "https://mock.local/formResponse")!,
            entryField: "entry.999",
            session: mockSession()
        )
        let payload = FeedbackSubmitter.makePayload(feedback: "No email here", email: "   ")

        try await submitter.submit(payload)

        let body = String(decoding: try XCTUnwrap(MockFeedbackURLProtocol.capturedBody), as: UTF8.self)
        let value = try XCTUnwrap(formValue(body, name: "entry.999"))
        XCTAssertTrue(value.contains("No email here"))
        XCTAssertFalse(value.contains("reply:"))
    }

    func testFormEncodingIsUnambiguousForPlusAndSpace() {
        // A literal "+" must encode to %2B, spaces to %20 — never a bare "+".
        let payload = FeedbackPayload(feedback: "a + b c", email: nil, appVersion: "4.3", macOSMajorVersion: 15)
        let body = String(decoding: FeedbackSubmitter.formBody(for: payload, entryField: "entry.1"), as: UTF8.self)
        XCTAssertTrue(body.contains("%2B"), "literal + must be percent-encoded")
        XCTAssertFalse(body.contains("+"), "no bare + (space must be %20)")
        // The decoded field is the user text followed by the context tag.
        XCTAssertEqual(formValue(body, name: "entry.1")?.hasPrefix("a + b c") == true, true)
    }

    func testSubmitThrowsOnBadStatus() async {
        MockFeedbackURLProtocol.statusCode = 500
        let submitter = FeedbackSubmitter(
            endpoint: URL(string: "https://mock.local/submit")!,
            session: mockSession()
        )
        let payload = FeedbackPayload(feedback: "x", email: nil, appVersion: "4.3", macOSMajorVersion: 15)

        do {
            try await submitter.submit(payload)
            XCTFail("Expected a failure on 500")
        } catch let error as FeedbackSubmitError {
            XCTAssertEqual(error, .badStatus(500))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSubmitThrowsTransportErrorOnFailure() async {
        MockFeedbackURLProtocol.failWithError = true
        let submitter = FeedbackSubmitter(
            endpoint: URL(string: "https://mock.local/submit")!,
            session: mockSession()
        )
        let payload = FeedbackPayload(feedback: "x", email: nil, appVersion: "4.3", macOSMajorVersion: 15)

        do {
            try await submitter.submit(payload)
            XCTFail("Expected a transport failure")
        } catch let error as FeedbackSubmitError {
            if case .transport = error { /* ok */ } else {
                XCTFail("Expected .transport, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testDefaultSubmitterTargetsGoogleForm() {
        let submitter = FeedbackSubmitter()
        XCTAssertEqual(submitter.endpoint, FeedbackSubmitter.formResponseURL)
        XCTAssertEqual(submitter.endpoint.absoluteString.contains("/formResponse"), true)
        XCTAssertTrue(submitter.entryField.hasPrefix("entry."))
    }
}
