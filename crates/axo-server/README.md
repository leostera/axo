# axo-server

The daemon itself (RFD0041): a task per open Session, the services beside them, the local JSON-RPC methods on `axod.sock`, the attach socket, and the relay adapter. `axod mcp` is `axo-mcp`; `axo.apps.*` is the `axo-apps` extension and `axo.assets.fetch` the `axo-assets` one. The `axod` binary only parses arguments and calls `serve_ipc`.

It has no SQL outside its tests (that is `axo-store`, reached through `tokio-rusqlite`), and launches processes through `axo-pty` and `axo-agent`. Everything runs on one tokio runtime; blocking work runs on its blocking pool.

## Layout

| Module | Owns |
| --- | --- |
| `lib.rs` | `serve_ipc`: the server directory, PID file, socket, signal handling, relay startup, and `open_core`. `rpc_handler` assembles axod's methods from its extensions (`daemon`, `relay`, `sessions`, `remote`, `axo_apps::Apps`, `axo_assets::Assets`, `axo_questions::QuestionsExtension` and `axo_computer_use::ComputerExtension`); a method two of them register stops axod at startup |
| `core` | `Core`: what every part shares (store, events, catalog, registry, settings, viewport, the lifeline) and the services that are no one Session's: questions, computer use, the input key, assets, git state, other Macs |
| `session` | One Session's task: its panes, its Pi (`session/pi`: launch, link, restart, kill at boot), prompts waiting for that Pi, its record (`session/record`), Pi events (`session/controls`) |
| `sessions` | What spans Sessions: the registry, restoring at boot, create, import, `/resume`, reopen, prompts, readiness, stopping |
| `catalog` | The open Sessions as a `watch` channel, written by each Session's task |
| `store`, `events` | The SQLite connection's thread; events on `broadcast` |
| `handlers`, `remote`, `ops` | Local methods, the account's `axo.remote.*`, and what both do |
| `attachments`, `event_stream` | The attach socket; pushed events |
| `relay_host` | `RelayHost` for the relay, and archived transcripts in the cloud |
| `peers` | Other Macs' Sessions on this one |
| `permissions` | The macOS privacy permissions (TCC) that Sessions need |

The runtime and attachment invariants, and what each `session` module owns, are in [`crates/axod/README.md`](../axod/README.md).

## Build and test

```sh
bazel build //crates/axo-server
bazel test //crates/axo-server:axo_server_tests
```

The end-to-end RPC tests against a real `axod` are `//crates/axod:rpc_tests`.
