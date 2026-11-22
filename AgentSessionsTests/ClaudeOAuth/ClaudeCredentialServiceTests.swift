import Foundation
import XCTest
@testable import AgentSessions

final class ClaudeCredentialServiceTests: XCTestCase {

    @MainActor
    func testBlockedSecretReadAllowsMainActorProgress() async throws {
        let gate = FakeWorkerGate()
        let store = FakeClaudeSecretStore(value: "credential-A")
        store.blockNextRead(on: gate)
        let service = ClaudeCredentialService(store: store)
        defer { gate.open() }

        let readTask = Task { try await service.read() }
        let readEntered = await waitForSignal(gate.entered, timeoutMilliseconds: 2_000)
        XCTAssertTrue(readEntered, "The fake store read should start on the service worker.")

        let mainActorProgress = DispatchSemaphore(value: 0)
        let progressTask = Task { @MainActor in mainActorProgress.signal() }
        let progressed = await waitForSignal(mainActorProgress, timeoutMilliseconds: 1_000)

        gate.open()
        await progressTask.value
        let credential = try await readTask.value

        XCTAssertTrue(progressed, "MainActor work should run while the physical read is blocked.")
        XCTAssertEqual(credential.value, "credential-A")
    }

    @MainActor
    func testOverlappingReadsCoalesceToOnePhysicalRead() async throws {
        let gate = FakeWorkerGate()
        let store = FakeClaudeSecretStore(value: "credential-A")
        store.blockNextRead(on: gate)
        let service = ClaudeCredentialService(store: store)
        defer { gate.open() }

        let first = Task { try await service.read() }
        let readEntered = await waitForSignal(gate.entered, timeoutMilliseconds: 2_000)
        XCTAssertTrue(readEntered)

        let secondStarted = expectation(description: "second read task started")
        let second = Task { @MainActor in
            secondStarted.fulfill()
            return try await service.read()
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        let bothWaitersRegistered = await waitUntil(timeoutMilliseconds: 2_000) {
            service.pendingReadWaiterCountForTesting == 2
        }
        XCTAssertTrue(bothWaitersRegistered)

        gate.open()
        let firstCredential = try await first.value
        let secondCredential = try await second.value
        let counts = store.snapshot

        XCTAssertEqual(counts.reads, 1)
        XCTAssertEqual(firstCredential.value, "credential-A")
        XCTAssertEqual(secondCredential.value, "credential-A")
        XCTAssertEqual(firstCredential.owner, secondCredential.owner)
    }

    @MainActor
    func testCancellingOneCoalescedWaiterLeavesTheOtherActive() async throws {
        let gate = FakeWorkerGate()
        let store = FakeClaudeSecretStore(value: "credential-A")
        store.blockNextRead(on: gate)
        let service = ClaudeCredentialService(store: store)
        defer { gate.open() }

        let cancelledWaiter = Task { try await service.read() }
        let readEntered = await waitForSignal(gate.entered, timeoutMilliseconds: 2_000)
        XCTAssertTrue(readEntered)

        let retainedWaiterStarted = expectation(description: "retained read task started")
        let retainedWaiter = Task { @MainActor in
            retainedWaiterStarted.fulfill()
            return try await service.read()
        }
        await fulfillment(of: [retainedWaiterStarted], timeout: 2)
        let bothWaitersRegistered = await waitUntil(timeoutMilliseconds: 2_000) {
            service.pendingReadWaiterCountForTesting == 2
        }
        XCTAssertTrue(bothWaitersRegistered)

        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("The cancelled waiter should finish with CancellationError.")
        } catch is CancellationError {
            // A waiter may cancel independently of the physical read.
        }

        XCTAssertFalse(gate.isOpen, "Cancelling one waiter must not release the worker read.")
        gate.open()
        let credential = try await retainedWaiter.value

        XCTAssertEqual(credential.value, "credential-A")
        XCTAssertEqual(store.snapshot.reads, 1)
    }

    @MainActor
    func testSaveDuringBlockedReadSupersedesOldOwnerAndReturnsNewCredential() async throws {
        let gate = FakeWorkerGate()
        let store = FakeClaudeSecretStore(value: "credential-A")
        store.blockNextRead(on: gate)
        let service = ClaudeCredentialService(store: store)
        let oldOwner = service.currentOwner
        defer { gate.open() }

        let oldRead = Task { try await service.read() }
        let readEntered = await waitForSignal(gate.entered, timeoutMilliseconds: 2_000)
        XCTAssertTrue(readEntered)

        let save = Task { try await service.save(pasted: "sessionKey=credential-B") }
        let ownerAdvanced = await waitUntil(timeoutMilliseconds: 2_000) {
            service.currentOwner != oldOwner
        }
        XCTAssertTrue(ownerAdvanced, "Save acceptance should advance ownership before the write runs.")
        XCTAssertTrue(service.isMutating)
        XCTAssertEqual(store.snapshot.writes, 0, "The serial write must wait behind the blocked read.")

        gate.open()
        try await save.value
        do {
            _ = try await oldRead.value
            XCTFail("The read from the previous owner should be superseded.")
        } catch let failure as ClaudeCredentialService.Failure {
            XCTAssertEqual(failure, .superseded)
        }

        let current = try await service.read()
        XCTAssertEqual(current.value, "credential-B")
        XCTAssertEqual(current.owner, service.currentOwner)
        XCTAssertEqual(store.snapshot.writes, 1)
    }

