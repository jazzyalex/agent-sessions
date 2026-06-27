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
}
