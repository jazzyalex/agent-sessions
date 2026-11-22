import XCTest
@testable import AgentSessions

final class ClaudeCredentialIntegrationTests: XCTestCase {
    private final class Store: ClaudeSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var value: String? = "sk-ant-sid01-account-A"
        func read() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        func write(_ value: String) -> Bool { lock.lock(); defer { lock.unlock() }; self.value = value; return true }
        func delete() { lock.lock(); defer { lock.unlock() }; value = nil }
    }
    private actor Gate {
        private var continuation: CheckedContinuation<[ClaudeCloudRawSession], Error>?
        private var entered = 0
        func fetch() async throws -> [ClaudeCloudRawSession] {
            entered += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func hasEntered(_ count: Int) -> Bool { entered >= count && continuation != nil }
        func finish(_ result: Result<[ClaudeCloudRawSession], Error>) { continuation?.resume(with: result); continuation = nil }
    }
    private func wait(_ gate: Gate, count: Int = 1) async throws {
        for _ in 0..<200 { if await gate.hasEntered(count) { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Fake request did not start")
    }

    @MainActor
    func testCatalogRejectsSuccessAfterRemove() async throws {
        let credentials = ClaudeCredentialService(store: Store())
        let gate = Gate()
        let catalog = ClaudeCloudSessionCatalog(credentials: credentials, fetch: { _, _, _ in try await gate.fetch() }, isEnabled: { true })
        let pending = Task { await catalog.refresh() }
        try await wait(gate)
        _ = try await credentials.remove()
        catalog.invalidate(disabled: false)
        await gate.finish(.success([Self.row]))
        await pending.value
        XCTAssertEqual(catalog.sessions.count, 0)
        XCTAssertEqual(catalog.state, .notConnected)
    }

    @MainActor
    func testCatalogRejectsErrorAfterDisableAndAllowsFreshRefresh() async throws {
        let credentials = ClaudeCredentialService(store: Store())
        let gate = Gate()
        let catalog = ClaudeCloudSessionCatalog(credentials: credentials, fetch: { _, _, _ in try await gate.fetch() }, isEnabled: { true })
        let pending = Task { await catalog.refresh() }
        try await wait(gate)
        catalog.invalidate(disabled: true)
        await gate.finish(.failure(ClaudeCloudError.expired))
        await pending.value
        XCTAssertEqual(catalog.state, .disabled)
        let fresh = Task { await catalog.refresh() }
        try await wait(gate, count: 2)
        await gate.finish(.success([Self.row]))
        await fresh.value
        XCTAssertEqual(catalog.sessions.map(\.id), ["cloud-A"])
    }

    func testCloudStopsBeforePageRequestWhenDisabledDuringOrgLookup() async throws {
        let credentials = ClaudeCredentialService(store: Store())
        let lease = ClaudeCredentialRequestLease(owner: credentials.currentOwner, credentials: credentials)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CredentialURLProtocol.setHandler(nil) }
        let requests = RequestRecorder()
        CredentialURLProtocol.setHandler { request in
            requests.record(request.url!.path)
            lease.cancel()
            return Data("[{\"uuid\":\"org-A\"}]".utf8)
        }
        let client = ClaudeCloudAPIClient(session: session, credentials: credentials)
        do {
            _ = try await client.listSessions(sessionKey: "A", owner: credentials.currentOwner, lease: lease)
            XCTFail("Cancelled lease must reject the organization completion")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests.paths, ["/api/organizations"])
    }

    func testCloudOrgCacheIsNotReusedByAnotherOwner() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CredentialURLProtocol.setHandler(nil) }
        let requests = RequestRecorder()
        CredentialURLProtocol.setHandler { request in
            requests.record(request.url!.path)
            let account = request.value(forHTTPHeaderField: "Cookie")!.contains("=A") ? "A" : "B"
            return Data("[{\"uuid\":\"org-\(account)\"}]".utf8)
        }
        let client = ClaudeCloudAPIClient(session: session)
        let a = try await client.resolveOrgID(sessionKey: "A")
        let b = try await client.resolveOrgID(sessionKey: "B")
        XCTAssertEqual(a, "org-A"); XCTAssertEqual(b, "org-B")
        XCTAssertEqual(requests.paths.count, 2)
    }

    @MainActor
    func testQueuedAvailabilityIsRejectedAfterRequestCancellation() {
        let credentials = ClaudeCredentialService(store: Store())
        let lease = ClaudeCredentialRequestLease(owner: credentials.currentOwner, credentials: credentials)
        let queued = ClaudeServiceAvailability(cliUnavailable: false, tmuxUnavailable: false,
            transientReason: "obsolete failure", captionOnly: true,
            credentialOwner: credentials.currentOwner, requestLease: lease)
        lease.cancel()
        let model = ClaudeUsageModel()
        model.applyAvailability(queued)
        XCTAssertNil(model.transientReason)
    }

    func testCancelledSnapshotCannotOverwriteNewerPersistedSnapshot() async throws {
        let credentials = ClaudeCredentialService(store: Store())
        let lease = ClaudeCredentialRequestLease(owner: credentials.currentOwner, credentials: credentials)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ClaudeUsageSnapshotStore(fileURL: url)
        var old = ClaudeLimitSnapshot(fetchedAt: Date(), source: .webEndpoint, health: .live,
            fiveHourUsedRatio: 0.1, fiveHourResetText: "", weeklyUsedRatio: 0.1,
            weeklyResetText: "", weekOpusUsedRatio: nil, weekOpusResetText: nil, rawPayloadHash: nil)
        old.ownership = credentials.currentOwner
        old.requestLease = lease
        await store.save(old)
        let decoded = await store.load()
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.requestLease, "A process-local lease must not survive serialization")
        XCTAssertFalse(decoded?.webOwnershipIsCurrent ?? true)
        var current = old
        current.source = .oauthEndpoint; current.ownership = "oauth:B"; current.requestLease = nil
        current.fiveHourUsedRatio = 0.8
        await store.save(current)
        lease.cancel()
        await store.save(old)
        let retained = await store.load()
        XCTAssertEqual(retained?.fiveHourUsedRatio, 0.8)
    }

    private static var row: ClaudeCloudRawSession {
        .init(id: "cloud-A", title: "Synthetic", status: "active", statusBucket: "working", workerStatus: "running", connectionStatus: nil, environmentKind: "anthropic_cloud", lastEventAt: Date(), unread: nil)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ path: String) { lock.lock(); defer { lock.unlock() }; values.append(path) }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
private final class CredentialURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Data)?
    static func setHandler(_ value: ((URLRequest) -> Data)?) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let data = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
