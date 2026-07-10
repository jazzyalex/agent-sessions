import XCTest
@testable import AgentSessions

final class ClaudeWorkflowSubagentTests: XCTestCase {

    // MARK: - Fixture helpers

    private var createdDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in createdDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        createdDirs.removeAll()
        try super.tearDownWithError()
    }

    /// Returns a fresh, unique temp directory that is removed in tearDown.
    private func makeUniqueTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeWorkflowSubagentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdDirs.append(dir)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url)
    }

    private let parentUUID = "11111111-2222-4333-8444-555555555555"

    /// Builds a Claude `Session` with empty events (mirrors lightweight parsing).
    private func claudeSession(id: String,
                               filePath: String,
                               parentSessionID: String?,
                               subagentType: String?,
                               hint: String?) -> Session {
        Session(
            id: id,
            source: .claude,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            model: "claude-opus-4-8",
            filePath: filePath,
            eventCount: 1,
            events: [],
            isHousekeeping: false,
            codexInternalSessionIDHint: hint,
            parentSessionID: parentSessionID,
            subagentType: subagentType
        )
    }

    // MARK: - detectSubagentInfo: nested workflow layout

    func test_detectSubagentInfo_nestedWorkflowLayout_returnsParentAndAgentType() throws {
        let root = try makeUniqueTempDir()
        // .../<projectHash>/<parentUUID>/subagents/workflows/wf_abc/agent-<id>.jsonl
        let agentDir = root
            .appendingPathComponent("projecthash", isDirectory: true)
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf_abc", isDirectory: true)
        let agentFile = agentDir.appendingPathComponent("agent-a0a3e832029606953.jsonl")
        try write("{}\n", to: agentFile)
        try write(#"{"agentType":"workflow-subagent","spawnDepth":1}"#,
                  to: agentDir.appendingPathComponent("agent-a0a3e832029606953.meta.json"))

        let (parent, type) = ClaudeSessionParser.detectSubagentInfo(from: agentFile)

        XCTAssertEqual(parent, parentUUID)
        XCTAssertEqual(type, "workflow-subagent")
    }

    func test_detectSubagentInfo_flatLayout_stillResolvesParentAndAgentType() throws {
        let root = try makeUniqueTempDir()
        // .../<projectHash>/<parentUUID>/subagents/agent-<id>.jsonl
        let subagentsDir = root
            .appendingPathComponent("projecthash", isDirectory: true)
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        let agentFile = subagentsDir.appendingPathComponent("agent-cafef00d.jsonl")
        try write("{}\n", to: agentFile)
        try write(#"{"agentType":"Explore"}"#,
                  to: subagentsDir.appendingPathComponent("agent-cafef00d.meta.json"))

        let (parent, type) = ClaudeSessionParser.detectSubagentInfo(from: agentFile)

        XCTAssertEqual(parent, parentUUID)
        XCTAssertEqual(type, "Explore")
    }

    func test_detectSubagentInfo_nonUUIDParent_returnsNil() throws {
        let root = try makeUniqueTempDir()
        // A user folder literally named "subagents" must not be mistaken for a parent.
        let agentFile = root
            .appendingPathComponent("not-a-uuid", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("agent-x.jsonl")
        try write("{}\n", to: agentFile)

        let (parent, type) = ClaudeSessionParser.detectSubagentInfo(from: agentFile)

        XCTAssertNil(parent)
        XCTAssertNil(type)
    }

    func test_detectSubagentInfo_topLevelSession_returnsNil() throws {
        let root = try makeUniqueTempDir()
        let topLevel = root
            .appendingPathComponent("projecthash", isDirectory: true)
            .appendingPathComponent("\(parentUUID).jsonl")
        try write("{}\n", to: topLevel)

        let (parent, type) = ClaudeSessionParser.detectSubagentInfo(from: topLevel)

        XCTAssertNil(parent)
        XCTAssertNil(type)
    }

    // MARK: - Hierarchy nesting (consequence of the detection fix)

    func test_hierarchy_workflowSubagentNestsUnderParent() {
        let parent = claudeSession(
            id: "PARENT_ID",
            filePath: "/p/projecthash/\(parentUUID).jsonl",
            parentSessionID: nil,
            subagentType: nil,
            hint: parentUUID)
        let workflowChild = claudeSession(
            id: "CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID,           // produced by the Task 1 fix
            subagentType: "workflow-subagent",
            hint: parentUUID)                       // carries the PARENT's sessionId

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, workflowChild],
            hierarchyEnabled: true)

        XCTAssertEqual(result.sessions.map(\.id), ["PARENT_ID", "CHILD_ID"])
        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.childCount, 1)
        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.hasChildren, true)
        XCTAssertEqual(result.rowMeta["CHILD_ID"]?.depth, 1)
    }

    func test_hierarchy_workflowSubagentHint_doesNotStealSiblingResolution() {
        // Regression for the hint-collision risk: the workflow child carries the
        // parent's sessionId as its hint. If it were (pre-fix) treated as a root
        // (parentSessionID == nil), it would register parentKeyToID[parentUUID] =
        // CHILD and steal a real flat sibling. With parentSessionID set, the
        // builder's guard skips its hint and BOTH children resolve to the parent.
        let parent = claudeSession(
            id: "PARENT_ID",
            filePath: "/p/projecthash/\(parentUUID).jsonl",
            parentSessionID: nil, subagentType: nil, hint: parentUUID)
        let workflowChild = claudeSession(
            id: "WF_CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)
        let flatChild = claudeSession(
            id: "FLAT_CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/agent-2.jsonl",
            parentSessionID: parentUUID, subagentType: "Explore", hint: parentUUID)

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, workflowChild, flatChild],
            hierarchyEnabled: true)

        // Both children fold under the real parent — not under each other.
        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.childCount, 2)
        XCTAssertEqual(result.rowMeta["WF_CHILD_ID"]?.depth, 1)
        XCTAssertEqual(result.rowMeta["FLAT_CHILD_ID"]?.depth, 1)
        XCTAssertEqual(result.sessions.first?.id, "PARENT_ID")
    }

    // MARK: - Discovery excludes workflow journal + sidecars

    func test_discovery_excludesWorkflowJournalAndSidecars() throws {
        let root = try makeUniqueTempDir()
        let project = root.appendingPathComponent("projecthash", isDirectory: true)
        let parentFile = project.appendingPathComponent("\(parentUUID).jsonl")
        let parentDir = project.appendingPathComponent(parentUUID, isDirectory: true)
        let wfDir = parentDir
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf_abc", isDirectory: true)
        let agentFile = wfDir.appendingPathComponent("agent-a0a3e832029606953.jsonl")
        // Real transcripts:
        try write(#"{"sessionId":"\#(parentUUID)","isSidechain":true}"#, to: parentFile)
        try write("{}\n", to: agentFile)
        // Sidecars from a real run — none may be ingested:
        try write(#"{"type":"started","agentId":"a0a3e832029606953"}"#, to: wfDir.appendingPathComponent("journal.jsonl"))
        try write(#"{"agentType":"workflow-subagent","spawnDepth":1}"#, to: wfDir.appendingPathComponent("agent-a0a3e832029606953.meta.json"))
        try write("// workflow script\n", to: parentDir.appendingPathComponent("workflows/scripts/migration-wf_abc.js"))
        try write("{}", to: parentDir.appendingPathComponent("workflows/wf_abc.json"))
        try write("tool output spill", to: parentDir.appendingPathComponent("tool-results/bj5l1z0m6.txt"))

        let discovery = ClaudeSessionDiscovery(customRoot: root.path, includeDesktopRoots: false)
        let names = Set(discovery.discoverSessionFiles().map(\.lastPathComponent))

        XCTAssertEqual(names, ["\(parentUUID).jsonl", "agent-a0a3e832029606953.jsonl"],
                       "only the parent + agent transcripts may be discovered")
        XCTAssertFalse(names.contains("journal.jsonl"), "workflow journal must not be ingested as a session")
    }

    func test_collectSessionFiles_sidecarsDoNotStarveVisitCap() throws {
        let root = try makeUniqueTempDir()
        let wfDir = root
            .appendingPathComponent("projecthash", isDirectory: true)
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf_abc", isDirectory: true)
        // 2 transcripts surrounded by many sidecars that previously burned the cap.
        try write("{}\n", to: wfDir.appendingPathComponent("agent-1.jsonl"))
        try write("{}\n", to: wfDir.appendingPathComponent("agent-2.jsonl"))
        try write(#"{"type":"started"}"#, to: wfDir.appendingPathComponent("journal.jsonl"))
        for i in 0..<10 {
            try write("{}", to: wfDir.appendingPathComponent("agent-\(i).meta.json"))
        }

        let discovery = ClaudeSessionDiscovery(customRoot: root.path, includeDesktopRoots: false)
        let (files, hitCap) = discovery.collectSessionFiles(in: root, fileCap: 2)

        // Both transcripts fit in a cap of 2 because sidecars/journal no longer count.
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["agent-1.jsonl", "agent-2.jsonl"])
        XCTAssertFalse(hitCap)
    }

    // MARK: - Resume ID helpers (nested layout)

    func test_deriveSessionID_nestedWorkflowAgent_returnsParentUUID() {
        // events == [] on purpose: lightweight parse must not be relied on.
        let session = claudeSession(
            id: "CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)

        XCTAssertEqual(ClaudeSessionIDHelper.deriveSessionID(from: session), parentUUID)
    }

    @MainActor
    func test_projectRoot_nestedWorkflowAgent_readsProjectSessionsIndex() throws {
        let root = try makeUniqueTempDir()
        let project = root.appendingPathComponent("projecthash", isDirectory: true)
        try write(#"{"originalPath":"/Users/me/code/widgets"}"#,
                  to: project.appendingPathComponent("sessions-index.json"))
        let agentPath = project
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf_abc", isDirectory: true)
            .appendingPathComponent("agent-1.jsonl").path
        let session = claudeSession(
            id: "CHILD_ID", filePath: agentPath,
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)

        let resolved = ClaudeSessionIDHelper.projectRoot(for: session)

        XCTAssertEqual(resolved?.path, "/Users/me/code/widgets")
    }

    // MARK: - Workflow badge label

    func test_workflowBadgeLabel_mapsWorkflowSubagentToWorkflow() {
        XCTAssertEqual(WorkflowSubagentBadge.displayLabel(for: "workflow-subagent"), "workflow")
    }

    func test_workflowBadgeLabel_passesThroughOtherTypes() {
        XCTAssertEqual(WorkflowSubagentBadge.displayLabel(for: "Explore"), "Explore")
        XCTAssertEqual(WorkflowSubagentBadge.displayLabel(for: "general"), "general")
    }

    // MARK: - Resume gating for workflow subagents

    func test_isClaudeWorkflowSubagent_trueForWorkflowAgent() {
        let wf = claudeSession(
            id: "CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)
        XCTAssertTrue(wf.isClaudeWorkflowSubagent)
    }

    func test_isClaudeWorkflowSubagent_falseForFlatSubagent() {
        let flat = claudeSession(
            id: "FLAT_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/agent-2.jsonl",
            parentSessionID: parentUUID, subagentType: "Explore", hint: parentUUID)
        XCTAssertFalse(flat.isClaudeWorkflowSubagent)
    }

    // MARK: - Parent workflow marker

    func test_hierarchy_parentWithWorkflowChild_flagsHasWorkflowChildren() {
        let parent = claudeSession(
            id: "PARENT_ID",
            filePath: "/p/projecthash/\(parentUUID).jsonl",
            parentSessionID: nil, subagentType: nil, hint: parentUUID)
        let workflowChild = claudeSession(
            id: "WF_CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, workflowChild], hierarchyEnabled: true)

        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.hasWorkflowChildren, true)
        // The child itself is not a parent — never flagged.
        XCTAssertEqual(result.rowMeta["WF_CHILD_ID"]?.hasWorkflowChildren, false)
    }

    func test_hierarchy_parentWithOnlyFlatSubagents_doesNotFlagWorkflow() {
        let parent = claudeSession(
            id: "PARENT_ID",
            filePath: "/p/projecthash/\(parentUUID).jsonl",
            parentSessionID: nil, subagentType: nil, hint: parentUUID)
        let flatChild = claudeSession(
            id: "FLAT_CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/agent-2.jsonl",
            parentSessionID: parentUUID, subagentType: "Explore", hint: parentUUID)

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, flatChild], hierarchyEnabled: true)

        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.hasWorkflowChildren, false)
    }

    // MARK: - Lightweight parse: multi-byte UTF-8 slice boundaries (issue #49 root cause)

    private static let lightweightHeadSlice = 256 * 1024
    private static let lightweightTailSlice = 256 * 1024

    /// Builds a large (> head+tail) Claude JSONL whose head slice ends inside a
    /// multi-byte character AND whose tail slice starts inside one, so the
    /// strict-UTF8 slice decoder would drop both slices whole. The first line is
    /// a genuine Japanese user prompt: if either slice decodes, the session is
    /// non-housekeeping.
    private func makeCJKBoundarySplittingSession(promptLine: String) -> Data {
        let head = Self.lightweightHeadSlice
        let tail = Self.lightweightTailSlice
        // Long run of 3-byte characters so a slice boundary reliably lands mid-char.
        let filler = #"{"type":"summary","summary":"\#(String(repeating: "あ", count: 4000))"}"#

        func padLine(_ n: Int) -> Data {
            Data(("{\"type\":\"summary\",\"summary\":\"" + String(repeating: " ", count: n) + "\"}\n").utf8)
        }
        func assemble(headPad: Int, tailPad: Int) -> Data {
            var d = Data()
            d.append(Data((promptLine + "\n").utf8))
            if headPad > 0 { d.append(padLine(headPad)) }
            while d.count < head + tail + 96 * 1024 {
                d.append(Data((filler + "\n").utf8))
            }
            // tailPad is appended last, so it never shifts bytes[0..<head).
            if tailPad > 0 {
                d.append(Data(("{\"type\":\"summary\",\"summary\":\"" + String(repeating: " ", count: tailPad) + "\"}").utf8))
            }
            return d
        }
        func headSplits(_ d: Data) -> Bool { String(data: Data(d.prefix(head)), encoding: .utf8) == nil }
        func tailSplits(_ d: Data) -> Bool { String(data: Data(d.suffix(tail)), encoding: .utf8) == nil }

        // Align the head boundary first (pad inserted before it), then the tail
        // (pad appended at end) with head fixed. The cap must exceed the widest
        // run of non-splitting bytes (the ~31-byte ASCII structure between filler
        // runs) so a 1-byte-at-a-time nudge is guaranteed to walk into the
        // 3-byte-char run and land mid-character.
        let maxPad = 64
        var headPad = 0
        while headPad < maxPad, !headSplits(assemble(headPad: headPad, tailPad: 0)) { headPad += 1 }
        var tailPad = 0
        while tailPad < maxPad, !tailSplits(assemble(headPad: headPad, tailPad: tailPad)) { tailPad += 1 }
        return assemble(headPad: headPad, tailPad: tailPad)
    }

    func test_lightweightParse_largeCJKSession_notMisclassifiedAsHousekeeping() throws {
        let dir = try makeUniqueTempDir()
        let url = dir.appendingPathComponent("\(parentUUID).jsonl")

        let promptText = "テニスのコーチング分析ツールを作ってください。完全にオフラインで動作する必要があります。"
        let promptLine = "{\"type\":\"user\",\"sessionId\":\"\(parentUUID)\",\"cwd\":\"/Users/me/proj\",\"timestamp\":\"2026-07-01T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(promptText)\"}]}}"

        let data = makeCJKBoundarySplittingSession(promptLine: promptLine)
        try data.write(to: url)

        // Precondition: the fixture actually reproduces the split boundaries the
        // bug depends on — otherwise the assertion below would pass vacuously.
        XCTAssertNil(String(data: Data(data.prefix(Self.lightweightHeadSlice)), encoding: .utf8),
                     "fixture head slice should split a multi-byte char")
        XCTAssertNil(String(data: Data(data.suffix(Self.lightweightTailSlice)), encoding: .utf8),
                     "fixture tail slice should split a multi-byte char")

        let session = try XCTUnwrap(ClaudeSessionParser.parseFile(at: url))

        XCTAssertFalse(session.isHousekeeping,
                       "A large CJK session with a real prompt must not be hidden as housekeeping")
    }
}
