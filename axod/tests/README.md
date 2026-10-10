# axod test coverage

Tests use owned disposable directories/processes, not live Mac state or deployment credentials. Pi-owned execution/history, native rendering and physical-device acceptance are separate gates.

## Rust domain and process tests

From `axod/`:

```sh
cargo test --locked --offline
cargo clippy --locked --offline --all-targets -- -D warnings
```

These cover typed boundaries, runtime/work receipts, corruption/persistence fencing, private files, real PTYs, attachment/input/resize, slow readers, final output, descendants and stopped/recovery states. The `tests/fixtures/` programs are process fixtures, **not fake Pi sessions**.

## Actual daemon RPC tests

From the repository root:

```sh
npm --prefix sites/api.axo.leostera.dev run test:axod
```

This builds the compiled `@axo/protocol` package, checks schema drift and runs:

- `tests/axod.test.ts`: two real daemon owners behind an Access-validating isolated Worker; process launch/reconciliation, independent machines, disconnect/cloud loss, restart and Swift wire fixtures.
- `tests/local.test.ts`: real local discovery/WebSocket admission, negotiation, codec/credits/bounds, launch receipts, paging and recovery.
- `tests/work.test.ts`: positive paths for every implemented workspace/session/receipt RPC on both actual local/cloud routes, stable records, manual names, cursor/source fencing and restart durability.
- `tests/daemon-rpc.test.ts`: an exhaustive method-input matrix for every shared exposed daemon RPC. Typechecking requires a case whenever `RemoteMethod` grows. Each method exercises positional/missing/extra/malformed input, stale machine/source and non-executing notifications on both routes.

The method suite also checks concurrent command/hop-ID collisions, revision winners/losers, original receipt reconciliation, per-route uncertain persistence and global mutation fencing, absent-versus-null paging semantics, legitimate nullable cursor scopes, explicit null request IDs and maximum Unicode pages within encoded-byte budgets.

The RFD catalogue is used to exercise **explicit unsupported errors** for methods not implemented yet. This is not positive Pi/chat/terminal coverage. Adding a real capability requires both a typed matrix case and actual positive/failure/lifecycle evidence; do not replace it with a fake handler or invented transcript.

Local and cloud transport policies may differ; shared domain semantics must not. For example, optional paging fields may be omitted but not explicitly null unless their schema is nullable. A missing command receipt means unknown knowledge, never safe replay or confirmed rejection.

The dedicated command serializes test files to bound compiler/Worker fixture contention; its concurrent-client cases still send real simultaneous requests. The complete API suite remains available with `npm --prefix sites/api.axo.leostera.dev test`; it additionally tests service JWT roles, directory admission, hibernation/deadlines and relay recovery. Tests deliberately respect ingress/credit limits rather than disabling guards, and cleanup signals only owned child handles.