    @MainActor
    func testRemoveDuringBlockedReadSupersedesOldOwnerAndReturnsAbsentCredential() async throws {
        let gate = FakeWorkerGate()
        let store = FakeClaudeSecretStore(value: "credential-A")
        store.blockNextRead(on: gate)
        let service = ClaudeCredentialService(store: store)
        let oldOwner = service.currentOwner
        defer { gate.open() }

        let oldRead = Task { try await service.read() }
        let readEntered = await waitForSignal(gate.entered, timeoutMilliseconds: 2_000)
        XCTAssertTrue(readEntered)

        let remove = Task { try await service.remove() }
        let ownerAdvanced = await waitUntil(timeoutMilliseconds: 2_000) {
            service.currentOwner != oldOwner
        }
        XCTAssertTrue(ownerAdvanced, "Remove acceptance should advance ownership before deletion runs.")
        XCTAssertTrue(service.isMutating)
        XCTAssertEqual(store.snapshot.deletes, 0, "Deletion must wait behind the blocked read.")

        gate.open()
        try await remove.value
        do {
            _ = try await oldRead.value
            XCTFail("The read from the previous owner should be superseded.")
        } catch let failure as ClaudeCredentialService.Failure {
            XCTAssertEqual(failure, .superseded)
        }

        let current = try await service.read()
        XCTAssertNil(current.value)
        XCTAssertEqual(current.owner, service.currentOwner)
        XCTAssertEqual(store.snapshot.deletes, 1)
    }

    @MainActor
    func testInvalidPasteLeavesOwnerAndStorageUnchanged() async {
        let store = FakeClaudeSecretStore(value: "credential-A")
        let service = ClaudeCredentialService(store: store)
        let owner = service.currentOwner

        do {
            try await service.save(pasted: "lastActiveOrg=example; no session key")
            XCTFail("A cookie header without sessionKey should be rejected.")
        } catch let failure as ClaudeCredentialService.Failure {
            XCTAssertEqual(failure, .invalidPaste)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(service.currentOwner, owner)
        XCTAssertFalse(service.isMutating)
        XCTAssertEqual(store.snapshot.writes, 0)
        XCTAssertEqual(store.snapshot.deletes, 0)
        XCTAssertEqual(store.snapshot.value, "credential-A")
    }

    @MainActor
    func testTypedReadErrorIsPropagated() async {
        let store = FakeClaudeSecretStore(value: "credential-A")
        store.setReadError(.securityStatus(-25293))
        let service = ClaudeCredentialService(store: store)

        do {
            _ = try await service.read()
            XCTFail("The typed storage error should not become an absent credential.")
        } catch let error as ClaudeSecretStoreError {
            XCTAssertEqual(error, .securityStatus(-25293))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.snapshot.reads, 1)
    }

    @MainActor
    func testFailedSaveAdvancesOwnerAndNextReadReturnsStoredCredential() async throws {
        let store = FakeClaudeSecretStore(value: "credential-A")
        store.setWriteError(.securityStatus(-50))
        let service = ClaudeCredentialService(store: store)
        let oldOwner = service.currentOwner

        let save = Task { try await service.save(pasted: "sessionKey=credential-B") }
        let ownerAdvanced = await waitUntil(timeoutMilliseconds: 2_000) {
            service.currentOwner != oldOwner
        }
        XCTAssertTrue(ownerAdvanced, "An accepted mutation advances ownership even if storage fails.")

        do {
            try await save.value
            XCTFail("The configured storage failure should be propagated.")
        } catch let error as ClaudeSecretStoreError {
            XCTAssertEqual(error, .securityStatus(-50))
        }

        XCTAssertNotEqual(service.currentOwner, oldOwner)
        XCTAssertFalse(service.isMutating)
        let current = try await service.read()
        XCTAssertEqual(current.value, "credential-A")
        XCTAssertEqual(current.owner, service.currentOwner)
        XCTAssertEqual(store.snapshot.writes, 1)
    }

    @MainActor
    func testRegisteringNewLegacyCredentialInvalidatesPreviousOwner() throws {
        let service = ClaudeCredentialService(store: FakeClaudeSecretStore(value: nil))
        let manualOwner = service.currentOwner

        let legacyOwnerA = try service.registerLegacyCredential("legacy-A", after: manualOwner)
        let legacyOwnerB = try service.registerLegacyCredential("legacy-B", after: manualOwner)

        XCTAssertNotEqual(legacyOwnerA, legacyOwnerB)
        XCTAssertFalse(service.isCurrentWebOwner(legacyOwnerA))
        XCTAssertTrue(service.isCurrentWebOwner(legacyOwnerB))
        XCTAssertTrue(service.isCurrent(manualOwner))
    }

    @MainActor
    func testManualMutationInvalidatesLegacyOwnerAndRejectsObsoleteRegistration() async throws {
        let service = ClaudeCredentialService(store: FakeClaudeSecretStore(value: nil))
        let oldManualOwner = service.currentOwner
        let legacyOwner = try service.registerLegacyCredential("legacy-A", after: oldManualOwner)
        XCTAssertTrue(service.isCurrentWebOwner(legacyOwner))

        try await service.save(pasted: "sessionKey=manual-B")

        let newManualOwner = service.currentOwner
        XCTAssertNotEqual(newManualOwner, oldManualOwner)
        XCTAssertFalse(service.isCurrentWebOwner(legacyOwner))
        do {
            _ = try service.registerLegacyCredential("legacy-B", after: oldManualOwner)
            XCTFail("Registration against an obsolete manual owner should be superseded.")
        } catch let failure as ClaudeCredentialService.Failure {
            XCTAssertEqual(failure, .superseded)
        }
    }

    @MainActor
    func testRequestLeaseRejectsCancellation() {
        let service = ClaudeCredentialService(store: FakeClaudeSecretStore(value: nil))
        let lease = ClaudeCredentialRequestLease(owner: service.currentOwner, credentials: service)

        XCTAssertNoThrow(try lease.check())
        lease.cancel()
        XCTAssertThrowsError(try lease.check()) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testRequestLeaseRejectsManualOwnerMutation() async throws {
        let service = ClaudeCredentialService(store: FakeClaudeSecretStore(value: nil))
        let lease = ClaudeCredentialRequestLease(owner: service.currentOwner, credentials: service)

        try await service.save(pasted: "sessionKey=manual-B")

        XCTAssertThrowsError(try lease.check()) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore,
                               timeoutMilliseconds: Int) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            semaphore.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .success
        }.value
    }

