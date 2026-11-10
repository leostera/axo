# RFD0041 - Axo: axod as tasks, and every process its child

- Feature Name: `axod-session-tasks`
- Status: Implemented (0.46, `57c2c50`; the side-car in 0.48, `5795a4c`)
- Author: leostera
- Start Date: 2026-11-10
- Updated: 2026-11-10
- Document Type: Proposal
- Supersedes: [RFD0038](RFD0038-sessions-without-workspaces-and-session-actors.md) (Part 2, a task per Session)
- Amends: [RFD0037](RFD0037-axod-reactive-core.md) (what is left of its threads and waits), [RFD0033](RFD0033-session-controls-for-clients.md) (restarting Pi), [RFD0018](RFD0018-session-sync-and-client-delivery.md) (event queues)

## Summary

`axo-server` is rebuilt, in one change, as tasks on axod's one tokio runtime. A registry task finds and starts Sessions; each Session is a task that owns its panes, its Pi and everything said about them, and is reached only through its mailbox. SQLite has one writer thread behind `tokio-rusqlite`. Events go out on a `broadcast` channel. Services that were fields of the Session manager (questions, computer use, the input key, assets, devices, a folder's git state) stand on their own. Every process axod depends on is its child and dies with it: each Pi holds a lifeline pipe from axod and exits when it closes, and at boot axod kills a Pi a previous axod left behind rather than taking it over.

The data model and every wire stay as they are: the same database, the same transcripts, the same RPC methods, attach protocol, bridge protocol and relay calls.

## Motivation

axod had four concurrency models at once:

- **One lock for everything.** `SessionManager` held the SQLite connection and every pane behind one `std` mutex, the Pis' state behind a second, and twenty more fields, a third of them nothing to do with Sessions. Every write to SQLite happened under the lock.
- **Waits built around that lock.** Because everything waited on one lock, RFD0037 had to add `StateChanges`, `wait_for_state`, `PiWake`, `Interrupt`, seven condvars and a reaper thread to stop waits polling.
- **A thread per thing.** Each Pi had a bridge thread; each terminal attachment two; prompt flushes, Pi restarts, shell cleanup, git reads and the attach acceptor each had their own.
- **Async at the edges only.** The socket, the relay and the MCP servers were async, and reached the core through 25 `add_blocking_method` handlers and a dozen `spawn_blocking` bridges.

And processes axod depended on could outlive it. A Pi whose axod crashed kept running, holding its transcript's writer lock, so every axod had to be able to take a transcript over from a Pi it did not start: `takeover.rs` (900 lines), `process_inspection.rs` (430), a shutdown handshake on the bridge, a kqueue on another process's exit, and most of `pi_recovery.rs`. The rule now is simpler: any process axod is not the parent of is killed and started again as its child.

## Guide-level explanation

Nothing changes for a person, except:

- Quitting or crashing axod ends every Pi it ran, at once, even with `kill -9`. The next axod starts them again on their conversations.
- A Pi that survived anyway (an older axod, a stuck process) is killed when axod starts, not negotiated with.
- axod runs on about a dozen threads, whatever the number of Sessions and panes.

## Reference-level explanation

### Shape

```
                ┌──────────────────── axod's runtime ────────────────────┐
socket ─► RPC handlers (async) ─► Registry ─► Session task (one per Session)
attach.sock ─► attachment tasks ─────────┘        │  panes, Pi, bridge stream, prompts
relay ─► RelayHost adapter ──────────────┘        │
                                                  ├─► Store (tokio-rusqlite, one thread)
Events (broadcast) ◄──────────────────────────────┤
Catalog (watch: every open Session's record) ◄────┘
Services: questions, computer use, input key, assets, devices, git state
```

- **Registry** (`sessions.rs`): owns which Sessions are open and their tasks' mailboxes, the viewport, the launch's readiness, reopening and the focus a resume asks for. It creates, closes, reopens and imports Sessions, and restores them at boot.
- **Session task** (`session/`): one per open Session. It owns its panes' processes, its Pi (launching, its bridge connection as a stream inside the task, activity, controls, queued prompts, dormancy), and writes its own rows. Commands arrive on its mailbox; child exits and bridge records arrive on the same mailbox. It never waits on anything slow inline: a Pi's answer to a prompt is awaited by the caller, which the task hands the bridge's sender to.
- **Catalog** (`catalog.rs`): a `watch` channel holding every open Session's `SessionRecord`, written by Session tasks as their records change. `axo.session.list`, the relay's sync, the questions extension's "is this Session open" and the attach socket's shell lookup read it without asking any task.
- **Store** (`store.rs`): `tokio-rusqlite`'s connection, the only SQLite handle. Every caller awaits it. (As first built, the relay's synchronous calls blocked on it from the blocking pool; [RFD0042](RFD0042-async-relay-and-extensions.md) made those calls async and removed the bridge.)
- **Events** (`events.rs`): one `broadcast` channel of `Arc<Event>`. A subscription is a receiver with its scope and Session filter; falling more than the channel's capacity behind gives `subscription.lagged` and the client relists, as before. Terminal output is published only while someone streams it.
- **Services** (`core.rs`): stand-alone values beside the Sessions, given to the extensions that use them. `Core` is what every part shares; it holds no Session state.

