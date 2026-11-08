# RFD0034 - Axo: axod as an AXP Server with Extensions

- Feature Name: `axo-axod-as-an-axp-server`
- Status: Accepted (provisionally, 2026-11-07, to unblock the work; revisit on review)
- Author: leostera
- Start Date: 2026-11-07
- Updated: 2026-11-07 (steps 1 and 3 built; per-method callers on the local socket)
- Document Type: Proposal
- Amends: [RFD0016](RFD0016-connections-and-tools.md), [RFD0029](RFD0029-ask-the-person.md)

## Summary

axod becomes a small AXP server (`axo-server`) plus extensions that know nothing about it. The server owns connections, trust, routing, events and cancellation. Every feature lives in an extension crate that registers methods behind one async API: Sessions, agent, terminal, connections, questions, computer use and assets. A request is the same request whether it arrives on the local socket, through the relay, or from `axod mcp`. So the relay's second dispatch table goes away, and every handler is told who is calling and when the caller has gone. The move happens one crate at a time. Before each step lands, a black-box conformance suite must stay green and coverage must not drop.

## Motivation

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

Each of these sits behind exactly one boundary, and nothing else may block the executor:

- libghostty-vt: one thread per terminal, reached through a channel;
- SQLite: one database thread owning the `Connection`, reached through a channel. It replaces `SessionState.database` under the catalog lock;
- Cua accessibility calls and `SecCode` checks: `spawn_blocking`;
- PTYs: `AsyncFd` on the master; `fork`/`exec` on `spawn_blocking`.

### The Session manager, reimagined

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
7. **tokio throughout**: the relay socket, the uploader, followers, PTY pumps, the database thread.
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
   - **The agents' state has its own lock (2026-11-08).** What axod knows of its Pis beyond their panes (activity, controls, dormant Pis, the launch, queued prompts, provenance) is `AgentState` in `session/agents.rs`, under `SessionManager.agents`, no longer inside `SessionState`. The order is fixed: the Session state's lock first, then the agents'; never the Session state while holding the agents'. `lock_agents()` marks the thread, `lock_state()` asserts in debug builds that it isn't marked, and a thread takes the agents' lock once, so a wrong order fails tests instead of deadlocking. A site that decides on panes and agents together (a Pi's binding is current, then its activity changes; a Pi exits, then its prompts are dropped) holds both; readiness, `axo.daemon.health` and reading a Pi's controls hold only the agents'. Functions over the state that need the agents take them as a parameter (`session_metadata`, `close_session`, `still_starting`). Next: the terminals' state (peer views, the viewport, attachments), then the database on its own thread, then each part into its crate.

Steps 1 to 3 are small and can start at once. Step 4 is the one that needs review. The order that remains is 7 (tokio), 8 (the split, and terminal, agent and sessions out), then 6 (the relay as a transport, once the views per caller have an owner).

### Testing

- **Conformance suite** (`crates/axod/tests/conformance`, harness in `tests/support`). It drives the real binary over its socket and through `axod mcp`, with a fake Pi (`testdata/fake_pi.rs`) that speaks the bridge. It is hermetic: its own `HOME`, file credentials, and a relay URL where nothing listens. Areas: daemon, sessions, account, elicitations, mcp.
- **Inventory** (`conformance_inventory`): every advertised method is called by a black-box test, and every tool `axod mcp` lists is called in `mcp.rs`. A method may only be listed as uncovered, and that list may only shrink.
- **The Worker's relay tests** cover the linked paths end to end through the real Worker.
- **Coverage** (2026-11-07, unit plus black-box plus Worker end to end):

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
- **Keep `RelayHost` and make it async.** It would stay a second API, only async.

## Unresolved questions

- **Settled provisionally:**
  - Extensions get plain names: `axo-sessions`, `axo-questions`, `axo-apps` (connections become apps, RFD0016), and so on. `axo-ext-*` in this document means those.
  - The ATXF step moves the records only; the wire moves to AXP later.
- **During implementation:**
  - Where do the services' traits live: in `axo-server`, or in the extension that exports them?
  - Which limits move from static atomics to per-method declarations without changing behaviour that clients rely on?
- **Out of scope:** the Agent trait for a second agent backend (not until one exists), and push delivery (RFD0032).
