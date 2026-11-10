# RFD0034 - Axo: axod as an AXP Server with Extensions

- Feature Name: `axo-axod-as-an-axp-server`
- Status: Partially implemented (accepted provisionally 2026-11-07; see Current state). Steps 7 and 8 superseded by [RFD0037](RFD0037-axod-reactive-core.md), [RFD0041](RFD0041-axod-session-tasks.md) and [RFD0042](RFD0042-async-relay-and-extensions.md)
- Author: leostera
- Start Date: 2026-11-07
- Updated: 2026-11-10
- Document Type: Proposal
- Amends: [RFD0016](RFD0016-connections-and-tools.md), [RFD0029](RFD0029-ask-the-person.md)

## Summary

axod becomes a small AXP server (`axo-server`) plus extensions that know nothing about it. The server owns connections, trust, routing, events and cancellation. Every feature lives in an extension crate that registers methods behind one async API: Sessions, agent, terminal, connections, questions, computer use and assets. A request is the same request whether it arrives on the local socket, through the relay, or from `axod mcp`. So the relay's second dispatch table goes away, and every handler is told who is calling and when the caller has gone. The move happens one crate at a time. Before each step lands, a black-box conformance suite must stay green and coverage must not drop.

## Current state (2026-11-10, 0.49)

This section is the current contract. The Motivation and the step-by-step notes below are kept as the history of how axod got here. Where a step's notes describe a shape that later changed, they are marked as historical.

**Built:**

- **The MCP server in axod** (step 1, `crates/axo-mcp`). `axod mcp` opens `axo.mcp.open`, the connection is upgraded (`axo_ipc::Upgrades`, `axo_mcp::upgrade`), and tools call axod's methods in process through `axo_ipc::Local`. `axod mcp` itself is a byte copier on two threads (`serve_stdio`).
- **Per-method callers** (step 2, local half). `axo_ipc::peer::Caller` is `Signed(Signer)` or `Relay`. `TypedMethods::add_typed_only(Only { caller, .. })` refuses any other caller before parsing parameters. Since RFD0042, every typed handler is async, and `add_blocking_method` and the thread-local peer and cancellation hand-offs are gone.
- **Cancellation** (step 3). `axo_ipc::cancel` cancels a connection's unanswered requests when it closes. `axod mcp` cancels on `notifications/cancelled` or end of input. Questions, forwarded app calls and prompts waiting for Pi stop when cancelled. `specs/cancellation/questions.ts` models the questions part.
- **Extension registration** (step 4, partly). `axo_ipc::extension::Extension` has a name and `register(&mut IoHandler)`, with one owner per method. axod is assembled from `Daemon`, `Relay`, `Remote` and `Sessions` (in `axo-server`), and `Apps`, `Assets`, `QuestionsExtension` and `ComputerExtension`.
- **Extensions out** (step 5, partly). `crates/axo-apps`, `crates/axo-assets`, `crates/axo-questions` and `crates/axo-computer-use`.
- **The relay as a transport** (step 6). `crates/axo-relay/src/relay/forward.rs` forwards any `axo.remote.*` request whole to `RelayHost::answer_remote` and refuses everything else. The account's calls are ordinary async methods of the `Remote` extension in `crates/axo-server/src/remote.rs`, which admit only `Caller::Relay` and answer with the redacted remote views.
- **One runtime, no blocking bridges** (step 7, done another way). RFD0037, RFD0041 and RFD0042 replaced step 7's plan. axod runs on one tokio runtime. Sessions are tasks, SQLite is one `tokio-rusqlite` thread, `RelayHost`, `HostLinkStore` and `SyncStore` return boxed futures, and the blocking pool runs only synchronous OS and library work.
- **The Session manager split** (step 8, done another way). RFD0041 replaced `SessionManager`, `SessionState` and `AgentState` with a registry, one task per Session, a catalog `watch`, a `broadcast` event bus and stand-alone services. The split is by Session, not by owner as step 8 proposed.

**Accepted here and not built.** None of these is rejected, and nothing scheduled depends on them:

