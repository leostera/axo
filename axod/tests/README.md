# axod test coverage

Tests use owned disposable directories/processes, not live Mac state or deployment credentials. Pi-owned execution/history, native rendering and physical-device acceptance are separate gates.

## Rust domain and process tests

From `axod/`:

```sh
cargo test --locked --offline
cargo clippy --locked --offline --all-targets -- -D warnings
```

These cover typed boundaries, runtime/work receipts, corruption/persistence fencing, private files, real PTYs, attachment/input/resize, slow readers, final output, descendants and stopped/recovery states. The `tests/fixtures/` programs are process fixtures, **not fake Pi sessions**.

## Property/fuzz and commit-window hardening

```sh
npm --prefix protocol run test:properties
```

The normal protocol and Rust test commands also include these tests. `fast-check` runs three replayable seeds (4282447, 20261011, 12648430): 6,000 malformed/structured codec cases, 1,500 read-admission cases, and generated notification/oversized-response batches. The development-only `axod/examples/rpc-oracle.rs` calls the actual Rust decoder and dispatcher, with an explicit read-only method allowlist, private disposable state, bounded input and owned-child teardown. It is not an installed daemon endpoint, surrogate Pi harness or execution test.

Replay a reported seed/path for one property from `protocol/`:

```sh
npm run build
AXO_PROPERTY_SEED=4282447 AXO_PROPERTY_PATH=0:1 \
  ./node_modules/.bin/tsx --test --test-name-pattern='seeded malformed-input' tests/property.test.ts
```

Diagnostics report seed/path and mismatch location, not generated payload bodies. Shrinking is enabled. The synthetic edge corpus covers UTF-16 IDs/methods, UTF-8 frame bytes, lone surrogates, non-finite JSON numbers, nesting, prototype-like dictionary keys, strict case-insensitive RFC UUIDs, cursor domains and numeric spellings such as `1.0`/`1e0`. Selected regressions also run through both real WebSocket routes.

Rust `proptest` exercises bounded UTF-8 input, exact IEEE-754 round trips, encoded-byte and post-dispatch reply bounds. A real filesystem state machine generates create/rename/reconcile/conflict/restart sequences and checks revision continuity, immutable original receipts, reconstruction and absence of runtime launch records. It runs 96 sequences of up to 39 actions per invocation; generated identities/state remain fixture-owned.

Test-only, thread-local hooks inject failures before file sync, before atomic rename and immediately after rename. The store must fence memory, retain known receipt reads and reject further mutations; reopening observes only the old or new atomic record/receipt pair. Exhaustive byte truncation of a synthetic store and individual receipt-invariant corruption must reject startup, never regenerate empty state. Ownership contention is distinguished from corruption; only disposable test roots may briefly wait for inherited CLOEXEC locks during parallel PTY forks. Production ownership acquisition remains fail-closed, with no command retry.

**Evidence limits:** injected post-rename failure and same-kernel reopen do not prove power-loss durability or actual directory-fsync recovery. This is bounded generated testing, not coverage-guided libFuzzer, exhaustive correctness, production hardening, orphan containment or a fix for every compiler/Worker contention stall. Abrupt death at process/spawn/fsync boundaries, escaped descendants, soak/resource-exhaustion campaigns and native/Pi acceptance remain open.

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
