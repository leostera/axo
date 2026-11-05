# axo-protocol

Axo's wire protocol: the identifiers, records, events, and RPC parameters and results axod exchanges with local clients and the cloud relay. The JSON shapes are fixed by [`schemas/axo.leostera.dev/v1`](../../schemas/axo.leostera.dev).

Every type is parsed at the boundary: deserializing one establishes its invariants (IDs are valid, layouts are well-formed trees, attachments have safe names), so code holding a value never checks again. RPC parameters reject unknown fields.

| Module | Owns |
| --- | --- |
| `ids` | `SessionId` (UUID, RFD0017) and `ShellId` (positive, never reused) |
| `model` | Sessions, panes, Workspaces and configuration as clients see them |
| `layout`, `viewport` | Pane layouts (a binary tree of splits) and the grid each pane gets, computed as the Mac client does |
| `rpc` | Local JSON-RPC method names, parameters and results; `method::ADVERTISED` |
| `event` | Events axod publishes to subscribers and the relay |
| `parity` | What each local method becomes when reached through the relay; a test fails when a method has no decision |
| `relay`, `elicitation`, `asset` | Relay status, elicitations (RFD0029), attachments (RFD0030) |
| `base64` | Base64 for terminal bytes, bounded and canonical on input |
| `conformance` | Tests that these types match the published schema and its fixtures |

## Build and test

```sh
bazel build //crates/axo-protocol
bazel test //crates/axo-protocol:axo_protocol_tests
```