- `axo-server` becoming the transport and router core, with features in separate crates. Sessions, agent, terminal, connections and sync are still modules of `crates/axo-server`, and the relay transport is still `crates/axo-relay`. The step 8 notes defer the move until a second user needs one of them.
- The richer extension API: `Request<'_>` with `caller()`, `cancelled()`, `deadline()` and typed services, `Extension::start` for background tasks, `long_wait`, and concurrency limits declared on methods. Handlers still read the caller and cancellation from task-locals (`axo_ipc::peer::current`, `axo_ipc::cancel::current`). Relay job limits are still per-kind `JobLimit` semaphores in `crates/axo-relay/src/relay/jobs.rs`.
- `Caller::Device(DeviceId)` and `Caller::Agent(SessionId)`. The account is one `Caller::Relay`. Device proofs are checked only on remote answers to questions (`crates/axo-server/src/devices.rs`). An agent is known by the Session its `axo.mcp.open` named.
- The `axp` Rust crate (`axp/rust/` does not exist) and deleting `axo-protocol`. Both wait on the wire moving to AXP, which no RFD has scheduled.
- A fake hub in the conformance harness.

## Motivation

*Historical: axod as of 2026-11-07, before steps 1 to 8.*

axod works, but it has grown into shapes that make the next three steps hard: tokio throughout, ATXF everywhere, and push delivery.

- **One crate holds everything.** `axo-server` is 15.7k lines: the Session manager, the Pi bridge, terminals, Workspaces, elicitations, computer input, the MCP server, the computer-use gate and connections forwarding. `axo-relay` adds another 8.6k, and pulls in `axo-agent` and with it libghostty-vt. A change to the share flow rebuilds the terminal emulator's dependents.
- **Two API surfaces.** Local clients call 50 advertised JSON-RPC methods. The relay answers 13 `axo.remote.*` methods of its own (`crates/axo-relay/src/relay/dispatch.rs`). They reach the same code through `RelayHost`, a 36-function trait whose adapter is 305 lines (`session/handlers.rs`). Every feature that should work from the phone is written twice, and the two copies drift. Hub-routed bash, computer calls, attachments and sign-ins are special "jobs" with their own limits (`relay/jobs.rs`).
- **One lock.** `SessionManager` keeps a `Mutex<SessionState>` with 15 fields: the database, panes, Pi activity, queued prompts, the event bus, the viewport and more. That lock is taken in 138 places. `SessionManager` holds five more mutexes beside it. axod already logs `catalog.lock_held_long`. Nothing about the shape stops a slow SQLite write from stalling a terminal resize.
- **Threads with no owner.** 53 `thread::spawn`s across server, relay, agent and PTY, with blocking I/O, including the relay's WebSocket (tungstenite). Only `axo-ipc`'s transport is async.
- **Nobody knows when a caller leaves.** A question that an agent asks stays pending for its full five minutes after the agent's connection drops, and holds a blocking-pool thread the whole time (`conformance/elicitations.rs`, ignored test `an_asker_that_goes_away_withdraws_its_question`). `axod mcp` ignores `notifications/cancelled`. Connection forwarding waits up to 5½ minutes whatever the caller does.
- **Trust is checked inline.** Elicitations, computer input, redactions and assets each call `peer::current().is(...)` in their handler. Relay callers carry device proofs that are checked elsewhere. There is no one place that says who may call what.
- **`axod mcp` is a second process with a second JSON-RPC hop.** Every tool call is serialized twice. Its computer-use gate keeps state per process.

The conformance suite built for this RFD has already found what this costs. A Home Session could not be reopened when `$HOME` led through a symlink (fixed in `b26b88a`). Two of the Worker's end-to-end tests were in a Bazel target without axod, so `//packages/axo-api-worker:test` had been failing on main (fixed in `183b641`).

## Guide-level explanation

### The picture

```text
            local socket      relay (WebSocket)       axod mcp (stdio)
                 │                   │                      │
                 └─────────┬─────────┴──────────┬───────────┘
                           ▼                    ▼
                  ┌──────────────── axo-server ────────────────┐
                  │ transports · callers · router · events ·   │
                  │ cancellation · limits · logs                │
                  └──┬──────┬──────┬──────┬──────┬──────┬──────┘
                     ▼      ▼      ▼      ▼      ▼      ▼
                sessions  agent terminal questions computer connections assets …
                 (axo-ext-* crates: methods, events, background tasks)
```