    private func waitUntil(timeoutMilliseconds: Int,
                           condition: () -> Bool) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }
}

private final class FakeWorkerGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func blockWorker(timeoutSeconds: Int = 5) -> Bool {
        entered.signal()
        return releaseSemaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success
    }

    func open() {
        lock.lock()
        let shouldSignal = !opened
        opened = true
        lock.unlock()
        if shouldSignal { releaseSemaphore.signal() }
    }
}

private final class FakeClaudeSecretStore: ClaudeSecretStore, @unchecked Sendable {
    struct Snapshot {
        let value: String?
        let reads: Int
        let writes: Int
        let deletes: Int
    }

    private let lock = NSLock()
    private var value: String?
    private var nextReadGate: FakeWorkerGate?
    private var readError: ClaudeSecretStoreError?
    private var writeError: ClaudeSecretStoreError?
    private var readCount = 0
    private var writeCount = 0
    private var deleteCount = 0

    init(value: String?) { self.value = value }

    var snapshot: Snapshot {
        synchronized {
            Snapshot(value: value, reads: readCount, writes: writeCount, deletes: deleteCount)
        }
    }

    func blockNextRead(on gate: FakeWorkerGate) {
        synchronized { nextReadGate = gate }
    }

    func setReadError(_ error: ClaudeSecretStoreError?) {
        synchronized { readError = error }
    }

    func setWriteError(_ error: ClaudeSecretStoreError?) {
        synchronized { writeError = error }
    }

    func read() -> String? { try? readSecret() }

    func readSecret() throws -> String? {
        let captured = synchronized { () -> (String?, FakeWorkerGate?, ClaudeSecretStoreError?) in
            readCount += 1
            let gate = nextReadGate
            nextReadGate = nil
            return (value, gate, readError)
        }
        if let gate = captured.1, !gate.blockWorker() {
            throw FakeSecretStoreError.workerTimedOut
        }
        if let error = captured.2 { throw error }
        return captured.0
    }

    func write(_ value: String) -> Bool {
        do {
            try writeSecret(value)
            return true
        } catch {
            return false
        }
    }

    func writeSecret(_ newValue: String) throws {
        let error = synchronized { () -> ClaudeSecretStoreError? in
            writeCount += 1
            if let writeError { return writeError }
            value = newValue
            return nil
        }
        if let error { throw error }
    }

    func delete() { try? deleteSecret() }

    func deleteSecret() throws {
        synchronized {
            deleteCount += 1
            value = nil
        }
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private enum FakeSecretStoreError: Error {
    case workerTimedOut
}
