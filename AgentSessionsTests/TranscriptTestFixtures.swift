import Foundation
@testable import AgentSessions

/// Shared synthetic-session builders for transcript block-space tests.
/// Lifted out of `TranscriptWindowedBuildTests`'s private per-test fixtures so
/// other suites (e.g. `TranscriptDerivedStateTests`) can reuse the same
/// interleaved user/assistant/tool event shape without duplicating it.
enum TranscriptTestFixtures {

    static func userEvent(_ id: String, _ text: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .user, role: "user", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    static func assistantDelta(_ id: String, _ text: String, messageID: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .assistant, role: "assistant", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: messageID, parentID: nil, isDelta: true, rawJSON: "{}")
    }

    static func toolCallEvent(_ id: String, toolName: String = "shell",
                              input: String = "{\"command\":[\"ls\"]}") -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_call, role: "assistant", text: nil,
                     toolName: toolName, toolInput: input, toolOutput: nil,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    static func toolResultEvent(_ id: String, output: String, toolName: String = "shell") -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                     toolName: toolName, toolInput: nil, toolOutput: output,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    /// Produces an `.error`-KIND LogicalBlock. `toolName` and `toolOutput` must
    /// BOTH be nil: `SessionTranscriptBuilder.block(from:)` maps an error event
    /// with either of those set to a `.toolOut` block (with isErrorOutput=true)
    /// instead of an `.error`-kind block.
    static func errorEvent(_ id: String, _ text: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .error, role: nil, text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    /// Synthetic session with a repeating user -> toolCall -> toolOut ->
    /// assistant -> error cycle so the resulting coalesced blocks exercise every
    /// `LogicalBlock.Kind` case reachable under `includeMeta: false` (user,
    /// toolCall, toolOut, assistant, error) that block-space derived state
    /// (user/tool/error indices, anchors, find matches) needs to discriminate.
    /// `.meta` blocks are deliberately absent: `SessionTranscriptBuilder.coalesce`
    /// drops meta events entirely when `includeMeta == false` (the mode every
    /// derived-state/`coalescedBlocks(for:includeMeta: false)` call site uses),
    /// so a meta-kind block is structurally unreachable in this fixture's
    /// consumers — not an oversight.
    /// `eventCount` is approximate: it is rounded down to a whole number of
    /// 5-event cycles.
    static func makeSyntheticSession(eventCount: Int, id: String = "s-synthetic") -> Session {
        let cycles = max(1, eventCount / 5)
        var events: [SessionEvent] = []
        events.reserveCapacity(cycles * 5)
        for p in 0..<cycles {
            events.append(userEvent("u-\(p)", "Question number \(p)\nwith two lines"))
            events.append(toolCallEvent("call-\(p)", input: "{\"command\":[\"echo\",\"\(p)\"]}"))
            events.append(toolResultEvent("out-\(p)", output: "line \(p) of output\nexit code: 0"))
            events.append(assistantDelta("a-\(p)", "Answer \(p) for the request", messageID: "asst-\(p)"))
            events.append(errorEvent("err-\(p)", "error: synthetic failure \(p)"))
        }
        return Session(id: id, source: .codex, startTime: nil, endTime: nil,
                       model: "test", filePath: "/tmp/\(id).jsonl", fileSizeBytes: nil,
                       eventCount: events.count, events: events)
    }

    // MARK: - Directly-constructed blocks with controllable timestamps
    //
    // `makeSyntheticSession` routes through `SessionEvent` + `coalesce`, whose
    // event builders above always pass `timestamp: nil` — there's no way to
    // get deterministic, controllable timestamps out of that path. Timing
    // tests (Phase 3 T18) need exact per-block timestamps, so this builds
    // `LogicalBlock`s directly (the same pattern `TranscriptToolSummaryTests`
    // already uses ad hoc), keyed by a simple spec so call sites read as a
    // timeline rather than a wall of memberwise-init boilerplate.

    /// One entry in a `makeTimedBlocks` timeline.
    struct TimedBlockSpec {
        var kind: SessionTranscriptBuilder.LogicalBlock.Kind
        /// Seconds since a common (arbitrary) epoch; nil → block has no timestamp.
        var offset: Double?
        var toolName: String? = nil

        static func user(_ offset: Double?) -> TimedBlockSpec { .init(kind: .user, offset: offset) }
        static func assistant(_ offset: Double?) -> TimedBlockSpec { .init(kind: .assistant, offset: offset) }
        static func toolCall(_ offset: Double?, toolName: String = "shell") -> TimedBlockSpec {
            .init(kind: .toolCall, offset: offset, toolName: toolName)
        }
        static func toolOut(_ offset: Double?, toolName: String = "shell") -> TimedBlockSpec {
            .init(kind: .toolOut, offset: offset, toolName: toolName)
        }
        static func error(_ offset: Double?) -> TimedBlockSpec { .init(kind: .error, offset: offset) }
        static func meta(_ offset: Double?) -> TimedBlockSpec { .init(kind: .meta, offset: offset) }
    }

    /// Builds `[LogicalBlock]` from a timeline of specs, one block per spec, in
    /// order. `globalBlockIndex` is assigned sequentially starting at 0 (matching
    /// what `SessionTranscriptBuilder.coalesce` does for a real session), and each
    /// spec's `offset` becomes `Date(timeIntervalSince1970: offset)` (nil stays nil).
    /// `eventID` is synthesized as `"e\(index)"` — tests that don't care about it
    /// can ignore it; tests that need a specific tool-call/tool-out pairing by ID
    /// can still assert on `toolName` or index.
    static func makeTimedBlocks(_ specs: [TimedBlockSpec]) -> [SessionTranscriptBuilder.LogicalBlock] {
        specs.enumerated().map { index, spec in
            var block = SessionTranscriptBuilder.LogicalBlock(
                kind: spec.kind,
                text: "",
                timestamp: spec.offset.map { Date(timeIntervalSince1970: $0) },
                messageID: nil,
                toolName: spec.toolName,
                isDelta: false,
                toolInput: nil,
                isErrorOutput: false,
                eventID: "e\(index)",
                rawJSON: "")
            block.globalBlockIndex = index
            return block
        }
    }
}