A request comes in on some transport. The server works out who sent it (a **Caller**), finds the method's handler, checks that this caller may call it, and runs it with a **request context**. The context carries the caller, a cancellation signal that fires when the caller goes away, and handles to the services the extension asked for. The answer goes back on the same transport.

### Writing an extension

An extension is a crate that depends on `axo-server`'s extension API, not on the server:

```rust
pub struct Questions { pending: Pending }

impl Extension for Questions {
    const NAME: &'static str = "questions";

    fn register(&self, methods: &mut Methods<Self>) {
        methods.add("axo.elicitation.request", Self::request).callers(Callers::ANYONE);
        methods.add("axo.elicitation.list", Self::list).callers(Callers::ANYONE);
        methods.add("axo.elicitation.resolve", Self::resolve).callers(Callers::PERSON);
    }
}

impl Questions {
    async fn request(&self, cx: Request<'_>, ask: RequestElicitation) -> Result<Outcome, Error> {
        let asked_by = match ask.asked_by {
            Asker::ComputerUse if cx.caller().is_own_tool() => Asker::ComputerUse,
            Asker::ComputerUse => return Err(NOT_A_TOOL.into()),
            Asker::Agent => Asker::Agent,
        };
        let question = self.pending.open(&ask, asked_by)?;
        cx.events().publish(Event::ElicitationRequested { .. });
        tokio::select! {
            answer = question.answered() => Ok(answer),
            _ = cx.cancelled() => Ok(question.withdraw(Cancel)), // the asker went away
            _ = tokio::time::sleep(TIMEOUT) => Ok(question.withdraw(Cancel)),
        }
    }
}
```

- `Callers::PERSON` means Axo.app on this Mac (by code signature), or a signed device through the relay. The handler doesn't check it again.
- `cx.cancelled()` fires when the local connection closes, when the relay says the caller hung up, or when `axod mcp` receives `notifications/cancelled`.
- The same method answers the phone through the relay. There is no `axo.remote.*` twin.

### Who calls

```rust
pub enum Caller {
    /// On this Mac's socket, with its audit token: Axo.app, axod's own tools, or anyone else.
    Local(Peer),
    /// Through the relay: a device of the account, with its proof.
    Device(DeviceId),
    /// A Session's agent, through `axod mcp` for that Session.
    Agent(SessionId),
}
```

Today these checks are spread out: `peer::current().is(Signer::AxoApp)` in a handler, a device proof verified in `session/devices.rs`, and an agent known only by an environment variable. After this change a method declares who may call it, once, and the server enforces that.

## Reference-level explanation

### Crates

| Crate | Holds | Depends on |
|---|---|---|
| `axod` | The CLI: flags, logging, `mcp` and `terminal-attach` subcommands. Assembles the server from extensions. | everything below |
| `axo-server` | Transports (local socket, relay WebSocket, MCP stdio bridge), callers and trust, router, event bus, cancellation, limits, the extension API. Absorbs `axo-ipc` and the transport half of `axo-relay`. | `axp`, `axo-protocol` |
| `axo-ext-sessions` | Sessions, Workspaces, the catalog, layouts, settings, the viewport. | `axo-store`, `axo-panes` |
| `axo-ext-agent` | Pi panes: launching, the bridge, prompts, restarts, recovery, transcripts. | `axo-agent`, `axo-ext-sessions` |
| `axo-ext-terminal` | Terminal panes: PTYs, attach, input, screens. | `axo-pty`, `axo-vt`, `axo-ext-sessions` |
| `axo-ext-questions` | Elicitations, device-signed answers. | `axo-seal` |
| `axo-ext-computer` | The gate, `request_input`, redactions, hub-routed computer calls. | `axo-computer`, `axo-ext-questions` |
| `axo-ext-connections` | Forwarding to the account's connections; sign-ins. | `axo-signin` |
| `axo-ext-assets` | Fetching attachments and assets. | |
| `axo-ext-sync` | Uploading transcripts, following other Macs (RFD0018, RFD0022). Becomes the AXP log in the ATXF step. | `axo-agent` |
| `axo-mcp` | The MCP server: tool definitions, results for agents. A client of the router; no SessionManager. | `axo-server` (API only) |
| `axp` (new, `axp/rust/`) | Only real AXP types, checked against `axp/schema/`. | |

