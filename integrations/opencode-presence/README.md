# OpenCode live-session presence

The local OpenCode 2.x TUI plugin reports the client's exact selected session ID and
its native `running`/`idle` state to Agent Sessions. It works independently of the
terminal host. It reads no transcript content, calls no model and makes no network
requests. One private JSON heartbeat per client is written atomically under
`~/Library/Application Support/AgentSessions/Presence`. Home clears the session ID;
cleanup removes that client's file. Agent Sessions rejects dead or expired clients.

Agent Sessions bundles the complete ESM package in `Contents/Resources/OpenCodePresence`.
At app launch and every five seconds, its integration manager installs or updates
`<OpenCode config>/plugins/agent-sessions-presence/`. No separate installation,
Node/Python runtime, download or `cli.json` edit is needed. OpenCode 2.1.2 discovers
and reloads the package in running standard TUI clients. An explicit OpenCode plugin
disable remains effective. Other plugins and configuration bytes are preserved.
The TUI discovery and route/status APIs are source-verified in 2.0.0 and 2.1.2;
the 1.19.0 server plugin scan does not recurse into this nested package. The
integration does not add a top-level server-plugin shim.

Default configuration, XDG roots and `OPENCODE_CONFIG_DIR` are supported. The manager
retains only configuration/storage paths from the environments of running, owner-owned
OpenCode processes, so terminal-specific roots work even when Agent Sessions was
launched from Finder. Profiles are remembered for later removal. Preferences →
OpenCode shows integration status or installation errors and the Desktop limitation.
The session catalog retains its existing Sessions Directory setting for alternate
data stores; configuration/service discovery does not merge unrelated databases.

Each managed package has an ownership/hash manifest. Updates exchange complete
directories atomically; previous packages are retained in Agent Sessions' application
support directory. Modified packages, symlinks and unrelated files are preserved and
reported. Turning off OpenCode or live-session detection moves only the unmodified,
owned package out of discovery; turning it back on reinstalls it automatically.
Deleting Agent Sessions from Finder does not run an uninstaller: disable OpenCode
live detection before removing the app to retire the package.

`AgentSessions/Resources/OpenCodePresence` is the single distributable source.
Run `node --test integrations/opencode-presence/presence.test.mjs` for exporter tests;
`OpenCodePresenceIntegrationTests` covers packaged resources, fresh-user automatic
setup, custom roots, updates, removal and preservation. The Python script is a legacy
developer-only explicit-registration installer; the app never invokes it.

Agent Sessions separately reads OpenCode's local shared service for exact working
session IDs. That covers terminal and packaged desktop execution. Stock OpenCode
2.1.2 does not expose desktop's selected-but-idle conversation through a public
client API or an installable renderer extension, so no idle desktop presence is
inferred from timestamps, persisted tabs or titles.

Source contracts verified against OpenCode v2.1.2:
- [TUI current route and tab API](https://github.com/anomalyco/opencode/blob/v2.1.2/packages/plugin/src/tui/context.ts#L490-L529)
- [TUI current session status](https://github.com/anomalyco/opencode/blob/v2.1.2/packages/plugin/src/tui/context.ts#L69-L75)
- [Live plugin reconciliation](https://github.com/anomalyco/opencode/blob/v2.1.2/packages/tui/src/plugin/context.tsx#L527-L538)
- [Drop-in discovery](https://github.com/anomalyco/opencode/blob/v2.1.2/packages/tui/src/plugin/discovery.ts#L8-L49)
- [Service active-session semantics](https://github.com/anomalyco/opencode/blob/v2.1.2/packages/protocol/src/groups/session.ts#L210-L219)
- [Desktop renderer-extension limitation](https://github.com/anomalyco/opencode/blob/v2.1.2/packages/app/src/runtime/extension/root.tsx#L39-L44)
