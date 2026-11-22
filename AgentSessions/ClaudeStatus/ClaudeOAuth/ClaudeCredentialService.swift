import Foundation
import CryptoKit

/// Owns NotificationCenter tokens without requiring an actor hop during destruction.
final class CredentialNotificationObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    func insert(_ token: NSObjectProtocol) {
        lock.lock(); tokens.append(token); lock.unlock()
    }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// Only this queue touches the manual-cookie Keychain item in production. A cancelled
/// waiter can leave immediately; the physical operation keeps its serial queue slot.
final class ClaudeCredentialService: @unchecked Sendable {
    static let shared = ClaudeCredentialService(store: ClaudeManualWebCookieStore.shared.secretStore)
    static let didChange = Notification.Name("ClaudeManualCredentialDidChange")
    static let legacyDidChange = Notification.Name("ClaudeLegacyCredentialDidChange")

    struct Credential: Sendable {
        let value: String?
        let owner: String
    }

    enum Failure: Error, Equatable {
        case invalidPaste
        case superseded
    }

    private struct Flight {
        let id: UUID
        var waiters: [Waiter<Credential>]
    }

    private let queue = DispatchQueue(label: "com.triada.AgentSessions.manual-credential", qos: .userInitiated)
    private let lock = NSLock()
    private let store: ClaudeSecretStore
    private let instance = UUID().uuidString
    private var epoch = UUID().uuidString
    private var flights: [String: Flight] = [:]
    private var pendingMutations = 0
    private var legacyFingerprint: String?
    private var legacyOwner: String?

    init(store: ClaudeSecretStore) { self.store = store }

    var currentOwner: String {
        lock.lock(); defer { lock.unlock() }
        return ownerLocked
    }

    var isMutating: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingMutations > 0
    }

#if DEBUG
    var pendingReadWaiterCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return flights.values.reduce(0) { $0 + $1.waiters.count }
    }
