import Foundation

/// One context-line item of an action (spec §6.3 L2 context line). Keys: "cwd", "shell",
/// "timeout", "script". The value is display text.
struct ToolContextItem: Equatable, Sendable {
    var key: String
    var value: String
}

/// One input argument for the generic renderer. The value is the decoded argument, with
/// ciphertext already replaced (`ToolInvocationBuilder.redactedCiphertext`).
struct ToolField: Equatable, Sendable {
    var key: String
    var value: ToolPayloadValue
}

/// One thing a tool call did (spec §6.2). A Codex code-mode script gives one action per child call.
struct ToolAction: Equatable, Sendable {
    var category: ToolCategory
    /// A `ToolVerb` catalog key ("tool.verb.ran", …). A structured action's verb is its display
    /// tool name instead ("github › create_pr"), shown as is. Read it through `ToolVerb.text(_:)`.
    var verbKey: String
    /// Single line.
    var object: String
    /// Spec §14 Q1: the object is agent-written prose (a `description` input or a ready-made
    /// title), shown in the system font.
    var objectIsAgentLabel: Bool
    var objectDetail: String?
    var context: [ToolContextItem]
    /// Display form of a shell action's command (the L2 command pane): the agent's text after the
    /// wrapper and a leading `cd` moved to the context; first line only when a heredoc is split off.
    var command: String?
    /// The command exactly as the agent sent it, before any lift or split (an argv array is joined
    /// with shell quoting). `plainText` and Copy Command use this form. Nil for non-shell actions.
    var exactCommand: String?
    /// Body of a `<<'EOF'` / `<<EOF` / `<<-EOF` heredoc, shown as its own pane with a gutter.
    var heredoc: DecodedText?
    /// Generic renderer input; primary-argument keys first, then alphabetical. Empty for shell
    /// actions (their input is `command`).
    var inputFields: [ToolField]
    var output: DecodedText?
    var facts: [AgentFact]
    var hiddenNotes: [String]
    var status: ToolStatus
    /// Spec §8 form. Shell: `$ <exactCommand>`. Others: `<verb> <object>`, then one `key: value`
    /// line per input field. Then `[exit N · 48s]` when known, then the decoded output with folds
    /// open and no gutter.
    var plainText: String
}

struct ToolInvocation: Equatable, Sendable {
    var ref: ToolInvocationRef
    var displayToolName: String
    /// At least one; the same count and order as `ToolInvocationBuilder.rowSummary(…).actions`.
    var actions: [ToolAction]
    /// Codex exec JavaScript, for "Show script".
    var scriptSource: String?
    /// Code-mode output not assigned to a command (loose text, or every chunk when chunks do not
    /// map to commands), shown under the script (spec §9). Never an action.
    var scriptOutput: DecodedText?
    var durationSeconds: Double?
}

extension ToolInvocation {
    /// The invocation's plain form: its actions' `plainText` joined by a blank line, then
    /// `scriptOutput` when present.
    var plainText: String {
        var parts = actions.map(\.plainText)
        if let script = scriptOutput?.text, !script.isEmpty { parts.append(script) }
        return parts.joined(separator: "\n\n")
    }
}

/// The L1 part of an action (no output, no plain text).
struct ToolRowAction: Equatable, Sendable {
    var category: ToolCategory
    var verbKey: String
    var object: String
    var objectIsAgentLabel: Bool
    var objectDetail: String?
    /// The action's own status: a code-mode command whose chunk maps to it reads that chunk's exit
    /// code (metadata only); every other action has the invocation's status.
    var status: ToolStatus
    /// `ToolChip.chips(for: status)`.
    var chips: [String]
}

