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
  - **Done (`8630607`):** `panes.rs` keeps every pane in one `Panes<P>` table:
    `Pane::Running(P) | Pane::Unavailable(UnavailablePane)`, recovery
    `Recovery::Idle | InProgress(RuntimeId)`. Transitions (`insert_running`, `process_exited`,
    `begin_recovery`, `release_recovery`, `commit_recovery`, `remove`, `drain`, …) are the only
    way to change a pane, each tested from every state. `Launching` and `Stopping` are not
    states yet: spawns run under the lock (see 1c) and stops run after removal.
- **Done (`9fa74d4`, `d503b85`):** `PiCatalogEvent::parse` replaces string matching on Pi events;
  `StoredLifecycle` parses session state in `/resume`.

### 1c. Correctness

- **New-session creation outside the catalog lock: measured, deferred.** Creating a pane holds
  the lock ~2.8 ms on a quiet machine (fork + exec of the PTY child; 7–14 ms under the heavy load
  test), ~30× any other holder; build 160 logged no hold ≥ 50 ms in real use. Moving the spawn
  out saves at most that per pane, and a pane being spawned would not yet exist in `Panes`, so a
  concurrent close of the Session's last other pane would archive the Session under the split.
  Revisit with a `Launching` pane state if lock waits show up in `catalog.lock_wait_long`.
- **Done (`d503b85`):** `lock_state` is `#[track_caller]` and logs `catalog.lock_wait_long` /
  `catalog.lock_held_long` with the caller at ≥ 50 ms.
- **Done (`05db4b3`):** a Session's record is one cached query instead of four (listing 8
  Sessions: p50 99 → 21 µs).
- **Done (`b741c68`):** no panics left on daemon paths. `BridgeSocketPath` holds a `String`, so
  UTF-8 is a property of the type. The remaining non-test `expect`s are the build number from
  build metadata, clap's validated arguments, and the load-test tool.
- **Done (`48cc02f`):** one stop path, `stop_panes`, for close, archive, cancelled recovery and
  shutdown, with each pane's own grace; one cleanup worker per close instead of one per pane.
- **Done (`2b242e2`):** `store.rs` holds the schema, migrations and database-only reads and
  writes (a verbatim move; `session.rs` 7,250 → 6,554 lines).
- **Done (`2d2f1d9`, `954180a`, `d76003e`):** the 38 inline SQL calls became named store functions
  with their own in-memory tests; `session.rs` (6,216 lines) has no SQL outside its tests.
  Creating a Workspace Session is now one transaction.
- **Done:** `crates/axo-store` is its own crate. Settings parsing (`ShellCommand`,
  `AgentCommand`) and Workspace bookmark restore stayed in `axo-server`; the store returns raw
  values through `load_or_create_setting` and `open_workspace_directories`. `axo_store::open`
  owns the connection setup; `axo-server` uses rusqlite only in tests.
- **Done:** `session.rs` is split into modules under `session/` (`catalog`, `handlers`,
  `events`, `terminal`, `lifecycle`, `spawn`, `workspaces`, `pi_bridge`, `pi_recovery`,
  `settings`, `base64`), each with its own `impl SessionManager`. The parent keeps
  `SessionManager`, `open`/`shutdown` and the shared types (383 lines with their tests).
  Each module's tests sit next to it; shared fixtures are in `session/test_support.rs`. The
  three tests that exercised only the store (lifecycle parsing, two migrations) moved to
  `axo-store`.
- **1b is done:** the only `serde_json::Value`s left outside tests are the `data` arguments at
  the RPC boundary, parsed on the first line.
