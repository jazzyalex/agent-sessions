import Foundation

// as-core: headless Agent Sessions core. Prints JSON, one object per line, on stdout;
// logs go to stderr.
//
//   as-core index  [--source s]...                build or refresh the search index
//   as-core list   [--source s]... [--limit n]    newest indexed sessions
//   as-core search <query> [--source s]... [--limit n]
//   as-core show   <source> <file> [--id id]      session header + every event
//   as-core resume <source> <file> [--id id]      shell command that reopens the session
//   as-core parse  <source> <file>                one-file summary (no index)
//   as-core scan   [--source s]... [--light]      discover + parse (no index)
//
// list/search hide subagent runs (e.g. Codex auto-review) unless --include-subagents.
// Common: --db <path> (default $AS_CORE_DB, $XDG_DATA_HOME/agent-sessions/index.db, or
// ~/.local/share/agent-sessions/index.db; never the macOS app's index).

// No bundle ID here; declare ourselves a real host so backend detectors probe the disk.
AppRuntime.isStandaloneCoreHost = true
redirectLogsToStderr()

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else {
    fail("usage: as-core <index|list|search|show|resume|parse|scan> [options]", code: 2)
}
let options = Options(arguments.dropFirst())

switch command {
case "index": await runIndex(options)
case "list": await runList(options)
case "search": await runSearch(options)
case "show": runShow(options)
case "resume": runResume(options)
case "parse": runParse(options)
case "scan": runScan(options)
default: fail("unknown command \(command)", code: 2)
}