extension ToolRowAction {
    /// The L1 line as plain text: `<verb> <object>`, then ` <detail>` when there is one. Selection
    /// copy uses it; empty parts leave out their space.
    var lineText: String {
        [ToolVerb.text(verbKey), object, objectDetail ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// What an L1 row needs, built without decoding any output body.
struct ToolRowSummary: Equatable, Sendable {
    var actions: [ToolRowAction]
    /// Invocation-level, pre-formatted from the invocation's cheap status only (`ToolChip.chips(for:)`).
    var chips: [String]
}

// MARK: - Localized text

/// Verb keys and their catalog text (spec §6.3).
enum ToolVerb {
    static let ran = "tool.verb.ran"
    static let polled = "tool.verb.polled"
    static let sentInput = "tool.verb.sentInput"
    static let ranScript = "tool.verb.ranScript"
    static let read = "tool.verb.read"
    static let created = "tool.verb.created"
    static let edited = "tool.verb.edited"
    static let searched = "tool.verb.searched"
    static let listed = "tool.verb.listed"
    static let fetched = "tool.verb.fetched"
    static let searchedWeb = "tool.verb.searchedWeb"
    static let updatedPlan = "tool.verb.updatedPlan"
    static let subagent = "tool.verb.subagent"
    static let asked = "tool.verb.asked"
    static let screenshot = "tool.verb.screenshot"
    static let output = "tool.verb.output"

    /// The localized verb for a key. Any other value (a structured action's tool name) comes back as is.
    static func text(_ verbKey: String) -> String {
        switch verbKey {
        case ran: return String(localized: "tool.verb.ran", defaultValue: "Ran",
                                comment: "Transcript tool row verb before a shell command or its description.")
        case polled: return String(localized: "tool.verb.polled", defaultValue: "Polled",
                                   comment: "Transcript tool row verb: the agent checked a running process for new output.")
        case sentInput: return String(localized: "tool.verb.sentInput", defaultValue: "Sent input",
                                      comment: "Transcript tool row verb: the agent typed input into a running process.")
        case ranScript: return String(localized: "tool.verb.ranScript", defaultValue: "Ran script",
                                      comment: "Transcript tool row verb before a script the agent ran.")
        case read: return String(localized: "tool.verb.read", defaultValue: "Read",
                                 comment: "Transcript tool row verb (past tense) before a file name the agent read.")
        case created: return String(localized: "tool.verb.created", defaultValue: "Created",
                                    comment: "Transcript tool row verb before a file path the agent wrote.")
        case edited: return String(localized: "tool.verb.edited", defaultValue: "Edited",
                                   comment: "Transcript tool row verb before a file name the agent edited.")
        case searched: return String(localized: "tool.verb.searched", defaultValue: "Searched",
                                     comment: "Transcript tool row verb before a search pattern.")
        case listed: return String(localized: "tool.verb.listed", defaultValue: "Listed",
                                   comment: "Transcript tool row verb before a directory the agent listed.")
        case fetched: return String(localized: "tool.verb.fetched", defaultValue: "Fetched",
                                    comment: "Transcript tool row verb before a URL the agent fetched.")
        case searchedWeb: return String(localized: "tool.verb.searchedWeb", defaultValue: "Searched the web",
                                        comment: "Transcript tool row verb before a web search query.")
        case updatedPlan: return String(localized: "tool.verb.updatedPlan", defaultValue: "Updated plan",
                                        comment: "Transcript tool row verb: the agent changed its task plan.")
        case subagent: return String(localized: "tool.verb.subagent", defaultValue: "Subagent",
                                     comment: "Transcript tool row label for a call that starts or messages another agent.")
        case asked: return String(localized: "tool.verb.asked", defaultValue: "Asked",
                                  comment: "Transcript tool row verb before a question the agent asked the user.")
        case screenshot: return String(localized: "tool.verb.screenshot", defaultValue: "Screenshot",
                                       comment: "Transcript tool row label for an image or screenshot tool call.")
        case output: return String(localized: "tool.verb.output", defaultValue: "Output",
                                   comment: "Transcript tool row label for tool output whose call is not shown.")
        default: return verbKey
        }
    }
}

/// Result chips (spec §6.3 "Result chips", §9). Lower case, short, SF Mono in the row.
enum ToolChip {
    static func exit(_ code: Int) -> String {
        String(localized: "exit \(code)", comment: "Transcript tool row chip: the command's exit code. %lld is the code.")
    }

    static var error: String {
        String(localized: "error", comment: "Transcript tool row chip: the tool call failed without an exit code.")
    }

    static func lines(_ count: Int) -> String {
        String(localized: "\(count) lines", comment: "Transcript tool row chip: number of output lines. %lld is the count.")
    }

    static var noOutput: String {
        String(localized: "no output", comment: "Transcript tool row chip: the tool call finished with empty output.")
    }

    static var noMatches: String {
        String(localized: "no matches", comment: "Transcript tool row chip: a search command found nothing.")
    }

    /// `agent` is the agent's product name, for example "Codex".
    static func cutBy(_ agent: String) -> String {
        String(localized: "cut by \(agent)",
               comment: "Transcript tool row chip: the agent shortened this output before saving it. %@ is the agent name, for example Codex.")
    }

    static var rejected: String {
        String(localized: "rejected by you", comment: "Transcript tool row chip: the user declined this tool call.")
    }

    static var interrupted: String {
        String(localized: "interrupted", comment: "Transcript tool row chip: the tool call stopped because the turn was interrupted.")
    }

    static var noResult: String {
        String(localized: "no result recorded", comment: "Transcript tool row chip: the session continued but stored no result for this call.")
    }

    static var pending: String {
        String(localized: "no result yet", comment: "Transcript tool row chip: the call is the latest one and has no result so far.")
    }

    /// The chips a status alone gives. `success` and `unknown` give none.
    static func chips(for status: ToolStatus) -> [String] {
        switch status {
        case .success, .unknown: return []
        case .failed(let code): return [code.map(exit) ?? error]
        case .rejected: return [rejected]
        case .interrupted: return [interrupted]
        case .noResult: return [noResult]
        case .pending: return [pending]
        }
    }
}

enum ToolText {
    /// Object detail of a process poll: the session the poll reads.
    static func session(_ id: String) -> String {
        String(localized: "session \(id)",
               comment: "Transcript tool row detail of a process poll. %@ is the process session ID, a number.")
    }

    /// Object detail of a `wait` poll: the code-mode cell it waits on.
    static func cell(_ id: String) -> String {
        String(localized: "cell \(id)",
               comment: "Transcript tool row detail of a wait call. %@ is the ID of the running script cell.")
    }

    /// Context item of one command in a Codex code-mode script.
    static func scriptCommand(_ index: Int, of count: Int) -> String {
        String(localized: "exec script · command \(index) of \(count)",
               comment: "Transcript tool context line: this command is one of several in an exec script. The first number is its position, the second the total. 'exec' is a tool name and stays verbatim.")
    }

    /// Shown instead of a Codex `collaboration` message, which the log stores encrypted.
    static func encrypted(characters: Int) -> String {
        String(localized: "message encrypted in the log (\(characters) chars)",
               comment: "Transcript placeholder for an agent message stored encrypted in the session log. %lld is its length in characters.")
    }
}
