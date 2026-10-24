# Axo correctness, performance and readability refactor

Status: approved with review feedback (2026-10-24). Applies the leo-code skills: readability, review-invariants, parse-dont-validate,
thinking-with-types, legacy (clean cutovers) and observability.

## Guardrails

- **Contracts stay fixed.** Wire schemas (`schemas/axo.leostera.dev/v1`, checked by
  `npm run -s schema:check`), the SQLite database, attach protocol v2, Pi transcripts and
  user-visible behavior. Internal names, files and module boundaries may change freely.
- **Clean cutovers.** No wrappers, aliases or duplicate paths left behind (leo-code-legacy).
- **Move-only commits first, semantic commits second**, so every behavior change is reviewable on
  its own. Each commit keeps the full test command, Clippy, warnings-free Swift and the schema
  check green.
- **Measure before and after** every performance claim (AxoTrace logs, the axod load test).
- Packaging as usual; no live restarts of your Axo/axod.

## Phase 0: baseline and safety net

1. **axod load test** (agreed earlier): `//crates/axod:loadtest`, a smoke profile as a Bazel test
   and a heavy profile via `bazel run`. Probes: `session.list`, `shell.create/close`, resize,
   `layout.set`, `shell.busy`, input, attach, event fan-out; background catalog/stream
   subscribers, output floods and attach churn. Reports p50/p95/p99/max, lag, threads, fds, RSS.
   Pass: control-plane p99 < 10 ms with no errors.
2. **Raise axod's `RLIMIT_NOFILE`** at startup (launchd defaults to 256; every shell costs ~4 fds).
3. **Slow-request log** in `ipc.rs`: one structured warn line for any request over 100 ms, with
   method and elapsed time. With AxoTrace this makes every latency report attributable.

## Phase 1: axod (`crates/`)

`session.rs` is 9,226 lines: a 2,433-line `SessionManager` impl, ~3,000 lines of free functions
and ~2,400 lines of tests.

### 1a. Split into crates, then modules

Anything that encapsulates cleanly becomes its own workspace crate with its own tests (Bazel
`rust_library` + `rust_test`; no new third-party crates needed):