#endif

    func isCurrent(_ owner: String) -> Bool { currentOwner == owner }
    func isCurrentWebOwner(_ owner: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return owner == ownerLocked || owner == legacyOwner
    }

    func registerLegacyCredential(_ value: String, after manualOwner: String) throws -> String {
        let fingerprint = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        guard manualOwner == ownerLocked else { lock.unlock(); throw Failure.superseded }
        if legacyFingerprint == fingerprint, let legacyOwner { lock.unlock(); return legacyOwner }
        legacyFingerprint = fingerprint
        let owner = "legacy:" + UUID().uuidString
        legacyOwner = owner
        lock.unlock()
        NotificationCenter.default.post(name: Self.legacyDidChange, object: self)
        return owner
    }
    private var ownerLocked: String { "web:\(instance):\(epoch)" }

    func read() async throws -> Credential {
        let metrics = SearchResponsivenessMetrics.shared
        let waiter = Waiter<Credential>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                if Task.isCancelled { waiter.finish(.failure(CancellationError())); return }
                lock.lock()
                let owner = ownerLocked
                let metricContext = SearchResponsivenessMetricContext.credentialOwner(owner)
                let operationID = metrics.newOperationID()
                let waitSpan = metrics.beginSpan(
                    .credentialServiceWait,
                    operationID: operationID,
                    context: metricContext)
                waiter.attachMetricSpan(metrics, waitSpan)
                if var flight = flights[owner] {
                    flight.waiters.append(waiter)
                    flights[owner] = flight
                    metrics.record(
                        .credentialServiceWait,
                        operationID: operationID,
                        context: metricContext,
                        status: .accepted,
                        counters: [.coalescedWaiters: Int64(flight.waiters.count - 1)])
                    lock.unlock()
                    return
                }
                let id = UUID()
                flights[owner] = Flight(id: id, waiters: [waiter])
                metrics.record(
                    .credentialServiceWait,
                    operationID: operationID,
                    context: metricContext,
                    status: .accepted,
                    counters: [.coalescedWaiters: 0])
                // Submission is inside the lock: reads accepted after a mutation must be
                // queued after its physical write, even when callers use different actors.
                queue.async { [self] in
                    let result = Result {
                        try metrics.measured(.credentialPhysicalRead, operationID: operationID, context: metricContext) {
                            Credential(value: try store.readSecret(), owner: owner)
                        }
                    }
                    finishRead(owner: owner, id: id, result: result)
                }
                lock.unlock()
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    func save(pasted: String) async throws {
        guard let value = ClaudeManualWebCookie.extractSessionKey(fromPasted: pasted) else {
            throw Failure.invalidPaste
        }
        try await mutate(value)
    }

    func remove() async throws { try await mutate(nil) }

    private func mutate(_ value: String?) async throws {
        try Task.checkCancellation()
        // Once accepted, a write completes even if its UI task goes away. Returning before
        // physical completion would falsely claim that Save/Remove had finished.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            epoch = UUID().uuidString
            legacyFingerprint = nil
            legacyOwner = nil
            let owner = ownerLocked
            let metrics = SearchResponsivenessMetrics.shared
            let metricContext = SearchResponsivenessMetricContext.credentialOwner(owner)
            let operationID = metrics.operation(source: "manual-credential", sessionID: owner, start: true)
            pendingMutations += 1
            metrics.record(
                .credentialMutationAccepted,
                operationID: operationID,
                context: metricContext,
                status: .accepted)
            queue.async { [self] in
                let result: Result<Void, Error> = Result {
                    if let value {
                        try metrics.measured(.credentialPhysicalWrite, operationID: operationID, context: metricContext) {
                            try store.writeSecret(value)
                        }
                    } else {
                        try metrics.measured(.credentialPhysicalDelete, operationID: operationID, context: metricContext) {
                            try store.deleteSecret()
                        }
                    }
                }
                lock.lock()
                pendingMutations -= 1
                let current = owner == ownerLocked
                lock.unlock()
                let completionStatus: SearchResponsivenessStatus
                if !current {
                    completionStatus = .rejected
                } else if case .success = result {
                    completionStatus = .succeeded
                } else {
                    completionStatus = .failed
                }
                metrics.record(
                    .credentialMutationCompleted,
                    operationID: operationID,
                    context: metricContext,
                    status: completionStatus)
                NotificationCenter.default.post(name: Self.didChange, object: self)
                continuation.resume(with: current ? result : .failure(Failure.superseded))
            }
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private func finishRead(owner: String, id: UUID, result: Result<Credential, Error>) {
        lock.lock()
        guard let flight = flights[owner], flight.id == id else { lock.unlock(); return }
        flights.removeValue(forKey: owner)
        let current = owner == ownerLocked
        lock.unlock()
        for waiter in flight.waiters {
            waiter.finish(current ? result : .failure(Failure.superseded))
        }
    }

    /// Handles cancellation before continuation installation as well as completion races.
    private final class Waiter<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        private var finished = false
        private var metrics: SearchResponsivenessMetrics?
        private var metricSpan: SearchResponsivenessSpan?

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let result {
                self.result = nil
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let metrics = self.metrics
            let metricSpan = self.metricSpan
            self.metrics = nil
            self.metricSpan = nil
            if continuation == nil { self.result = result }
            lock.unlock()
            if let metrics, let metricSpan {
                switch result {
                case .success:
                    metrics.end(metricSpan)
                case .failure(let error as CancellationError):
                    _ = error
                    metrics.cancel(metricSpan)
                case .failure(let error as ClaudeCredentialService.Failure) where error == .superseded:
                    metrics.fail(metricSpan, code: .superseded)
                case .failure:
                    metrics.fail(metricSpan, code: .unknown)
                }
            }
            continuation?.resume(with: result)
        }

        func attachMetricSpan(_ metrics: SearchResponsivenessMetrics, _ span: SearchResponsivenessSpan?) {
            guard let span else { return }
            lock.lock()
            guard !finished else {
                lock.unlock()
                metrics.cancel(span)
                return
            }
            self.metrics = metrics
            metricSpan = span
            lock.unlock()
        }
    }
}

extension SearchResponsivenessMetricContext {
    static func credentialOwner(_ owner: String) -> Self {
        guard SearchResponsivenessMetrics.shared.isEnabled else { return .none }
        return .init(contentRevision: .init(owner))
    }
}

/// Validity follows an operation through every network suspension, not just UI publication.
final class ClaudeCredentialRequestLease: @unchecked Sendable, Equatable {
    static func == (lhs: ClaudeCredentialRequestLease, rhs: ClaudeCredentialRequestLease) -> Bool { lhs === rhs }
    var isValid: Bool { (try? check()) != nil }
    private let lock = NSLock()
    private var cancelled = false
    let owner: String
    private let credentials: ClaudeCredentialService
    private let isEnabled: @Sendable () -> Bool

    init(owner: String, credentials: ClaudeCredentialService = .shared,
         isEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.owner = owner
        self.credentials = credentials
        self.isEnabled = isEnabled
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let cancelled = self.cancelled; lock.unlock()
        guard !cancelled, !Task.isCancelled, isEnabled(), credentials.isCurrentWebOwner(owner) else {
            throw CancellationError()
        }
    }
}