These stay as they are: `axo-agent`, `axo-computer`, `axo-pty`, `axo-vt`, `axo-panes`, `axo-store`, `axo-seal`, `axo-signin` and `axo-protocol`. `axo-protocol` carries today's wire until the ATXF step and is deleted after it. `axod-infer` and `axod-loadtest` remain deployment units. Crates may split further where that shortens builds. Crates don't need to match AXP's extensions one to one.

### The extension API

- `Extension::register(&self, &mut Methods<Self>)`: each method has a name, a typed parameters struct (`deny_unknown_fields`, as today), an async handler and its allowed callers. Methods may be marked `long_wait` (events, questions, forwarded calls), which exempts them from the slow-request warning.
- `Extension::start(self: Arc<Self>, cx: Background)`: optional background tasks (reapers, uploaders, followers), given a shutdown signal.
- `Request<'_>`: `caller()`, `cancelled()` (a `tokio_util::sync::CancellationToken` future), `events()`, `deadline()`, and typed `service::<T>()` handles that other extensions export.
- **Services, not internals.** An extension exports a trait, such as `Sessions` for open/list/close, and others use that. No crate reaches into another's state. This is how `axo-ext-agent` and `axo-ext-terminal` share panes without sharing a mutex.
- **Events:** a typed bus with today's two scopes (catalog and streams). Subscriptions, lag and per-Session filters stay as they are (`axo-ipc/src/event_queue.rs`).

### Transports and the relay

- **Local socket:** unchanged on the wire (`axo-protocol`). It becomes the server's first transport. `Caller::Local(peer)` comes from the audit token, as now.
- **Relay:** the WebSocket moves to tokio (`tokio-tungstenite`). Incoming `axo.remote.*` calls map onto the ordinary methods by a fixed table, inside the relay transport, with `Caller::Device`. Today's `dispatch.rs` and the `RelayHost` methods that only exist to serve it are deleted. On the AXP wire (RFD0025) the table disappears too, because routed calls are the extension's own methods (AXP §10.1).
- **Hub-routed jobs** (bash, computer, attachments, sign-ins) become methods of their extensions. They keep their concurrency limits, which are declared on the method instead of in static atomics.
- **`axod mcp`:** for now it stays a process that bridges stdio to the socket. In the tokio step (step 2 of the plan) the MCP server moves into axod as `axo-mcp`, reached through `axo.mcp` frames, so a tool call is one in-process call. `axod mcp` then only copies bytes.
  - **Built (2026-11-07), ahead of the rest of step 7.** `axod mcp` opens `axo.mcp.open {sessionId}`, the first request on its connection; `axo_ipc::Upgrades` hands the connection to `axo_mcp::upgrade`, and `axod mcp` copies bytes. Tools call axod's methods in process through `axo_ipc::Local`, as the connection's peer, each with its own `Cancellation`. Upgraded connections still speak line-delimited JSON, so the `axo.mcp` frames are not needed. The server is async (2026-11-08); see step 7. One gate per process now serves every Session, which is fine because it only remembers element and window names for its questions. When axod restarts, `axod mcp` exits with its connection; Pi shows the server disconnected and reconnects on the next call.

### Cancellation

Every request has a cancellation token. The server cancels it when:

1. the local connection closes;
2. the relay says the caller's call ended or the relay connection closes (AXP §5: outcome unknown);
3. `axod mcp` receives `notifications/cancelled` for the request, or its stdin closes;
4. axod is shutting down.

Handlers that wait (questions, `events.next`, forwarded connections, Pi prompts that wait for start, computer input) select on the token. A cancelled question resolves as `cancel`, publishes `elicitation.resolved`, and frees its slot. A Feynman spec, `specs/cancellation/`, states this and is checked against the conformance suite's tests.

