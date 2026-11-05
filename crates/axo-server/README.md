# axo-server

The daemon itself: `SessionManager` and everything it orchestrates, the local JSON-RPC methods on `axod.sock`, the relay adapter, and `axod mcp`. The `axod` binary only parses arguments and calls `serve_ipc`.

It has no SQL outside its tests (that is `axo-store`), launches processes through `axo-pty` and `axo-pi`, and tracks panes with `axo-panes`.

## Layout

| Module | Owns |
| --- | --- |
| `lib.rs` | `serve_ipc`: the server directory, PID file, socket, signal handling, relay startup and the methods that are not the session's |
| `session` | `SessionManager`, `open`/`shutdown` and the shared state. Each module under `session/` adds its part of `impl SessionManager`: `catalog`, `handlers`, `events`, `terminal`, `prompts`, `lifecycle`, `spawn`, `workspaces`, `pi_bridge`, `pi_recovery`, `settings`, `elicitations`, `peer_views`, `cloud_transcripts`, `transcripts`, `workspace_state` |
| `mcp` | `axod mcp`: one Session's agent reaching axod as an MCP server over stdio (RFD0015) |
| `computer_gate` | The risk gate in front of computer use (`axo-computer`) |
| `connections` | `axo.connections.*`, forwarded unchanged to the account over the relay (RFD0016) |
| `permissions` | The macOS privacy permissions (TCC) that Sessions need |
| `workspace_access` | Security-scoped bookmarks for Workspace folders on macOS |

The runtime and attachment invariants, and what each `session` module owns, are in [`crates/axod/README.md`](../axod/README.md).

## Build and test

```sh
bazel build //crates/axo-server
bazel test //crates/axo-server:axo_server_tests
```

The end-to-end RPC tests against a real `axod` are `//crates/axod:rpc_tests`.
