# axo-mcp

The MCP server for one Session's agent (RFD0015), running inside axod (RFD0034). Pi starts
`axod mcp` for its Session (pi-axo registers it). `axod mcp` opens `axo.mcp.open {sessionId}` on
axod's socket; axod hands that connection to this server, and from then on `axod mcp` only copies
bytes between stdio and the socket.

Each tool is an `axo.*` method, called in process through `axo_ipc::Local` as the connection's
peer, so the same caller checks apply as on the socket. Tool calls run side by side (at most 16
at once). Giving up a call (`notifications/cancelled`), or the agent leaving, fires the
cancellation of what it waits on. Computer use runs in axod through `axo-computer` and its risk
gate (`axo_computer::gate`, one per process, shared with other Macs' calls). `request_input` is
answered by `axo-computer-use`.

When axod restarts, the connection ends and `axod mcp` exits; Pi reconnects on the next call.

## Build and test

```sh
bazel build //crates/axo-mcp
bazel test //crates/axo-mcp:axo_mcp_tests
```

Every tool it offers is called against a real axod, through the real `axod mcp`, in
`//crates/axod:conformance_mcp`.
