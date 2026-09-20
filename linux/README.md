# Agent Sessions for the terminal (experimental)

A terminal UI to browse, search, read, copy and resume the local sessions of your coding
agents. It reads the same session files as the macOS app, through the same parsers and
search index, and never sends anything off the machine.

Supported sources: Codex, Claude Code, Antigravity, OpenCode, Hermes, GitHub Copilot CLI,
Droid, OpenClaw, Cursor, Pi, Kimi Code, Grok CLI, Qwen Code, Devin, fx and Cline. A source
shows up only if its session files exist for your user.

Linux locations of Cursor, Cline Desktop, Antigravity and Devin have not been verified yet
(the app's macOS paths are used); Codex, Claude Code, OpenCode and the other CLI sources
follow their documented `~/.<agent>` layouts and are tested.

## Install

| Format | Command | Installed files |
|---|---|---|
| `.deb` (Debian, Ubuntu) | `sudo apt install ./agent-sessions_<version>_<arch>.deb` | `/usr/bin/agent-sessions`, `/usr/lib/agent-sessions/agent-sessions-core` |
| `.rpm` (Fedora, RHEL, SUSE) | `sudo rpm -i agent-sessions-<version>.<arch>.rpm` | `/usr/bin/agent-sessions`, `/usr/libexec/agent-sessions/agent-sessions-core` |
| tarball | unpack anywhere | `agent-sessions` and `agent-sessions-core` side by side |

Only `agent-sessions` goes on your `PATH`. `agent-sessions-core` is its internal engine and
is found automatically: next to the program, then in `../libexec/agent-sessions`, then in
`../lib/agent-sessions`, then on `PATH`. `$AS_CORE` overrides all of that. To install a
tarball for everyone:

    sudo install -m 0755 agent-sessions /usr/local/bin/
    sudo install -m 0755 -D agent-sessions-core /usr/local/libexec/agent-sessions/agent-sessions-core

Nothing else is required: the Swift runtime and SQLite are linked in, so the binaries need
only glibc and libstdc++. Builds exist for `x86_64` (`amd64`) and `aarch64` (`arm64`).

The program is called `agent-sessions`, not `as`, because `as` is the GNU assembler.

## Use

    agent-sessions

| Key | Action |
|---|---|
| up, down, k, j, PgUp, PgDn, g, G | move through sessions |
| Enter, Tab | read the session (Tab again returns to the list) |
| `/` | full-text search; Enter runs it, Esc cancels; Esc in the list clears it |
| `s` | cycle the source filter |
| `o` | open the session in its agent: the UI exits and runs the agent's resume command in the session's project directory |
| `y` / `Y` | copy the resume command / the session file path to the clipboard |
| `r` | refresh the index |
| `q` | quit |

Notes:

- The list shows top-level sessions. Subagent runs, such as Codex auto-review, are hidden.
- The first start indexes your history, which can take minutes for gigabytes of Codex
  rollouts. The list fills in as sessions are found (the status line counts them), and
  quitting stops the indexer; what it already stored is kept and the next start continues.
  Later starts only read what changed and take well under a second.
- Resume works for Claude Code, Codex, OpenCode and Copilot CLI. For other sources `o` and
  `y` report that they cannot be resumed yet; `Y` still copies the file path.
- Copying uses the OSC 52 terminal sequence, so it also works over SSH. Terminals that do
  not implement it ignore it; the copied text is always shown in the status line.
- `agent-sessions --core-path` prints which engine binary is in use, which is the first
  thing to check if the program reports that the engine is missing.

## Where data lives

The index is `$XDG_DATA_HOME/agent-sessions/index.db` (default
`~/.local/share/agent-sessions/index.db`), one per user. It is a cache: deleting it only
costs a re-index. It is separate from the macOS app's index. Set `$AS_CORE_DB` to move it.

## The engine, for scripts

`agent-sessions-core` prints one JSON object per line on stdout (every object carries
`"schema": 1`) and logs to stderr. Run it through its installed path, since it is not on
`PATH`, for example `/usr/lib/agent-sessions/agent-sessions-core` on Debian.

    agent-sessions-core sources                       sources this build can read
    agent-sessions-core index [--source s]            build or refresh the index
    agent-sessions-core list [--source s] [--limit n] [--include-subagents]
    agent-sessions-core search <query> [--source s] [--limit n]
    agent-sessions-core show <source> <file> [--id id]      header plus every event
    agent-sessions-core resume <source> <file> [--id id]    the command that reopens it
    agent-sessions-core parse <source> <file>         one-file summary, no index
    agent-sessions-core scan [--source s] [--light]   discover and parse, no index

Common option: `--db <path>`. Database-backed sources (OpenCode, Hermes, Devin) share one
storage path, so `show` and `resume` take `--id`.

## Uninstall

    sudo apt remove agent-sessions        # Debian, Ubuntu
    sudo rpm -e agent-sessions            # Fedora, RHEL, SUSE

Remove `~/.local/share/agent-sessions` to delete the index.

## Build from source

`./linux/package.sh arm64|amd64 [version]` builds the tarball, `.deb` and `.rpm` into
`dist/`. It needs Docker (for the Swift engine, built in a Linux container) and Go (for the
UI, and to cross-build `nfpm`, which writes both package formats). The other architecture is
built under emulation, which is slow on the first run.

`python3 scripts/as_core_contract.py` parses every fixture in `Resources/Fixtures` with the
engine and compares against a committed golden, to catch parser drift between platforms.
