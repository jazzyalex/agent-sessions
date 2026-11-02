import Combine
import XCTest
@testable import AgentSessions

/// Diagnostics for the intermittent CI segv in `SessionIndexer.deinit`, where
/// `PublishedSubject.disassociate` finds a freed subject. These tests skip unless
/// `.github/workflows/segv-diagnostics.yml` (or a local run) sets their environment
/// variables, so the normal suite never runs them.
final class SessionIndexerLifecycleStressTests: XCTestCase {
    private static let rolloutName = "rollout-2025-12-17T15-27-49-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl"

    private var root: URL!

    override class func setUp() {
        super.setUp()
        SegvDiagnostics.installIfRequested()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionIndexerStress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func iterationCount() throws -> Int {
        guard let raw = ProcessInfo.processInfo.environment["STRESS_N"], let count = Int(raw), count > 0 else {
            throw XCTSkip("Set STRESS_N to run the SessionIndexer lifecycle stress tests")
        }
        return count
    }

    private func makeRollout(instructionsBytes: Int) throws -> URL {
        let url = root.appendingPathComponent(Self.rolloutName)
        let instructions = String(repeating: "A", count: instructionsBytes)
        let line = #"{"timestamp":"2025-12-17T23:27:49.405Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","cwd":"/tmp","instructions":"\#(instructions)"}}"#
        try Data((line + "\n").utf8).write(to: url)
        return url
    }

    /// Same shape as run 41146074451: a throwaway indexer per parse on a cooperative
    /// thread while the main thread spins. Matches `CodexSourceDescriptor.parseFullByPath`.
    func testIndexerLifecycleOnCooperativeThreads() async throws {
        let count = try iterationCount()
        let url = try makeRollout(instructionsBytes: 16)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask(priority: .utility) {
                    for _ in 0..<count {
                        autoreleasepool { _ = SessionIndexer().parseFileFull(at: url) }
                    }
                }
            }
        }
    }

    /// Same shape as run 40589763947: the main thread creates and releases indexers in a
    /// synchronous loop, so main-queue deliveries pile up until the run loop next spins.
    func testIndexerLifecycleOnMainThreadWithDetachedTasks() throws {
        let count = try iterationCount()
        let url = try makeRollout(instructionsBytes: 20_000)
        let group = DispatchGroup()
        for _ in 0..<3 {
            group.enter()
            Task.detached(priority: .utility) {
                for _ in 0..<count {
                    autoreleasepool { _ = SessionIndexer().parseFileFull(at: url) }
                }
                group.leave()
            }
        }
        for iteration in 0..<count {
            autoreleasepool { _ = SessionIndexer().parseFileFull(at: url) }
            if iteration % 500 == 0 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        while group.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Proves the instrument: over-releases a subject on purpose, then cancels through the
    /// same Sink -> FilterProducer -> Conduit chain as the CI crash. This test must crash.
    /// A diagnostics job that survives it cannot report the real over-release either.
    func testPositiveControlOverReleasedPublishedSubject() throws {
        guard ProcessInfo.processInfo.environment["STRESS_POSITIVE_CONTROL"] == "1" else {
            throw XCTSkip("Set STRESS_POSITIVE_CONTROL=1 to crash on purpose")
        }
        var model: PositiveControlModel? = PositiveControlModel()
        model?.overReleaseSubject()
        model = nil
        XCTFail("The over-released subject did not crash")
    }
}

/// Sorts first, so full-suite diagnostic runs install the crash handler before any
/// `SessionIndexer` test. XCTest runs `setUp` only for classes that have a test.
final class AAASegvDiagnosticsInstaller: XCTestCase {
    func testInstallCrashHandler() throws {
        guard SegvDiagnostics.isRequested else {
            throw XCTSkip("Set SEGV_DIAGNOSTICS=1 to install the crash handler")
        }
        SegvDiagnostics.installIfRequested()
    }
}

/// ASan cannot see Combine's reads of the freed subject, because Combine is not
/// instrumented, so it never prints a use-after-free report for this crash. This handler
/// asks ASan directly. In `disassociate`, x20 is the subject and x19 is the conduit, so
/// their descriptions hold the stack that freed the subject and the stack that allocated
/// each one. It needs ASAN_OPTIONS with handle_segv=0, and with free_fill_byte=0 so that a
/// freed subject faults on its null lock as it does on macOS 26.
enum SegvDiagnostics {
    typealias DescribeAddress = @convention(c) (UnsafeMutableRawPointer) -> Void

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["SEGV_DIAGNOSTICS"] == "1"
    }

    static func installIfRequested() {
        guard isRequested, segvDescribeAddress == nil else { return }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__asan_describe_address") else {
            fputs("SEGV-DIAGNOSTICS: __asan_describe_address is missing\n", stderr)
            return
        }
        segvDescribeAddress = unsafeBitCast(symbol, to: DescribeAddress.self)
        var action = sigaction()
        action.__sigaction_u = __sigaction_u(__sa_sigaction: segvHandler)
        action.sa_flags = SA_SIGINFO
        sigemptyset(&action.sa_mask)
        sigaction(SIGSEGV, &action, nil)
        sigaction(SIGBUS, &action, nil)
        fputs("SEGV-DIAGNOSTICS: crash handler installed\n", stderr)
    }
}

nonisolated(unsafe) private var segvDescribeAddress: SegvDiagnostics.DescribeAddress?

private func segvHandler(_ signalNumber: Int32,
                         _ info: UnsafeMutablePointer<__siginfo>?,
                         _ context: UnsafeMutableRawPointer?) {
    // Returning re-runs the faulting instruction, which then crashes with the default action.
    signal(signalNumber, SIG_DFL)
    guard let context, let describe = segvDescribeAddress else { return }
    let state = context.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext.pointee.__ss
    fputs("SEGV-DIAGNOSTICS: x20 (PublishedSubject)\n", stderr)
    if let subject = UnsafeMutableRawPointer(bitPattern: UInt(state.__x.20)) { describe(subject) }
    fputs("SEGV-DIAGNOSTICS: x19 (Conduit)\n", stderr)
    if let conduit = UnsafeMutableRawPointer(bitPattern: UInt(state.__x.19)) { describe(conduit) }
}

private final class PositiveControlModel {
    @Published var value = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        $value
            .map { $0 + 1 }
            .removeDuplicates()
            .sink { _ in }
            .store(in: &cancellables)
    }

    func overReleaseSubject() {
        let publisher = $value
        guard let subject = Mirror(reflecting: publisher).children.first?.value as AnyObject? else { return }
        Unmanaged.passUnretained(subject).release()
    }
}