### What stays blocking

*Historical: the plan as of 2026-11-07. The current boundaries are in [RFD0041](RFD0041-axod-session-tasks.md) and [RFD0042](RFD0042-async-relay-and-extensions.md). libghostty-vt has no thread of its own: each PTY's output pump feeds its headless terminal inline (`crates/axo-pty/src/output.rs`). SQLite has one `tokio-rusqlite` thread. Cua, accessibility and Keychain calls run on the blocking pool.*

Each of these sits behind exactly one boundary, and nothing else may block the executor:

- libghostty-vt: one thread per terminal, reached through a channel;
- SQLite: one database thread owning the `Connection`, reached through a channel. It replaces `SessionState.database` under the catalog lock;
- Cua accessibility calls and `SecCode` checks: `spawn_blocking`;
- PTYs: `AsyncFd` on the master; `fork`/`exec` on `spawn_blocking`.

### The Session manager, reimagined

*Superseded by [RFD0041](RFD0041-axod-session-tasks.md): axod split by Session (a task per Session and a registry), not by owner. Kept for the reasoning.*

Today `SessionState` is one struct under one lock. It is split by owner:

- **catalog** (axo-ext-sessions): Sessions, Workspaces, settings. It owns the database thread.
- **panes** (axo-panes): a registry of running and unavailable panes, keyed by shell.
- **agents** (axo-ext-agent): one task per Pi, owning its bridge, its activity, queued prompts and their provenance.
- **terminals** (axo-ext-terminal): one task per terminal, owning its PTY pump and VT thread.

These talk by messages and services, not by holding each other's locks. The split happens behind the `Sessions` service, after the extension API exists. Until then the mutex stays where it is, so that no step changes both the API and the concurrency.

### Order of the moves

Each step is one or a few commits on main. Each lands only with `bazel test //crates/...`, `//crates/axod:all` (conformance), the Worker's `:test` and `:relay_test`, and the Swift client interop tests green. A coverage run (`bazel/coverage/axod-coverage.sh`) must not lose lines.

1. **`axo-mcp`** (built, `b751505`): move `mcp.rs` out of `axo-server`. It only uses the socket. The computer-use gate goes to `axo_computer::gate`, since the hub-routed computer calls ask it too.
2. **The core**: grows in `axo-ipc`, which already sits below everything. It takes the `axo-server` name once the Session manager has moved out, so that extensions never depend on the crate that holds it. Introduce `Caller`, then per-method callers, which replace the inline `peer::current()` checks. Per-method callers are built for the local socket: a method registered with `add_typed_only(Only { signer, .. })` refuses anyone else before its parameters are read. `Caller` itself waits for step 6, when the relay's calls reach the same methods.
3. **Cancellation** (built for questions): the transport cancels a connection's unanswered requests when it closes (`axo_ipc::cancel`). `axod mcp` closes a call's connections when its client cancels the call, or when its stdin ends. A question wakes on its request's cancellation and is withdrawn. A forwarded connections call stops waiting too (the cloud's call runs on). A person's prompt that waits for Pi to start stops when its request is cancelled, and wakes when Pi binds or its pane goes away instead of checking every 50ms (2026-11-08).
4. **The extension API**, with the current `SessionManager` as its only implementation of `Sessions`. Begun: `axo_ipc::extension` has `Extension` (a name and `register`) and `Methods`, one owner per method; axod is assembled from `daemon`, `relay`, `sessions` and `apps`. Request contexts, background tasks and services come as the extensions that need them move out.
5. **Extensions out, smallest first:** apps (done: `crates/axo-apps`), assets (done: `crates/axo-assets`, sharing `AssetSlot` with the relay), questions (done: `crates/axo-questions`, with the Session manager as its `QuestionsHost`, passed to each call), computer (done: `crates/axo-computer-use`, named apart from the `axo-computer` library; its `ComputerHost` asks through questions). Each took its handlers and its tests; the rest of axod is a small host trait passed to each call.
   - **Terminal, agent and sessions move with step 8 (2026-11-07).** Unlike the four above, each owns part of `SessionState`: the shells, the Pi bridges, the catalog, all under the manager's one lock. Moving them first would mean a host trait that hands out that lock, which is today's coupling with a crate boundary drawn through it. They move when the state is split by owner, each taking its part.
