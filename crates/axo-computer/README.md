# axo-computer

Native computer use embedded in `axod`, for local MCP tools and remote account scripts. Cua's macOS platform uses Axo's Accessibility/Screen Recording grants; its Linux platform uses X11, AT-SPI and compositor-dependent Wayland capabilities.

- `TOOLS` is the 24-tool allowlist. Excluded tools are removed from the registry, not just hidden from schemas, so scripts and batches cannot reach them.
- `tool_definitions()` returns MCP definitions; `call(tool, args)` returns the tool's JSON result.
- A dedicated two-worker runtime starts lazily and stays off axod's socket/session runtime.
- Every driver dispatch, including nested script/batch calls, checks the desktop lock. Linux requires one active, explicitly unlocked graphical logind session for the current user; unknown state refuses.
- Registry initialization never starts a nested compositor, overlay or telemetry. Linux Wayland requires explicit opt-in and the graphical session's environment.
- Linux `request_input` remains unavailable: secure field/origin attestation is macOS-only. Unsupported platforms have no tools.

`gate` determines which actions need the person's agreement (RFD0029): a word filter, then Clef through `axod-infer` for flagged actions. The caller asks the person; the agent cannot approve itself. The native lock/allowlist checks are additional boundaries, not a substitute for the gate or authorization.

See [`linux/README.md`](../../linux/README.md) and [RFD0053](../../docs/rfds/RFD0053-linux-computer-use.md) for compositor limitations and acceptance tests. GNOME 50's unsafe WinRects helper is deliberately refused, not patched around.

## Build

```sh
bazel test //crates/axo-computer:axo_computer_tests
```
