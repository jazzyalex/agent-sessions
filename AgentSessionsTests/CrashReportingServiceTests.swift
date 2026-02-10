import XCTest
@testable import AgentSessions

final class CrashReportingServiceTests: XCTestCase {
    func testDetectOnLaunchQueuesLocalCrashes() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("Agent Sessions_2026-02-10-120000.crash")
        try makeCrashReportFile(at: reportURL)

        let storeURL = tempRoot.appendingPathComponent("pending.json")
        let store = CrashReportStore(fileManager: .default, pendingFileURL: storeURL, maxPendingCount: 1)
        let detector = CrashReportDetector(
            fileManager: .default,
            reportsRootURL: tempRoot,
            appName: "Agent Sessions",
            bundleIdentifier: "com.triada.AgentSessions",
            appVersion: "2.11.2",
            appBuild: "21",
            nowProvider: Date.init,
            lookbackWindow: 60 * 60 * 24 * 30,
            maxReports: 10
        )

        let defaults = testDefaults("CrashReportingServiceTests.detect")

        let service = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let detectedCount = await service.detectAndQueueOnLaunch()

        XCTAssertEqual(detectedCount, 1)
        let pending = await store.pending()
        XCTAssertEqual(pending.count, 1)
    }

    func testDetectOnLaunchFindsAgentCrashAmidManyNewerNonAgentReports() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for index in 0..<80 {
            let nonAgentURL = tempRoot.appendingPathComponent("OtherApp_\(index).crash")
            try makeNonAgentCrashReportFile(at: nonAgentURL)
            try setModificationDate(now.addingTimeInterval(TimeInterval(-index)), for: nonAgentURL)
        }

        let agentURL = tempRoot.appendingPathComponent("Agent Sessions_2026-02-10-113000.crash")
        try makeCrashReportFile(at: agentURL)
        try setModificationDate(now.addingTimeInterval(-5_000), for: agentURL)

        let storeURL = tempRoot.appendingPathComponent("pending.json")
        let store = CrashReportStore(fileManager: .default, pendingFileURL: storeURL, maxPendingCount: 1)
        let detector = CrashReportDetector(
            fileManager: .default,
            reportsRootURL: tempRoot,
            appName: "Agent Sessions",
            bundleIdentifier: "com.triada.AgentSessions",
            appVersion: "2.11.2",
            appBuild: "21",
            nowProvider: { now },
            lookbackWindow: 60 * 60 * 24 * 30,
            maxReports: 10
        )

        let defaults = testDefaults("CrashReportingServiceTests.noisyDirectory")
        let service = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: { now }
        )

        let detectedCount = await service.detectAndQueueOnLaunch()
        XCTAssertEqual(detectedCount, 1)
        let pendingCount = await store.pendingCount()
        XCTAssertEqual(pendingCount, 1)
    }

    func testDetectOnLaunchDoesNotRequeuePreviouslySeenCrashIDsAfterClear() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportAURL = tempRoot.appendingPathComponent("Agent Sessions_2026-02-10-120000.crash")
        let reportBURL = tempRoot.appendingPathComponent("Agent Sessions_2026-02-10-120500.crash")
        try makeCrashReportFile(at: reportAURL)
        try makeCrashReportFile(at: reportBURL)

        let storeURL = tempRoot.appendingPathComponent("pending.json")
        let store = CrashReportStore(fileManager: .default, pendingFileURL: storeURL, maxPendingCount: 1)
        let detector = CrashReportDetector(
            fileManager: .default,
            reportsRootURL: tempRoot,
            appName: "Agent Sessions",
            bundleIdentifier: "com.triada.AgentSessions",
            appVersion: "2.11.2",
            appBuild: "21",
            nowProvider: Date.init,
            lookbackWindow: 60 * 60 * 24 * 30,
            maxReports: 10
        )

        let defaults = testDefaults("CrashReportingServiceTests.seenIDs")
        let firstLaunchService = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let firstDetectedCount = await firstLaunchService.detectAndQueueOnLaunch()
        XCTAssertEqual(firstDetectedCount, 1)

        await firstLaunchService.clearPendingReports()
        let pendingAfterClear = await store.pendingCount()
        XCTAssertEqual(pendingAfterClear, 0)

        let secondLaunchService = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let secondDetectedCount = await secondLaunchService.detectAndQueueOnLaunch()
        XCTAssertEqual(secondDetectedCount, 1)
        let pendingAfterSecondLaunch = await store.pendingCount()
        XCTAssertEqual(pendingAfterSecondLaunch, 1)

        await secondLaunchService.clearPendingReports()

        let thirdLaunchService = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let thirdDetectedCount = await thirdLaunchService.detectAndQueueOnLaunch()
        XCTAssertEqual(thirdDetectedCount, 0)
        let pendingAfterThirdLaunch = await store.pendingCount()
        XCTAssertEqual(pendingAfterThirdLaunch, 0)

        let seenCrashIDs = defaults.stringArray(forKey: PreferencesKey.Diagnostics.seenCrashIDs) ?? []
        XCTAssertEqual(seenCrashIDs.count, 2)
    }

    func testDetectOnLaunchRetainsNewlySeenIDWhenHistoryIsAtCapacity() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("Agent Sessions_2026-02-10-123000.crash")
        try makeCrashReportFile(at: reportURL)

        let storeURL = tempRoot.appendingPathComponent("pending.json")
        let store = CrashReportStore(fileManager: .default, pendingFileURL: storeURL, maxPendingCount: 1)
        let detector = CrashReportDetector(
            fileManager: .default,
            reportsRootURL: tempRoot,
            appName: "Agent Sessions",
            bundleIdentifier: "com.triada.AgentSessions",
            appVersion: "2.11.2",
            appBuild: "21",
            nowProvider: Date.init,
            lookbackWindow: 60 * 60 * 24 * 30,
            maxReports: 10
        )

        let defaults = testDefaults("CrashReportingServiceTests.historyCap")
        let seededHistory = (1...200).map { "z-seen-\($0)" }
        defaults.set(seededHistory, forKey: PreferencesKey.Diagnostics.seenCrashIDs)
        defaults.set(seededHistory.first, forKey: PreferencesKey.Diagnostics.lastSeenCrashID)

        let firstLaunchService = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let firstDetectedCount = await firstLaunchService.detectAndQueueOnLaunch()
        XCTAssertEqual(firstDetectedCount, 1)

        let firstPending = await store.pending()
        let newSeenID = try XCTUnwrap(firstPending.first?.id)

        let seenAfterFirstDetect = defaults.stringArray(forKey: PreferencesKey.Diagnostics.seenCrashIDs) ?? []
        XCTAssertEqual(seenAfterFirstDetect.count, 200)
        XCTAssertTrue(seenAfterFirstDetect.contains(newSeenID))
        let retainedSeedCount = seenAfterFirstDetect.filter { $0.hasPrefix("z-seen-") }.count
        XCTAssertEqual(retainedSeedCount, 199)

        await firstLaunchService.clearPendingReports()

        let secondLaunchService = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let secondDetectedCount = await secondLaunchService.detectAndQueueOnLaunch()
        XCTAssertEqual(secondDetectedCount, 0)
    }

    func testSupportEmailDraftContainsCrashReportJSON() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let storeURL = tempRoot.appendingPathComponent("pending.json")
        let store = CrashReportStore(fileManager: .default, pendingFileURL: storeURL, maxPendingCount: 1)
        await store.enqueue(makeEnvelope(id: "email-1"))

        let defaults = testDefaults("CrashReportingServiceTests.emailDraft")
        let service = CrashReportingService(
            store: store,
            detector: CrashReportDetector(reportsRootURL: tempRoot),
            userDefaults: defaults,
            nowProvider: { Date(timeIntervalSince1970: 2_000_000_200) }
        )

        let maybeURL = await service.supportEmailDraftURL(recipient: "jazzyalex@gmail.com")
        XCTAssertNotNil(maybeURL)

        guard let url = maybeURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            XCTFail("Expected mailto URL")
            return
        }

        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, "jazzyalex@gmail.com")

        let queryMap = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let subject = queryMap["subject"] ?? ""
        let body = queryMap["body"] ?? ""

        XCTAssertTrue(subject.contains("Agent Sessions Crash Report"))
        XCTAssertTrue(body.contains("Crash Report JSON"))
        XCTAssertTrue(body.contains("\"id\" : \"email-1\""))
    }

    func testSupportEmailDraftWithoutPendingReportsHasTemplateBody() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let storeURL = tempRoot.appendingPathComponent("pending.json")
        let store = CrashReportStore(fileManager: .default, pendingFileURL: storeURL, maxPendingCount: 1)

        let defaults = testDefaults("CrashReportingServiceTests.emptyDraft")
        let service = CrashReportingService(
            store: store,
            detector: CrashReportDetector(reportsRootURL: tempRoot),
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let maybeURL = await service.supportEmailDraftURL(recipient: "jazzyalex@gmail.com")
        XCTAssertNotNil(maybeURL)

        guard let url = maybeURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            XCTFail("Expected mailto URL")
            return
        }

        let queryMap = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let body = queryMap["body"] ?? ""
        XCTAssertTrue(body.contains("No pending crash report was available"))
    }

    private func makeTempDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func testDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeCrashReportFile(at url: URL) throws {
        let text = """
        Process:               Agent Sessions [100]
        Identifier:            com.triada.AgentSessions
        Version:               2.11.2 (21)
        Date/Time:             2026-02-10 12:00:00.000 +0000
        Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
        Exception Codes:       KERN_INVALID_ADDRESS at 0x0000000000000000
        Termination Reason:    SIGNAL 11 Segmentation fault: 11

        Thread 0 Crashed:
        0   libswiftCore.dylib           0x0000000100000000 swift_unknownObjectRelease + 16
        1   Agent Sessions               0x0000000100001111 closure #1 in App.start + 88
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeNonAgentCrashReportFile(at url: URL) throws {
        let text = """
        Process:               Other App [200]
        Identifier:            com.example.OtherApp
        Version:               1.0 (1)
        Date/Time:             2026-02-10 12:00:00.000 +0000
        Exception Type:        EXC_BREAKPOINT (SIGTRAP)
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeEnvelope(id: String) -> CrashReportEnvelope {
        CrashReportEnvelope(
            id: id,
            detectedAt: Date(timeIntervalSince1970: 2_000_000_000),
            reportSourcePathHash: "hash-\(id)",
            reportFilename: "\(id).crash",
            crashTimestamp: Date(timeIntervalSince1970: 2_000_000_000),
            appVersion: "2.11.2",
            appBuild: "21",
            macOSVersion: "macOS 14",
            architecture: "arm64",
            terminationSummary: "EXC_BAD_ACCESS",
            topFrames: ["0 libswiftCore.dylib swift_unknownObjectRelease"],
            breadcrumbs: ["launch.diagnostics_scan"],
            rawMetadata: ["format": "crash"]
        )
    }
}
