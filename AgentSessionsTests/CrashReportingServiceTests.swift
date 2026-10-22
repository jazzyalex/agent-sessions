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

    func testDetectOnLaunchMarksSeenOnlyAfterPendingIsCleared() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("Agent Sessions_2026-02-10-121000.crash")
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

        let defaults = testDefaults("CrashReportingServiceTests.markSeenOnClear")
        let service = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let detectedCount = await service.detectAndQueueOnLaunch()
        XCTAssertEqual(detectedCount, 1)

        let seenBeforeClear = defaults.stringArray(forKey: PreferencesKey.Diagnostics.seenCrashIDs) ?? []
        XCTAssertTrue(seenBeforeClear.isEmpty)

        let pendingBeforeClear = await store.pending()
        let pendingID = try XCTUnwrap(pendingBeforeClear.first?.id)

        await service.clearPendingReports()

        let seenAfterClear = defaults.stringArray(forKey: PreferencesKey.Diagnostics.seenCrashIDs) ?? []
        XCTAssertEqual(seenAfterClear.count, 1)
        XCTAssertTrue(seenAfterClear.contains(pendingID))
    }

    func testLaterSuppressesTheSameCrashOnNextLaunchWhileRetainingTheReport() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("Agent Sessions_2026-02-10-121500.crash")
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

        let defaults = testDefaults("CrashReportingServiceTests.defer")
        let firstLaunchService = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let firstDetectedCount = await firstLaunchService.detectAndQueueOnLaunch()
        XCTAssertEqual(firstDetectedCount, 1)
        let pendingAfterFirstLaunch = await store.pending()
        let pendingID = try XCTUnwrap(pendingAfterFirstLaunch.first?.id)

        await firstLaunchService.deferPendingReports()

        let dismissedIDs = defaults.stringArray(forKey: PreferencesKey.Diagnostics.dismissedCrashIDs) ?? []
        XCTAssertEqual(dismissedIDs, [pendingID])
        let pendingCountAfterDefer = await store.pendingCount()
        XCTAssertEqual(pendingCountAfterDefer, 1)

        let secondLaunchService = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let secondDetectedCount = await secondLaunchService.detectAndQueueOnLaunch()
        XCTAssertEqual(secondDetectedCount, 0)
        let pendingCountAfterSecondLaunch = await store.pendingCount()
        XCTAssertEqual(pendingCountAfterSecondLaunch, 1)
    }

    func testClearPendingReportsMarksAllPendingIDsAsSeen() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let storeURL = tempRoot.appendingPathComponent("pending.json")
        let store = CrashReportStore(fileManager: .default, pendingFileURL: storeURL, maxPendingCount: 5)
        await store.enqueue(contentsOf: [
            makeEnvelope(id: "clear-1"),
            makeEnvelope(id: "clear-2"),
            makeEnvelope(id: "clear-3")
        ])

        let defaults = testDefaults("CrashReportingServiceTests.clearAllSeen")
        let service = CrashReportingService(
            store: store,
            detector: CrashReportDetector(reportsRootURL: tempRoot),
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let pendingBeforeClear = await store.pending()
        let pendingIDs = Set(pendingBeforeClear.map(\.id))
        XCTAssertEqual(pendingIDs.count, 3)

        await service.clearPendingReports()

        let seenAfterClear = defaults.stringArray(forKey: PreferencesKey.Diagnostics.seenCrashIDs) ?? []
        XCTAssertEqual(Set(seenAfterClear), pendingIDs)
        XCTAssertEqual(seenAfterClear.count, pendingIDs.count)

        let pendingAfterClear = await store.pendingCount()
        XCTAssertEqual(pendingAfterClear, 0)
    }

    func testClearPendingReportsDoesNotMarkSeenWhenStoreClearFails() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let failingPendingURL = tempRoot.appendingPathComponent("pending.json", isDirectory: true)
        try FileManager.default.createDirectory(at: failingPendingURL, withIntermediateDirectories: true)

        let store = CrashReportStore(fileManager: .default, pendingFileURL: failingPendingURL, maxPendingCount: 5)
        await store.enqueue(contentsOf: [
            makeEnvelope(id: "clear-fail-1"),
            makeEnvelope(id: "clear-fail-2")
        ])

        let defaults = testDefaults("CrashReportingServiceTests.clearFailSeen")
        let service = CrashReportingService(
            store: store,
            detector: CrashReportDetector(reportsRootURL: tempRoot),
            userDefaults: defaults,
            nowProvider: Date.init
        )

        await service.clearPendingReports()

        let seenAfterClearAttempt = defaults.stringArray(forKey: PreferencesKey.Diagnostics.seenCrashIDs) ?? []
        XCTAssertTrue(seenAfterClearAttempt.isEmpty)

        let pendingAfterClearAttempt = await store.pendingCount()
        XCTAssertEqual(pendingAfterClearAttempt, 2)
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

    func testClearPendingReportsRetainsNewlySeenIDWhenHistoryIsAtCapacity() async throws {
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
        XCTAssertFalse(seenAfterFirstDetect.contains(newSeenID))
        let retainedSeedCount = seenAfterFirstDetect.filter { $0.hasPrefix("z-seen-") }.count
        XCTAssertEqual(retainedSeedCount, 200)

        await firstLaunchService.clearPendingReports()

        let seenAfterClear = defaults.stringArray(forKey: PreferencesKey.Diagnostics.seenCrashIDs) ?? []
        XCTAssertEqual(seenAfterClear.count, 200)
        XCTAssertTrue(seenAfterClear.contains(newSeenID))
        let retainedSeedCountAfterClear = seenAfterClear.filter { $0.hasPrefix("z-seen-") }.count
        XCTAssertEqual(retainedSeedCountAfterClear, 199)

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

    func testDetectOnLaunchUsesVersionBuildFromCrashReportText() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("Agent Sessions_2026-02-10-122000.crash")
        try makeCrashReportFile(at: reportURL, versionLine: "1.2.3 (456)")

        let storeURL = tempRoot.appendingPathComponent("pending.json")
        let store = CrashReportStore(fileManager: .default, pendingFileURL: storeURL, maxPendingCount: 1)
        let detector = CrashReportDetector(
            fileManager: .default,
            reportsRootURL: tempRoot,
            appName: "Agent Sessions",
            bundleIdentifier: "com.triada.AgentSessions",
            appVersion: "9.9.9",
            appBuild: "999",
            nowProvider: Date.init,
            lookbackWindow: 60 * 60 * 24 * 30,
            maxReports: 10
        )

        let defaults = testDefaults("CrashReportingServiceTests.reportVersionBuild")
        let service = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let detectedCount = await service.detectAndQueueOnLaunch()
        XCTAssertEqual(detectedCount, 1)

        let pending = await store.pending()
        let report = try XCTUnwrap(pending.first)
        XCTAssertEqual(report.appVersion, "1.2.3")
        XCTAssertEqual(report.appBuild, "456")
    }

    func testDetectOnLaunchParsesPrettyPrintedIPSReportPayload() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("AgentSessions-2026-04-28-151242.ips")
        try makePrettyPrintedIPSReportFile(at: reportURL)

        let storeURL = tempRoot.appendingPathComponent("pending.json")
        let store = CrashReportStore(fileManager: .default, pendingFileURL: storeURL, maxPendingCount: 1)
        let detector = CrashReportDetector(
            fileManager: .default,
            reportsRootURL: tempRoot,
            appName: "Agent Sessions",
            bundleIdentifier: "com.triada.AgentSessions",
            appVersion: "9.9.9",
            appBuild: "999",
            nowProvider: Date.init,
            lookbackWindow: 60 * 60 * 24 * 30,
            maxReports: 10
        )

        let defaults = testDefaults("CrashReportingServiceTests.prettyIPS")
        let service = CrashReportingService(
            store: store,
            detector: detector,
            userDefaults: defaults,
            nowProvider: Date.init
        )

        let detectedCount = await service.detectAndQueueOnLaunch()
        XCTAssertEqual(detectedCount, 1)

        let pending = await store.pending()
        let report = try XCTUnwrap(pending.first)
        XCTAssertEqual(report.appVersion, "3.6.4")
        XCTAssertEqual(report.appBuild, "40")
        XCTAssertEqual(report.rawMetadata["procName"], "")
        XCTAssertEqual(report.rawMetadata["bundleID"], "com.triada.AgentSessions")
        XCTAssertEqual(report.terminationSummary, "EXC_BREAKPOINT | SIGTRAP")
        XCTAssertEqual(report.topFrames.first, "Agent Sessions CrashReportDetector.parseIPS")
        XCTAssertEqual(report.crashTimestamp, ISO8601DateFormatter().date(from: "2026-04-28T12:12:42Z"))
    }

    func testDetectOnLaunchIgnoresXCTestInjectedIPSReport() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("AgentSessions-test-host.ips")
        let text = """
        {"bundleID":"com.triada.AgentSessions","procName":"AgentSessions","timestamp":"2026-10-07T12:00:00Z"}
        {
          "usedImages" : [
            {"path":"/Applications/Xcode.app/Contents/Developer/usr/lib/libXCTestBundleInject.dylib"}
          ]
        }
        """
        try text.write(to: reportURL, atomically: true, encoding: .utf8)

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

        XCTAssertTrue(detector.detectRecentCrashes().isEmpty)
    }

    // A helper the app launches (e.g. a Claude Code hook) shares the app's
    // coalition, so its .ips names the app only as coalition/responsible process.
    func testDetectIgnoresChildProcessIPSThatOnlyNamesAppAsCoalition() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let text = """
        {"app_name":"cc-status","app_version":"","build_version":"","bug_type":"309","name":"cc-status","timestamp":"2026-10-22 11:37:12.00 -0700"}
        {
          "procName" : "cc-status",
          "procPath" : "\\/Applications\\/iTerm.app\\/Contents\\/Resources\\/utilities\\/cc-status",
          "parentProc" : "launchd",
          "coalitionName" : "com.triada.AgentSessions",
          "responsibleProc" : "AgentSessions",
          "exception" : {"type" : "EXC_CRASH", "signal" : "SIGABRT"}
        }
        """
        try text.write(to: tempRoot.appendingPathComponent("cc-status-2026-10-22-113712.ips"), atomically: true, encoding: .utf8)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    func testDetectIgnoresChildProcessCrashTextThatOnlyNamesAppAsCoalition() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let text = """
        Process:               cc-status [30524]
        Identifier:            cc-status
        Version:               ???
        Responsible:           AgentSessions [25568]
        Coalition:             com.triada.AgentSessions [470752]
        Date/Time:             2026-10-22 11:37:12.000 -0700
        Exception Type:        EXC_CRASH (SIGABRT)
        """
        try text.write(to: tempRoot.appendingPathComponent("cc-status_2026-10-22-113712.crash"), atomically: true, encoding: .utf8)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    // Real app .ips files name the process by its executable ("AgentSessions").
    // The header here carries no process name or bundle id, so only the
    // payload procName can identify the app.
    func testDetectMatchesAppIPSIdentifiedOnlyByPayloadProcName() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips"), payloadFields: """
          "procName" : "AgentSessions",
          "coalitionName" : "com.triada.AgentSessions",
        """)

        let report = try XCTUnwrap(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().first)
        XCTAssertEqual(report.rawMetadata["procName"], "AgentSessions")
        XCTAssertEqual(report.terminationSummary, "EXC_CRASH | SIGABRT")
    }

    // A renamed executable still carries the app's bundle id in bundleInfo.
    func testDetectMatchesAppIPSIdentifiedOnlyByPayloadBundleID() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("AgentSessionsDev-2026-10-22-113712.ips"), payloadFields: """
          "procName" : "AgentSessionsDev",
          "bundleInfo" : {"CFBundleIdentifier" : "com.triada.AgentSessions"},
        """)

        let report = try XCTUnwrap(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().first)
        XCTAssertEqual(report.rawMetadata["bundleID"], "com.triada.AgentSessions")
    }

    // An explicit bundle id is authoritative: another app whose executable
    // happens to be named AgentSessions is not this app.
    func testDetectIgnoresCrashTextWithAppProcessNameButOtherIdentifier() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let text = """
        Process:               AgentSessions [1234]
        Identifier:            com.example.Unrelated
        Date/Time:             2026-10-22 11:37:12.000 -0700
        Exception Type:        EXC_CRASH (SIGABRT)
        """
        try text.write(to: tempRoot.appendingPathComponent("AgentSessions_2026-10-22-113712.crash"), atomically: true, encoding: .utf8)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    // procName names the crashed executable; a header app_name must not
    // override it.
    func testDetectIgnoresIPSWhoseProcNameIsAnotherProcess() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let text = """
        {"app_name":"Agent Sessions","bug_type":"309","timestamp":"2026-10-22 11:37:12.00 -0700"}
        {
          "procName" : "cc-status",
          "exception" : {"type" : "EXC_CRASH", "signal" : "SIGABRT"}
        }
        """
        try text.write(to: tempRoot.appendingPathComponent("cc-status-2026-10-22-113712.ips"), atomically: true, encoding: .utf8)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    func testDetectIgnoresIPSWithAppProcNameButOtherBundleID() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips"),
                     headerFields: #""bundleID":"com.example.Unrelated","#, payloadFields: """
          "procName" : "AgentSessions",
        """)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    // A user fault (ExcUserFault_*.ips) is a 309 report for a process that
    // kept running. macOS writes integer is_simulated/isSimulated; Apple
    // documents the payload flags as strings. Each marker is tested alone.
    func testDetectIgnoresIPSWithHeaderSimulatedMarker() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("ExcUserFault_AgentSessions-2026-10-22-120937.ips"),
                     headerFields: #""is_simulated":1,"bundleID":"com.triada.AgentSessions","#, payloadFields: """
          "procName" : "AgentSessions",
        """)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    func testDetectIgnoresIPSWithPayloadSimulatedMarkerAsString() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("ExcUserFault_AgentSessions-2026-10-22-120937.ips"), payloadFields: """
          "procName" : "AgentSessions",
          "isSimulated" : "true",
        """)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    func testDetectReportsAppIPSWhoseSimulatedMarkersAreZero() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips"),
                     headerFields: #""is_simulated":0,"#, payloadFields: """
          "procName" : "AgentSessions",
          "isSimulated" : 0,
          "isNonFatal" : "false",
        """)

        XCTAssertEqual(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().count, 1)
    }

    func testDetectReportsLegacyBugType109AppIPS() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips"), bugType: "109", payloadFields: """
          "procName" : "AgentSessions",
        """)

        XCTAssertEqual(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().count, 1)
    }

    // Without a payload procName, the header name identifies the process.
    func testDetectMatchesAppIPSIdentifiedOnlyByHeaderName() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips"),
                     headerFields: #""name":"AgentSessions","#, payloadFields: "")

        XCTAssertEqual(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().count, 1)
    }

    // Without an Identifier line, the Process line (minus its [pid]) decides.
    func testDetectMatchesCrashTextIdentifiedOnlyByProcessLine() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let text = """
        Process:               AgentSessions [1234]
        Date/Time:             2026-10-22 11:37:12.000 -0700
        Exception Type:        EXC_CRASH (SIGABRT)
        """
        try text.write(to: tempRoot.appendingPathComponent("AgentSessions_2026-10-22-113712.crash"), atomically: true, encoding: .utf8)

        XCTAssertEqual(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().count, 1)
    }

    func testDetectIgnoresSimulatedCrashText() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let text = """
        Process:               AgentSessions [1234]
        Identifier:            com.triada.AgentSessions
        Date/Time:             2026-10-22 11:37:12.000 -0700
        Exception Type:        EXC_GUARD
        Exception Note:        SIMULATED (this is NOT a crash)
        """
        try text.write(to: tempRoot.appendingPathComponent("AgentSessions_2026-10-22-113712.crash"), atomically: true, encoding: .utf8)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    // Stackshots (bug_type 288) and other diagnostics share the folder and the
    // .ips extension but are not crashes.
    func testDetectIgnoresAppIPSThatIsNotACrashReport() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips"), bugType: "288", payloadFields: """
          "procName" : "AgentSessions",
        """)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    func testDetectIgnoresAppIPSMarkedNonFatal() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips"), payloadFields: """
          "procName" : "AgentSessions",
          "isNonFatal" : true,
        """)

        XCTAssertTrue(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().isEmpty)
    }

    // macOS moves reports into Retired/ within days, often before the next launch.
    func testDetectFindsAppCrashAlreadyMovedIntoRetired() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let retired = tempRoot.appendingPathComponent("Retired", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try writeIPS(at: retired.appendingPathComponent("AgentSessions-2026-10-22-113712.ips"), payloadFields: """
          "procName" : "AgentSessions",
        """)

        XCTAssertEqual(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().count, 1)
    }

    // Seen and dismissed history stores report ids, so the move into Retired/
    // must not change them.
    func testRetiringAReportKeepsItsID() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips")
        try writeIPS(at: reportURL, payloadFields: """
          "procName" : "AgentSessions",
        """)
        let detector = makeDetector(reportsRootURL: tempRoot)
        let beforeRetire = try XCTUnwrap(detector.detectRecentCrashes().first)

        let retired = tempRoot.appendingPathComponent("Retired", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: reportURL, to: retired.appendingPathComponent(reportURL.lastPathComponent))
        let afterRetire = detector.detectRecentCrashes()

        XCTAssertEqual(afterRetire.count, 1)
        XCTAssertEqual(afterRetire.first?.id, beforeRetire.id)
        XCTAssertEqual(afterRetire.first?.reportSourcePathHash, beforeRetire.reportSourcePathHash)
    }

    func testLaterStillSuppressesCrashAfterMacOSRetiresIt() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportsRoot = tempRoot.appendingPathComponent("DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsRoot, withIntermediateDirectories: true)
        let reportURL = reportsRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips")
        try writeIPS(at: reportURL, payloadFields: """
          "procName" : "AgentSessions",
        """)

        let store = CrashReportStore(fileManager: .default,
                                     pendingFileURL: tempRoot.appendingPathComponent("pending.json"),
                                     maxPendingCount: 1)
        let detector = makeDetector(reportsRootURL: reportsRoot)
        let defaults = testDefaults("CrashReportingServiceTests.retiredAfterLater")

        let firstLaunch = CrashReportingService(store: store, detector: detector, userDefaults: defaults, nowProvider: Date.init)
        let firstDetected = await firstLaunch.detectAndQueueOnLaunch()
        XCTAssertEqual(firstDetected, 1)
        await firstLaunch.deferPendingReports()

        let retired = reportsRoot.appendingPathComponent("Retired", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: reportURL, to: retired.appendingPathComponent(reportURL.lastPathComponent))

        let secondLaunch = CrashReportingService(store: store, detector: detector, userDefaults: defaults, nowProvider: Date.init)
        let secondDetected = await secondLaunch.detectAndQueueOnLaunch()
        XCTAssertEqual(secondDetected, 0)
        let pendingCount = await store.pendingCount()
        XCTAssertEqual(pendingCount, 1)
    }

    // Real .ips headers write "2026-10-22 11:37:12.00 -0700", not ISO 8601.
    func testDetectParsesRealIPSHeaderTimestamp() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeIPS(at: tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips"), payloadFields: """
          "procName" : "AgentSessions",
        """)

        let report = try XCTUnwrap(makeDetector(reportsRootURL: tempRoot).detectRecentCrashes().first)
        XCTAssertEqual(report.crashTimestamp, ISO8601DateFormatter().date(from: "2026-10-22T18:37:12Z"))
    }

    // Older builds could not parse that header timestamp, so they seeded the id
    // without it. Parsing it now must not re-prompt crashes the user dismissed.
    func testParsedIPSHeaderTimestampDoesNotChangeReportID() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips")
        let detector = makeDetector(reportsRootURL: tempRoot)
        let payload = """
          "procName" : "AgentSessions",
        """

        try writeIPS(at: reportURL, timestamp: nil, payloadFields: payload)
        let withoutTimestamp = try XCTUnwrap(detector.detectRecentCrashes().first)
        try writeIPS(at: reportURL, payloadFields: payload)
        let withTimestamp = try XCTUnwrap(detector.detectRecentCrashes().first)

        XCTAssertNil(withoutTimestamp.crashTimestamp)
        XCTAssertNotNil(withTimestamp.crashTimestamp)
        XCTAssertEqual(withTimestamp.id, withoutTimestamp.id)
    }

    // Older builds did parse ISO 8601 timestamps and seeded the id with them,
    // so those ids must keep the timestamp.
    func testISOTimestampStillSeedsReportID() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("AgentSessions-2026-10-22-113712.ips")
        let detector = makeDetector(reportsRootURL: tempRoot)
        let payload = """
          "procName" : "AgentSessions",
        """

        try writeIPS(at: reportURL, timestamp: nil, payloadFields: payload)
        let withoutTimestamp = try XCTUnwrap(detector.detectRecentCrashes().first)
        try writeIPS(at: reportURL, timestamp: "2026-10-22T18:37:12Z", payloadFields: payload)
        let withISOTimestamp = try XCTUnwrap(detector.detectRecentCrashes().first)

        XCTAssertNotEqual(withISOTimestamp.id, withoutTimestamp.id)
    }

    // Builds before the identity fix queued crashes of child processes (for
    // example iTerm2's cc-status hook) as app crashes. They read procName from
    // the .ips header only, which real headers lack, so only the filename names
    // the process. A user who chose "Later" still has those reports pending.
    func testLaunchDropsPendingReportsOfOtherProcesses() async throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = CrashReportStore(fileManager: .default,
                                     pendingFileURL: tempRoot.appendingPathComponent("pending.json"),
                                     maxPendingCount: 10)
        await store.enqueue(contentsOf: [
            makeEnvelope(id: "child-by-filename", reportFilename: "cc-status-2026-10-22-113712.ips",
                         rawMetadata: ["format": "ips", "procName": ""]),
            makeEnvelope(id: "child-by-procname", reportFilename: "x.ips",
                         rawMetadata: ["format": "ips", "procName": "cc-status"]),
            makeEnvelope(id: "other-bundle", reportFilename: "AgentSessions-2026-10-22-113712.ips",
                         rawMetadata: ["format": "ips", "procName": "AgentSessions", "bundleID": "com.example.Unrelated"]),
            makeEnvelope(id: "child-crash-text", reportFilename: "cc-status_2026-10-22-113712_Mac.crash"),
            makeEnvelope(id: "user-fault", reportFilename: "ExcUserFault_AgentSessions-2026-10-22-120937.ips",
                         rawMetadata: ["format": "ips", "procName": ""]),
            makeEnvelope(id: "app-by-bundle", reportFilename: "cc-status-2026-10-22-113712.ips",
                         rawMetadata: ["format": "ips", "procName": "", "bundleID": "com.triada.AgentSessions"]),
            makeEnvelope(id: "app-by-filename", reportFilename: "AgentSessions-2026-10-21-234329.ips",
                         rawMetadata: ["format": "ips", "procName": ""]),
            makeEnvelope(id: "app-crash-text", reportFilename: "Agent Sessions_2026-02-10-120000.crash"),
            makeEnvelope(id: "unidentifiable", reportFilename: "report.crash")
        ])

        let service = CrashReportingService(store: store,
                                            detector: makeDetector(reportsRootURL: tempRoot),
                                            userDefaults: testDefaults("CrashReportingServiceTests.dropStalePending"),
                                            nowProvider: Date.init)
        let detected = await service.detectAndQueueOnLaunch()

        XCTAssertEqual(detected, 0)
        let remainingIDs = Set(await store.pending().map(\.id))
        XCTAssertEqual(remainingIDs, ["app-by-bundle", "app-by-filename", "app-crash-text", "unidentifiable"])
    }

    func testDetectCapturesUncaughtExceptionReasonAndBacktrace() throws {
        let tempRoot = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let reportURL = tempRoot.appendingPathComponent("AgentSessions-2026-10-21-234329.ips")
        try makeUncaughtExceptionIPSReportFile(at: reportURL)

        let detector = CrashReportDetector(
            fileManager: .default,
            reportsRootURL: tempRoot,
            appName: "Agent Sessions",
            bundleIdentifier: "com.triada.AgentSessions",
            appVersion: "6.0",
            appBuild: "82",
            nowProvider: Date.init,
            lookbackWindow: 60 * 60 * 24 * 30,
            maxReports: 10
        )

        let report = try XCTUnwrap(detector.detectRecentCrashes().first)

        // Real .ips frames carry imageIndex into usedImages, not imageName.
        XCTAssertEqual(report.topFrames, [
            "AppKit +[NSApplication _crashOnException:]",
            "AppKit -[NSWindow(NSConstraintBasedLayoutInternal) updateConstraintsIfNeeded]"
        ])
        XCTAssertEqual(
            report.exceptionReason,
            "AppKit: The window has been marked as needing another Update Constraints in Window pass. <path>"
        )
        // Stripped app frames keep their offset so they can be symbolicated with the dSYM.
        XCTAssertEqual(report.exceptionBacktrace, [
            "CoreFoundation __exceptionPreprocess",
            "libobjc.A.dylib objc_exception_throw",
            "AgentSessions +0x1a2b3c",
            "<image> <symbol>"
        ])

        let redacted = report.redactedForUpload()
        XCTAssertEqual(redacted.exceptionReason, report.exceptionReason)
        XCTAssertEqual(redacted.exceptionBacktrace, report.exceptionBacktrace)
    }

    func testPendingEnvelopeWithoutExceptionFieldsStillDecodes() throws {
        let json = """
        {"id":"a","detectedAt":"2026-10-14T14:57:49Z","reportSourcePathHash":"h","reportFilename":"x.ips",
         "appVersion":"5.6","appBuild":"80","macOSVersion":"27","architecture":"arm64",
         "terminationSummary":"EXC_BREAKPOINT","topFrames":[],"breadcrumbs":[],"rawMetadata":{}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(CrashReportEnvelope.self, from: Data(json.utf8))
        XCTAssertNil(envelope.exceptionReason)
        XCTAssertNil(envelope.exceptionBacktrace)
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

    /// Writes an .ips whose header names no process, so only `payloadFields`
    /// can identify it.
    private func writeIPS(at url: URL, bugType: String = "309", headerFields: String = "",
                          timestamp: String? = "2026-10-22 11:37:12.00 -0700", payloadFields: String) throws {
        let timestampField = timestamp.map { #","timestamp":"\#($0)""# } ?? ""
        let text = """
        {\(headerFields)"app_version":"6.1","build_version":"84","bug_type":"\(bugType)"\(timestampField)}
        {
        \(payloadFields)
          "exception" : {"type" : "EXC_CRASH", "signal" : "SIGABRT"}
        }
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeDetector(reportsRootURL: URL) -> CrashReportDetector {
        CrashReportDetector(
            fileManager: .default,
            reportsRootURL: reportsRootURL,
            appName: "Agent Sessions",
            bundleIdentifier: "com.triada.AgentSessions",
            appVersion: "6.1",
            appBuild: "84",
            nowProvider: Date.init,
            lookbackWindow: 60 * 60 * 24 * 30,
            maxReports: 10
        )
    }

    private func testDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeCrashReportFile(at url: URL, versionLine: String = "2.11.2 (21)") throws {
        let text = """
        Process:               Agent Sessions [100]
        Identifier:            com.triada.AgentSessions
        Version:               \(versionLine)
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

    private func makePrettyPrintedIPSReportFile(at url: URL) throws {
        let text = """
        {"bundleID":"com.triada.AgentSessions","procName":"","app_version":"3.6.4","build_version":"40","timestamp":"2026-04-28T12:12:42Z"}
        {
          "exception" : {
            "type" : "EXC_BREAKPOINT",
            "signal" : "SIGTRAP"
          },
          "faultingThread" : 1,
          "threads" : [
            {
              "frames" : [
                {
                  "imageName" : "AppKit",
                  "symbol" : "NSApplicationMain"
                }
              ]
            },
            {
              "frames" : [
                {
                  "imageName" : "Agent Sessions",
                  "symbol" : "CrashReportDetector.parseIPS"
                },
                {
                  "imageName" : "libswiftCore.dylib",
                  "symbol" : "swift_unknownObjectRelease"
                }
              ]
            }
          ]
        }
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeUncaughtExceptionIPSReportFile(at url: URL) throws {
        let text = """
        {"bundleID":"com.triada.AgentSessions","procName":"","app_version":"6.0","build_version":"82","timestamp":"2026-10-21T23:43:29Z"}
        {
          "exception" : {"type" : "EXC_BREAKPOINT", "signal" : "SIGTRAP"},
          "asi" : {
            "AppKit" : ["The window has been marked as needing another Update Constraints in Window pass. /Users/robert/Projects/secret"]
          },
          "faultingThread" : 0,
          "threads" : [
            {
              "frames" : [
                {"imageIndex" : 0, "imageOffset" : 100, "symbol" : "+[NSApplication _crashOnException:]"},
                {"imageIndex" : 0, "imageOffset" : 200, "symbol" : "-[NSWindow(NSConstraintBasedLayoutInternal) updateConstraintsIfNeeded]"}
              ]
            }
          ],
          "lastExceptionBacktrace" : [
            {"imageIndex" : 1, "imageOffset" : 975780, "symbol" : "__exceptionPreprocess", "symbolLocation" : 164},
            {"imageIndex" : 2, "imageOffset" : 1000, "symbol" : "objc_exception_throw"},
            {"imageIndex" : 3, "imageOffset" : 1715004},
            {"imageIndex" : 99}
          ],
          "usedImages" : [
            {"name" : "AppKit", "path" : "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"},
            {"name" : "CoreFoundation"},
            {"path" : "/usr/lib/libobjc.A.dylib"},
            {"name" : "AgentSessions", "path" : "/Applications/Agent Sessions.app/Contents/MacOS/AgentSessions"}
          ]
        }
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

    private func makeEnvelope(id: String,
                              reportFilename: String? = nil,
                              rawMetadata: [String: String] = ["format": "crash"]) -> CrashReportEnvelope {
        CrashReportEnvelope(
            id: id,
            detectedAt: Date(timeIntervalSince1970: 2_000_000_000),
            reportSourcePathHash: "hash-\(id)",
            reportFilename: reportFilename ?? "\(id).crash",
            crashTimestamp: Date(timeIntervalSince1970: 2_000_000_000),
            appVersion: "2.11.2",
            appBuild: "21",
            macOSVersion: "macOS 14",
            architecture: "arm64",
            terminationSummary: "EXC_BAD_ACCESS",
            topFrames: ["0 libswiftCore.dylib swift_unknownObjectRelease"],
            exceptionReason: nil,
            exceptionBacktrace: nil,
            breadcrumbs: ["launch.diagnostics_scan"],
            rawMetadata: rawMetadata
        )
    }
}