| Crate | Owns |
| --- | --- |
| `axo-protocol` | Wire types only: IDs, `PaneRole`, `SessionLayout`, metadata records, typed RPC params/results and events (serde). Shared by axod, the load test and future clients. |
| `axo-pty` | Opening PTYs, launching a child on one (shared by shells and Pi), the permanent output pump, fan-out subscribers, and attach protocol v2 (server and client). |
| `axo-ipc` | Newline-delimited JSON-RPC over a Unix socket (today's `ipc.rs`) and `EventQueue`. |
| `axo-store` | All SQLite: schema/migrations, sessions, panes, workspaces, Pi bindings, config. |
| `axo-relay` | The cloud relay (today's `relay.rs`). |
| `axo-server` | `SessionManager` orchestration: catalog state, pane lifecycle, Pi bridge and recovery, RPC handlers. Split into modules (`manager`, `lifecycle`, `pi_bridge`, `recovery`, `events`, `rpc`). |
| `axod` | The binary and the `terminal-attach` CLI. |

Tests move next to the code they test.

### 1b. Parse at the boundary, type the domain

Parse, don't validate, everywhere. `serde_json::Value` and `json!` are a code smell: every
payload is a struct or enum deriving `Serialize`/`Deserialize`. `Value` survives only where
`jsonrpc_core`'s handler signature forces it, converted to a typed value on the first line.

- **Typed RPC params.** Each method deserializes a serde struct (`SessionShellParams`,
  `ResizeParams`…) once, replacing ~36 `value.get(..).as_i64()` lookups across `session.rs` and
  `relay.rs`. Unknown fields stay tolerated (wire compatibility); missing or invalid ones fail
  with the same error codes.
- **Typed events.** `enum CatalogEvent` / `enum StreamEvent` with `#[serde(tag = "type")]`
  replace ~100 `json!` construction sites. `EventScope::accepts` becomes a property of the
  variant, not a string match. Fixtures stay byte-compatible (schema check).
- **Pi bridge state machine.** The `phase` integer (0/1/2) becomes `enum BridgePhase
  { AwaitingAuth, AwaitingHello, Bound { pi_session_id } }`, so events before binding are
  unrepresentable.
- **Pane lifecycle state machine.** One `PaneState` per shell ID (e.g. `Launching`, `Running`,
  `Unavailable`, `Recovering`, `Stopping`) with transitions as the only way to change it, so
  "running and unavailable at once" can't be represented. Pure transition function, tested
  exhaustively (every state × event, including illegal transitions and stale runtime IDs);
  effects (spawn, kill, publish) run outside it.

### 1c. Correctness

- **New-session creation outside the catalog lock** (open item in
  `docs/axod-recovery-hardening.md`): reserve under the lock, spawn outside it, commit or roll
  back under it, like Pi recovery already does.
- Remove the remaining non-test `unwrap`/`expect`s, or document why each cannot fail.
- One stop path for shells (close, archive, shutdown, recovery) with a single timeout policy.

## Phase 2: Swift app (`apple/`)

The same style rules as Rust: enums and structs for domain values, never strings or loose
booleans; parse wire data into domain types at the boundary.

### 2a. Swift packages for reuse (iOS, watchOS, …)

| Package | Contents | Platforms |
| --- | --- | --- |
| `AxoProtocol` | Wire models, IDs, events, params; `Codable`, no I/O | all |
| `AxoClient` | Persistent JSON-RPC connection, typed calls, event stream, `TerminalAttachment` | all with Unix sockets (macOS now; remote transport later) |
| `AxoDaemonManager` | LaunchAgent registration and health | macOS |
| `AxoTerminal` | Ghostty runtime, surfaces, input policies | macOS |
| `AxoMac` | App, scenes, workbench, settings | macOS |

### 2b. Types

- `TerminalShell.role: String?` → `PaneRole` enum (`role == "pi"` is compared in 6 places).
- `available: Bool?` + `availabilityReason: String?` → `PaneAvailability { available,
  unavailable(reason) }`. The focus bug just fixed came from availability checks scattered across
  the model.
- Event and method names stay inside `AxoProtocol`; nothing else matches on strings.
- `TerminalAttachment` keeps descriptor ownership explicit (owned type, single close).

### 2c. Split `TerminalSessionsModel` (924 lines)

- `SessionCatalog`: sessions, workspaces, applying events and snapshots.
- `WorkbenchSelection`: selected session, focused pane, layouts, navigation. One rule for what is
  focusable.
- `SessionCommands`: create/close/split/rename/archive/restart, applying Axod's returned records.
- Confirmations become their own small types instead of optional properties plus cancel methods.

### 2d. Views and runtime

- `TerminalWorkbenchView` (460 lines): extract `ExpandedSidebar`, `CollapsedSidebar` and
  `WorkbenchDialogs`. No business logic in view closures.
- `GhosttyRuntime` (468 lines): move surface lifecycle (attach, adopt, reattach, free) into
  `TerminalSurfaceRegistry`; the runtime keeps libghostty app/config/callbacks.
- `UnixSocketRPC` (482 lines of near-identical methods): table-driven method descriptors.

### 2e. Performance

Phase 2 moved ahead of the rest of Phase 1: measured axod forwarding (attach echo p50 113 µs,
p99 274 µs) is not where the felt lag is.

- **Done (`447c858`):** hidden surfaces follow window geometry only after it holds still for
  150 ms, instead of reflowing (and SIGWINCHing every hidden program) on each fullscreen or
  window-drag animation frame.
- **Done (`d046f2e`):** Pi status/name updates no longer invalidate the terminal area. The model
  projects `shellsByID`, `sessionLayouts` and `hasSessions`; the sidebar is its own view.
- **Persistent RPC connection: deferred.** Measured with the Swift client against axod, a whole
  call including `NWConnection` setup and teardown is p50 0.28 ms, p99 0.70 ms (200 sequential
  `axo.health` calls). It is not a latency problem; it stays as groundwork for push events.
- Profile the ⌘W and new-session paths with the AxoTrace data from build 144, and fix what it
  shows.

### 2f. Observability

- **Done (`46b27f5`):** main-thread stalls (`event=main.stall`, run-loop observer), delayed
  libghostty ticks (`event=ghostty.tick_delayed`) and late key delivery
  (`event=key.delivery_delayed`), category `latency`, plus `key.down`/`ghostty.tick`/`main.busy`
  signposts.
- Turn AxoTrace into `OSSignposter` intervals for commands (key → RPC → UI applied), so they show
  in Instruments too. Bounded fields only: no paths, names or terminal content.

## Phase 3: contributor docs and skills

The skills in `.agents/skills` are for building and contributing to Axo, not for using it. Update
`axo-macos-native-apps` (it still says surfaces use the `terminal-attach` helper) and
`axo-macos-packaging` to the new crates, packages and architecture, plus `crates/axod/README.md`
and the audit docs.

## Out of scope

- **TypeScript** (`packages/axo-api-worker`, `axo-web-app`): skipped for now.
- **Terminal state snapshots** to replace the 8 MiB raw replay cap.

## Decisions

- Order: Phase 0, Phase 1 (axod), Phase 2 (app), Phase 3 (docs).
- The persistent RPC connection is deferred: per-call connection cost is measured at 0.28 ms p50.
- Phase 2 (app) runs before the rest of Phase 1: the felt lag is in the app, not axod.
- Load-test pass bar: control-plane p99 < 10 ms.