### Processes

- **Lifeline.** axod opens one pipe at start and keeps its write end, close-on-exec. Each Pi inherits the read end (`AXO_LIFELINE_FD`); pi-axo exits when it reads end of file. The kernel closes the write end however axod ends, so Pis cannot outlive it. Node does not pass the descriptor on to Pi's own children.
- **Kill at boot.** When a Pi starts, its pid and start time are stored with its Session. A new axod that finds the transcript's writer lock held looks up the stored pid; if a process with that pid and start time exists, it is sent SIGKILL (and its group), and axod waits for the lock. An unknown holder is never signalled: the pane is unavailable, as before.
- **Children.** Shells and Pis are axod's children on PTYs, watched as RFD0037 says. Stopping one is async: SIGHUP and SIGTERM, then SIGKILL after its grace, waited for without a thread. macOS's `waitid(WEXITED)` also reports a child that was stopped or continued, so a watch counts only `CLD_EXITED`, `CLD_KILLED` and `CLD_DUMPED` as an exit; a stopped Pi is still running, and stopping axod still kills it.
- **Clearing the identity.** A Pi's stored identity is cleared when it exits, and kept when axod stops, so the next axod can recognise it if it somehow survived.
- **Restarting Pi** (`axo.session.pi.restart.*`, `axo.remote.session.restart`): ask Pi to shut down on its bridge, kill it after the grace, start it again. No takeover.

### What goes

`takeover.rs`, `process_inspection.rs`, `interrupt.rs`, the bridge's shutdown-if-idle handshake, `lock.rs`'s `ProcessExit` kqueue, `SessionManager`, `StateChanges`, `wait_for_state`, `PiWake`, the reaper, the bridge worker threads, the attachment threads and acceptor, `add_blocking_method` for axod's own methods, the per-subscriber `EventQueue`s, and axo-pty's own runtime when it runs inside axod. (RFD0042 later removed `add_blocking_method` altogether.)

Without the `ProcessExit` wake, waiting for a transcript's writer lock is a 5 ms retry bounded by its deadline (`crates/axo-agent/src/lock.rs`). It happens only when a Pi launches: for up to 250 ms while a child forked before a release still holds the lock (`FORK_EXEC_WINDOW`), and for up to 2 s after a previous Pi is killed (`KILLED_RELEASE`).

### Order of work

One change: the old core is deleted, not migrated. The integration suites (`//crates/axod:rpc_tests`, the conformance targets, the Swift interop tests and the relay's end-to-end tests) are the contract it must keep. `axod terminal-attach` was removed in its own release (0.48, `fedde36`). `axod mcp` was already a thin proxy (below). The unit tests the change dropped were ported back separately (`6265d2f`, RFD0042).

The inference side-car (`axod-infer`, llama.cpp's server) is axod's child too. It cannot read a lifeline itself, so it runs under a small shell that does and kills it when the lifeline ends (`Lifeline::guarded`); the model download runs the same way. A side-car an earlier axod left running is found through its socket's peer (`LOCAL_PEERPID` on `infer.sock`, in axod's private run directory), killed and replaced on the next question. `axod mcp` was already a thin proxy (RFD0034): the computer-use gate that starts the side-car runs in axod.

## Drawbacks

- One large change is harder to bisect than seven small ones. The data model and every wire staying the same is what makes it safe: nothing stored or sent changes shape.
- A Session's commands are serialized through its task. A slow operation inside a task would stall that Session; the rule that tasks never await anything slow inline (bridge answers, process stops, git) is what keeps it responsive.
- A global `broadcast` channel means a burst of terminal output can make a catalog-only subscriber lag. Output is only published while a stream subscriber exists, and the capacity is sized for bursts.

## Rationale and alternatives

- **Migrate one operation at a time** (RFD0038 Part 2's plan). Rejected: every intermediate state needs both the lock and the tasks, and the bridges between them are exactly the complexity being removed.
- **`sqlx` or `turso`.** `tokio-rusqlite` keeps `axo-store`'s synchronous functions as they are and adds only the thread.
- **Keep taking over orphaned Pis.** A lifeline makes orphans the exception, and killing the exception is simpler and safer than verifying and negotiating with it.

## Unresolved questions

- Computer use on a locked Mac (RFD0028) is unchanged by this.
