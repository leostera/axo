# axo-mcp

`axod mcp`: one Session's agent reaching axod as an MCP server over stdio (RFD0015). Pi starts it for its Session (pi-axo registers it). Each tool is an `axo.*` method on `axod.sock`, one connection per call, and tool calls run side by side (at most 16 at once).

It is a client of the socket and knows nothing of axod's insides (RFD0034): computer use runs here, in this process, through `axo-computer` and its risk gate (`axo_computer::gate`), and `request_input` is axod's to answer.

## Build and test

```sh
bazel build //crates/axo-mcp
bazel test //crates/axo-mcp:axo_mcp_tests
```

Every tool it offers is called against a real axod in `//crates/axod:conformance_mcp`.