6. **The relay as a transport**: delete `dispatch.rs` and the `RelayHost` methods it used.
   - **Found while preparing it (2026-11-07):** a remote call is not its local twin with a `target`. The account sees a *redacted* view: `RemoteSessionSnapshot` has Workspace names but no paths, and the layout pruned to terminal panes. That is a security property, pinned by `conformance_relay` ("the account sees names, not paths"). So mapping `axo.remote.*` onto the ordinary methods needs the methods to answer per caller: `Caller::Device` gets the redacted view, `Caller::Local` the full one. That is the view layer of the `sessions` extension, so step 6 moves after step 8 (splitting the Session manager), where those views get an owner. Until then `dispatch.rs` stays, held still by `conformance_relay`, which covers every remote call the parity table promises.
   - **Built (2026-11-08).** The relay is a transport: `axo-relay/src/relay/forward.rs` hands each of the account's requests to the host whole, and refuses anything not named `axo.remote.*` (so no local method is reachable from the cloud) and runs no notification. `RelayHost` has one `answer_remote` instead of nineteen `remote_*` methods. The calls are ordinary methods of axod, in `axo-server/src/session/remote.rs` (the `remote` extension, now `crates/axo-server/src/remote.rs`), registered beside the local ones and answering only `Caller::Relay`; a local program calling one is told the method does not exist. `axo_ipc::peer` has callers: `Caller::Signed(Signer)` for a local program with that signature, `Caller::Relay` for the account, which runs as `Peer::Relay` (`peer::as_relay`), something no socket client can be; `Only` takes a `Caller`. The redacted views, the stale-host check, the error codes and messages, and a prompt's attachments and limit moved with the calls; the wire is unchanged, held by `conformance_relay` and the Worker's relay tests. Prompts still ran on a task of their own then, since one waits for Pi; since RFD0042, `answer_remote` is awaited directly on the relay's task. The account's calls keep their own names and shapes until the wire moves to AXP, after the records do.