- **Later: Bazel test caching.** Bazel caches a test target as a whole, keyed on its binary, so
  per-test targets in one crate gain nothing. The payoff is smaller crates and test binaries
  with narrower dependencies (`axo-store`'s tests no longer rerun when `session.rs` changes),
  and splitting `TerminalWorkbenchE2ETests` (the 10 s critical path) for parallelism.
- **Test isolation (`aeaae49`, `48b12cd`, `97a971d`):** RPC tests no longer share a directory
  (microsecond timestamps collided), axo-server tests never start the user's login shell, and
  Swift daemon fixtures wait for `connect()`, not the socket file.

## Phase 2: Swift app (`apple/`)

The same style rules as Rust: enums and structs for domain values, never strings or loose
booleans; parse wire data into domain types at the boundary.

### 2a. Swift packages for reuse (iOS, watchOS, …)

| Package | Contents | Platforms |
| --- | --- | --- |
| `AxoProtocol` | Wire models, IDs, events, layouts, method names, protocol version; `Codable`, no I/O. **Done** (request structs stay in `AxoRPC`, which encodes them) | all |
| `AxoClient` | Persistent JSON-RPC connection, typed calls, event stream, `TerminalAttachment` | all with Unix sockets (macOS now; remote transport later) |
| `AxoDaemonManager` | LaunchAgent registration and health | macOS |
| `AxoTerminal` | Ghostty runtime, surfaces, input policies | macOS |
| `AxoMac` | App, scenes, workbench, settings | macOS |

### 2b. Types

- **Done (`9fa74d4`):** `TerminalShell.role: String?` → `PaneRole` enum, and
  `available: Bool?` + `availabilityReason: String?` → `PaneAvailability { available,
  unavailable(reason) }`, decoded so the reason is present exactly when unavailable.
- **Done:** event names are matched only in `TerminalSessionEvent`'s decoder and method names
  are spelled only in `AxodMethodName`, both in `AxoProtocol`.
- **Done:** `TerminalAttachment` owns both descriptors, with one idempotent `close()` and a
  `deinit`.

### 2c. Split `TerminalSessionsModel` (924 lines)

- `SessionCatalog`: sessions, workspaces, applying events and snapshots.
- `WorkbenchSelection`: selected session, focused pane, layouts, navigation. One rule for what is
  focusable.
- `SessionCommands`: create/close/split/rename/archive/restart, applying Axod's returned records.
- Confirmations become their own small types instead of optional properties plus cancel methods.
  (They are: `ShellCloseConfirmation`, `WorkspaceArchiveConfirmation`.)
- **Done:** commands stay on the model, because each one applies Axod's answer to the
  catalog, selection and errors, and a separate commands object would need all of them. Their
  decisions moved out and are tested without a daemon: `AxodCapabilities` (negotiation, typed
  `Set<AxodMethodName>`), `ShellCloseConfirmation.Reason(closing:busy:)`, `SessionClosePlan`,
  `WorkspaceArchiveConfirmation.stillApplies` and `PendingTerminalSplit.resize(to:)`
  (model 846 → 780 lines).
- **Done (`4b82070`):** `SessionCatalog`, a pure value whose `sessions` are sorted and unique by
  ID by construction.
- **Done (`9fa74d4`):** one layout store; `SidebarSections` replaces `sidebarOrder` (Sessions of
  an unlisted Workspace no longer vanish).
- **Done (`434b3a5`):** `WorkbenchSelection` is a pure value owning selection, focus, every
  layout and recent Sessions; the shown layout is derived, layout writes are collected and handed
  to `TerminalLayoutWriter`. Tested in `WorkbenchSelectionTests` without a model or daemon.

### 2d. Views and runtime

- **Done:** `TerminalWorkbenchView` is 191 lines; the sidebar is `WorkbenchSidebar` and
  `SessionSidebarRow`.
- **Done (`418f612`):** `TerminalSurfaceRegistry` owns surface lifecycle (presentation, attach,
  adopt, reattach, offscreen sizing, free); `GhosttyRuntime` keeps the libghostty app, config,
  callbacks and command routing (632 → 285 lines).
- **Done (`66d8d86`):** `UnixSocketRPC` is table-driven: `AxodMethodName` is the only place
  method names are spelled, `AxodMethod<Params, Result>` descriptors and one generic `call()`.
- **Done (`d477f1f`):** `ReattachThrottle` replaces `lastReattach`, so a stream ending twice in
  2 s reattaches later instead of freezing the pane.

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
- **Done:** `AxoTrace.beginInterval`/`endInterval` wrap each user command
  (`command.session.create|show|close`, `command.pane.split|close`, `command.pi.restart`,
  `command.workspace.create`) from request to the model applying Axod's answer; static names
  only. Read with Instruments, or `log show --signpost --predicate 'subsystem ==
  "dev.leostera.axo" AND eventType == "signpostEvent"'`.

## Phase 3: contributor docs and skills

**Done (this round):** `axo-macos-native-apps` (in-process attach, new types, fixture rules),
`axo-pi-title-and-attention` (status lives in `axo-pi`), and a crate map plus the stop path in
`crates/axod/README.md`.

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
