# Cursor ACP persisted-session support

1. Discover `~/.cursor/acp-sessions/<UUID>/store.db` without changing it.
2. Decode the documented root, turn, user-message, and assistant-message protobuf graph.
3. Namespace ACP row IDs, label their surface `ACP`, and exclude them from Cursor CLI resume.
4. Reject unknown sidecar schema versions, unexpected SQLite table columns, invalid blob IDs, and incomplete root/turn references instead of indexing partial records.
5. Cover the graph decoder with a synthetic SQLite fixture that includes an unreachable sensitive blob and an unknown-schema rejection case.
6. Build and run the targeted parser test.

Out of scope: `session/load`, ACP client control, tool payload indexing, encrypted or unknown blob decoding, and writing Cursor storage.