7. **tokio throughout**: the relay socket, the uploader, followers, PTY pumps, the database thread.
   - *Historical. The notes below record steps as they landed between 2026-11-07 and 2026-11-08. RFD0037 (causes, not ticks), RFD0041 (Session tasks, `tokio-rusqlite`, no reaper, no bridge or attachment threads) and RFD0042 (no `block_on` or `call_blocking`, async `RelayHost`) finished and replaced them. "What remains threads" below no longer holds.*
   - **The relay socket (built, 2026-11-07).** It was a loop that read with a 20ms timeout, so it woke 50 times a second when idle and delayed every message by up to 20ms. Now it uses `tokio-tungstenite` on a current-thread runtime on the relay thread, and one `select!` waits on the socket, the outgoing queue (a tokio channel that threads still send to without blocking), the heartbeat, the expiry of half-received messages, and `RelayControl`'s `Notify` for stop and reconnect. Requests that the host answers at once (dispatch, a person's answer, computer status) go in arrival order to one thread, and local events go to another, so neither holds up the socket. The handshake now times out after 30s instead of waiting forever. `conformance_relay` checks that calls aren't delayed by a poll (the median of 40 is under 5ms; it was about 21ms). Peers still use the blocking socket until the followers move.
   - **The rest of the relay, and the MCP server (built, 2026-11-08).** axod has one multi-thread runtime (`axo_server::axod_runtime`, four workers). Stopping is `axo_ipc::Stop` (a flag, a `Notify` and a `Condvar` for threads) and signals arrive as tokio signal streams, so the 20ms watchers in the accept loop and the signal check are gone. The relay connection, the followers of other Macs and the uploader are tasks; what blocks inside them (the Keychain, the link file, a sync turn, processing a peer's frame) runs on the blocking pool. A `bash` job is a `tokio::process` task: its exit and output are awaited, not polled every 10ms on three threads. The MCP server is async: an upgrade is an async function given the connection's halves, `Local::call` is a future, and each tool call is a task with its own `Cancellation` in a task-local, given up by `notifications/cancelled` or by the input ending. The computer-use gate and Cua calls run on the blocking pool. `axod mcp`, a separate process, still copies bytes on two threads.
   - **Nothing in axod wakes on a timer while idle (2026-11-08).** The threads that stay block on what they wait for, with no timeout:
     - the reaper sleeps until SIGCHLD (a tokio signal stream) or the launch's time limit; it looked at every child every 100ms;
     - the PTY attachment acceptor polls its listener and a socket pair that shutdown closes; it woke every 100ms;
     - each attached terminal's pump waits on output, and a watcher blocked on the client's socket detaches it on hang-up; it woke every 100ms per pane;
     - each PTY's output pump polls the PTY and a stop socket; it woke every 250ms per shell;
     - each Pi's bridge worker polls Pi's socket and a wake socket that every command writes to; it read with a 200ms timeout, so every command waited about 200ms before reaching Pi (`conformance_latency` now measures a few milliseconds).
   - **What remains threads:** the PTY pumps and attachment watchers (blocking reads, one per shell or pane), the Pi bridge workers (one per Pi), the database thread, and one-shot helpers (shell cleanup, Pi restarts, flushing queued prompts). None of them polls. They become tasks with step 8, when the terminal and agent extensions own their PTYs and Pis. `axod attach`'s resize forwarder wakes on SIGWINCH through a pipe (it checked a flag every 25ms).
8. **The Session manager split** behind `Sessions`.
   - *Historical. RFD0041 deleted `SessionManager`, `SessionState`, `AgentState` and the lock order below. `TerminalInput` survives, as each running pane's input writer (`crates/axo-server/src/terminal_input.rs`).*
   - **Closed (2026-11-08), by the data.** Since build 53, the Session state's lock is held long only by the startup restore (2–2.7s once per start, spawning every shell, before axod's socket exists, so nobody waits on it) and by the reaper (rarely 100–200ms). SQLite never shows up, so the database does not get a thread of its own: it stays with the catalog, which owns it, and its 102 call sites stay as they are. With the agents' state under its own lock and terminal input written outside the Session lock, what remains of the split is moving terminals, agents and sessions into crates. That waits for a second user of one of them: today each would need a host trait handing back the Session lock, which is the coupling with a crate boundary drawn through it. Step 6 did not need it: the views per caller are the `remote` extension's.
   - **The agents' state has its own lock (2026-11-08).** What axod knows of its Pis beyond their panes (activity, controls, dormant Pis, the launch, queued prompts, provenance) is `AgentState` in `session/agents.rs`, under `SessionManager.agents`, no longer inside `SessionState`. The order is fixed: the Session state's lock first, then the agents'; never the Session state while holding the agents'. `lock_agents()` marks the thread, `lock_state()` asserts in debug builds that it isn't marked, and a thread takes the agents' lock once, so a wrong order fails tests instead of deadlocking. A site that decides on panes and agents together (a Pi's binding is current, then its activity changes; a Pi exits, then its prompts are dropped) holds both; readiness, `axo.daemon.health` and reading a Pi's controls hold only the agents'. Functions over the state that need the agents take them as a parameter (`session_metadata`, `close_session`, `still_starting`). Next: the terminals' state (peer views, the viewport, attachments), then the database on its own thread, then each part into its crate.
   - **A pane's input is written outside the Session lock (2026-11-08).** Writing to a PTY whose program isn't reading blocks, with no limit: the master is a blocking descriptor shared with every attached client (`axod attach` writes to it too, so it can't be made non-blocking), and `poll` on a macOS PTY says writable when a 64-byte write still blocks. Input was written under the Session state's lock, so one large paste into a busy program stopped all of axod. Each running pane now has a `TerminalInput` (`session/terminal_input.rs`): its own copy of the master, the person's input sequence, and a turn, so one write per pane at a time. The lock is held only to find the pane. A pane that takes no input holds up only its own writers, which give up after `TERMINAL_INPUT_WRITE_TIMEOUT` (5s) with `TimedOut`; closing the pane ends the stuck write.

Steps 1 to 3 and 6 are built. Steps 4 and 5 are partly built. Steps 7 and 8 were finished another way by RFD0037, RFD0041 and RFD0042. Terminal, agent and sessions move into crates when something besides axod needs one (Current state).

### Testing

- **Conformance suite** (`crates/axod/tests/conformance`, harness in `tests/support`). It drives the real binary over its socket and through `axod mcp`, with a fake Pi (`testdata/fake_pi.rs`) that speaks the bridge. It is hermetic: its own `HOME`, file credentials, and a relay URL where nothing listens. Areas: daemon, sessions, account, elicitations, mcp.
- **Inventory** (`conformance_inventory`): every advertised method is called by a black-box test, and every tool `axod mcp` lists is called in `mcp.rs`. A method may only be listed as uncovered, and that list may only shrink.
- **The Worker's relay tests** cover the linked paths end to end through the real Worker.
- **Coverage** (a snapshot from 2026-11-07, before RFD0041 rebuilt `axo-server`; not re-measured since; unit plus black-box plus Worker end to end):

  | Crate | Lines |
  |---|---|
  | axo-server | 87.8% (9440/10749) |
  | axo-relay | 81.8% (4353/5319) |
  | axo-agent | 89.0% |
  | axo-pty | 84.9% |
  | axo-ipc | 93.2% |
  | axo-store | 96.4% |

  The weakest remaining areas are:
  - relay job limits and bad hub calls (`relay/jobs.rs` 56%, `dispatch.rs` 61%);
  - linking and peers (`link.rs` 58%, `follower.rs` 68%, `uploader.rs` 73%);
  - macOS permissions and bookmarks (`permissions.rs` 41%, `workspace_access.rs` 24%);
  - form filling (`input.rs` 50%), which only the live test reaches.

  A fake hub in the conformance harness would reach the relay paths deterministically, and should exist before step 6.

## Drawbacks

- **Many crates.** Twelve-odd crates add Bazel targets and a dependency graph to keep in mind. Some extensions (assets, connections) are a few hundred lines each.
- **A trait boundary costs some directness.** Calls between extensions go through services. Today a handler just takes the lock.
- **Step 4 is a large change in one place.** Wrapping the current manager as `Sessions` touches every handler's signature, even though each one's body stays the same.
- **Async everywhere is harder to read** wherever a plain blocking call was clearer. The blocking boundaries above keep that to the places that must wait.

## Alternatives

- **Do nothing.** Keep adding features in `axo-server` and the relay dispatch. Each phone feature keeps being written twice. ATXF would have to be threaded through both tables, and push delivery through the relay's threads.
- **Split files, not crates.** `axo-store` and `axo-relay` were split into modules this way already. That helps reading but not build times or boundaries: a module can still take the catalog lock.
- **One crate per AXP extension, exactly.** This is tidy, but `sessions` and `agent` share panes and Pi recovery too closely to be split along the spec's lines first. The layout above follows the code's own seams and can be split further later.
- **A rewrite from scratch** against AXP. It would throw away behaviour the conformance suite now pins down, such as restarts, crash recovery and dormant Pis, for a rewrite that would have to find all of it again.
- **Keep `RelayHost` and make it async.** It would stay a second API, only async. (RFD0042 later made `RelayHost` async, but only after step 6 had shrunk it to a transport adapter with one `answer_remote`, so it is not the second API this rejected.)

## Unresolved questions

- **Settled provisionally:**
  - Extensions get plain names: `axo-sessions`, `axo-questions`, `axo-apps` (connections become apps, RFD0016), and so on. `axo-ext-*` in this document means those.
  - The ATXF step moves the records only; the wire moves to AXP later.
- **During implementation:**
  - Where do the services' traits live: in `axo-server`, or in the extension that exports them?
  - Which limits move from static atomics to per-method declarations without changing behaviour that clients rely on?
- **Out of scope:** the Agent trait for a second agent backend (not until one exists), and push delivery (RFD0032).
