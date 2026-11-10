# RFD0037 - Axo: axod's reactive core

- Feature Name: `axod-reactive-core`
- Status: Implemented (steps 1 to 4 and 6; step 5 and the thread list superseded by [RFD0041](RFD0041-axod-session-tasks.md) and [RFD0042](RFD0042-async-relay-and-extensions.md))
- Author: leostera
- Start Date: 2026-11-09
- Updated: 2026-11-10
- Document Type: Proposal
- Amends: [RFD0034](RFD0034-axod-as-an-axp-server.md) (step 7), [RFD0018](RFD0018-session-sync-and-client-delivery.md) (Upload)

## Summary

Everything inside axod waits for a cause, on one tokio runtime. A cause is a message on a channel, bytes on a descriptor, a file change, a child's exit, a signal, or a deadline that is itself the point (a timeout, a backoff, a heartbeat). Nothing checks on a timer whether something changed, and no thread exists except the blocking calls tokio has no async form of (SQLite, libghostty-vt, accessibility). The host's heartbeat moves from every 10 seconds to every minute.

## Current state (2026-11-10, 0.49)

- **Built as written:** the uploader waits for causes, with FSEvents through `notify` (`crates/axo-relay/src/sync/watch.rs`; `specs/sessions/upload-wakes.ts`). Each child has an exit watch on tokio's SIGCHLD stream (`crates/axo-pty/src/exit.rs`, `WatchedChild`). The host heartbeats every 60 s (`HEARTBEAT_INTERVAL` in `crates/axo-relay/src/relay.rs`) against a 150 s lease (`LIMITS.leaseMs` in `packages/axo-api/src/contracts.ts`), and a newer socket from the same Mac replaces the old route (`packages/axo-api-worker/tests/mac-socket.test.ts`). The Mac app is pushed events on `axo.session.events.stream` (`crates/axo-server/src/event_stream.rs`, `AxodEventStream.swift`), and `axo.session.subscribe`, `axo.session.events.next` and `axo.session.unsubscribe` answer method-not-found (`crates/axod/tests/conformance/daemon.rs`). PTY output pumps are `AsyncFd` tasks. The side-car's start is watched through `notify` and its child's exit (`crates/axod-infer`).
- **Superseded by RFD0041:** step 5 (`StateChanges`, `wait_for_state`, `Interrupt`), process inspection and `pi_recovery` in step 2, the transcript lock's `EVFILT_PROC` wake, and the bridge, attachment and reaper threads in step 6. Session tasks and the lifeline removed what those waits were for.
- **Superseded by RFD0042:** the relay's request bridges that step 5 kept as blocked threads, and sign-in's `poll(2)` listener. Both are futures now.
- **Still a timer that is not the point:** waiting for a transcript's writer lock retries every 5 ms until its deadline (`crates/axo-agent/src/lock.rs`). `flock` cannot be awaited, and since RFD0041 removed the `EVFILT_PROC` wake, nothing reports a release. The wait happens only at a Pi's launch.
- **Not recorded:** the before-and-after numbers that Measuring it proposes.

The step sections below are the design as accepted, with notes where the code later changed.

## Motivation

RFD0032 made the cloud and the clients push-based; the inside of axod is still partly polled and partly threads.

- **Records wait for a tick.** The uploader checks every open transcript and rereads the catalog every 500ms. Every record reaches the cloud, and so the phone, up to half a second late, and an idle Mac wakes twice a second to find nothing.
- **Waiting for a process to exit is a loop.** Stopping a shell, a git query, an inspection tool, a Pi's controls and Pi's start each check `try_wait` or the Session state, then sleep 5 to 50ms.
- **The Mac app long-polls.** `TerminalCatalogSync` asks `axo.session.events.next` again after every batch, and axod reclaims subscriptions nobody polls.
- **The core is synchronous.** The Session manager, its event queues and the relay's request bridges use `std` mutexes, condvars and `recv_timeout`; tokio reaches them through about 15 `spawn_blocking` bridges. PTY output, terminal attachments, each Pi's bridge and the sign-in listener each have a thread.
- **The heartbeat is more frequent than it needs to be.** It only renews a lease that matters when a socket dies silently; every 10 seconds costs requests for nothing.

## Guide-level explanation

Nothing changes for a person except that things arrive sooner: a line Pi writes is in the cloud within milliseconds, a pane that exits closes at once, and the Mac app hears of every change as it happens. An idle Mac does nothing at all until something happens.

## Reference-level explanation

### What counts as a cause

| Cause | Mechanism |
| --- | --- |
| Another part of axod did something | a tokio channel (`mpsc`, `watch`, `broadcast`) or `Notify` |
| Bytes on a socket, pipe or PTY | tokio's `net` types, or `AsyncFd` on the descriptor |
| A file changed | `notify` (FSEvents) on the file's directory, reported through a channel or `Notify` |
| A child exited | a task per child woken by `tokio::signal::unix`'s SIGCHLD stream (below) |
| A process that isn't axod's child exited | kqueue `EVFILT_PROC` `NOTE_EXIT`: tokio has no way to watch it, and only the transcript lock needs it |
| A signal | `tokio::signal::unix` |
| Time is the point | `tokio::time::sleep_until` / `interval`: timeouts, backoffs, the heartbeat, the WebSocket ping, the reassembly expiry, debouncing |

A timer is allowed only when the deadline is what's being waited for. "Check again in 50ms" is not.

### Child processes: a task each, woken by SIGCHLD

Each child axod spawns (a shell's program, Pi, the inference side-car; inspection tools until RFD0041 removed them) gets a task on the caller's runtime (axod's, since RFD0041; a caller with no runtime is refused, and only axo-pty's tests share one of their own) that listens to tokio's SIGCHLD stream and, on each wake, asks `waitid(WEXITED | WNOHANG | WNOWAIT)` whether its own child has exited. It listens before it first looks, so no exit falls between. The child stays unreaped: its owner reaps through `try_wait` only once the task has seen the exit, so a pid, and the process group it leads, cannot be reused while anything could still signal it (process inspection kills a leader's whole group after the leader exits). That is why this is not `tokio::process`, which reaps as soon as it hears. Every exit wakes every task, one non-blocking syscall each: about a hundred, a few times a minute. The reaper stops sweeping: it is told which child exited.

As first built (0.38 to 0.43) this was one thread per child blocked in `waitid`: 113 of axod's 132 threads on a working Mac.

### Step 1: the uploader waits for a cause (`specs/sessions/upload-wakes.ts`)

A turn runs only when woken by:

- a Session event (anything but a streaming update): `forward_event`, as today;
- the catalog changing: `SessionSnapshot`, `SessionRemoved`, a lagged subscription;
- the kernel: a write to an open Session's transcript, or a file created in the directory of one that doesn't exist yet;
- the last append committing (there may be more);
- the socket connecting;
- a retry deadline after a failure.

The 500ms tick, the 60-second check of archived transcripts and the catalog's 500ms throttle go. The catalog is reread when a catalog event or Session event says it changed, not on every wake.

Two orderings make this sound, and the spec shows each is needed (`--without` breaks `everyLineReachesTheCloud`):

1. **Watch before reading.** A turn registers its watches, then reads. Pi reports a message's end on its bridge and appends the line in either order; if the turn woken by the event reads before the write, the write's vnode event wakes the next one.
2. **Watch the directory until the file exists.** Pi creates its transcript with the first line; a watch on a file that doesn't exist is impossible, so the directory stands in for it.

As built, every transcript is watched through its directory, with `notify`'s FSEvents stream (no latency, `NoDefer`): events name the file, so those for other files are dropped, and a transcript rewritten or created later is in the same directory, so nothing registers again. A directory that does not exist yet is stood in for by its nearest existing ancestor, recursively. `notify` starts its stream before `watch` returns, which keeps ordering 1. A write wakes the uploader in about 12 ms; a stream that starts also reports changes from just before it, a wake with nothing new to read. Only open Sessions' transcripts are watched; an archived one changes only by being restored, which is a catalog event. Until 0.43 this was a kqueue of `EVFILT_VNODE` watches, one descriptor per file.

Checked with `feynman check sessions/upload-wakes --depth 40`: every property holds on every path.

### Step 2: processes are waited for, not polled

*The per-child waiter and git queries are built as described (git runs under `tokio::process` in `crates/axo-server/src/workspace_state.rs`). The other bullets describe code that RFD0041 deleted. Kept as history.*

- The per-child waiter above, for shells and Pis. The reaper's 100ms tick (tests only today) goes.
- Inspection tools and git queries wait on their child's waiter (`WatchedChild`) until their deadline.
- `pi_controls` waiting for a Pi to exit awaits the shell's exit instead of polling the Session state every 50ms.
- Pi's start (`pi_recovery`, 50ms) waits on the Session state's `watch` channel for the pane to run or fail.
- The transcript lock (`lock.rs`, 5ms and 100ms) has no wake-up: `flock` can't be awaited. When the holder is a Pi axod knows, its exit (kqueue `EVFILT_PROC`) wakes the wait; otherwise the bounded retry stays, as a deadline. The 250ms window after a fork that has not exec'd yet stays a 5ms retry: nothing reports an exec.

### Step 3: the host lease (`specs/relay/host-lease.ts`)

- axod heartbeats every 60 seconds (`HEARTBEAT_INTERVAL`).
- The HostDO keeps a route for 150 seconds without one (`LIMITS.leaseMs`): two heartbeats and a deadline. A test pins `leaseMs >= 2 × heartbeat + deadline`.
- **A new socket from the same Mac replaces the old route** instead of being refused with 409 while the old lease lasts. Otherwise a laptop that woke on another network, whose old socket died where the HostDO couldn't see it, would be refused for up to 150 seconds. The old socket is fenced and closed (4002), as RFD0032 does for clients.
- Order: the Worker first (a 150-second lease is fine with 10-second heartbeats), then axod.

### Step 4: axod pushes to the Mac app

`axo.session.events.stream` is a connection's first request, as `axo.mcp.open` is: axod answers with the subscription, then sends each batch as an `axo.session.events` notification the moment there is one. The subscription lives as long as the connection. A subscription someone waits on is never reclaimed; one nobody waits on or polled for 60 seconds still is, for an in-process waiter that was cancelled before it unsubscribed. After a lag marker axod ends the stream, and the app opens a new one and relists. `axo.session.subscribe`, `axo.session.events.next` and `axo.session.unsubscribe` go in the same release (no legacy: the app and axod ship together, from one bundle).

### Step 5: waits on the Session state are events

*Superseded by [RFD0038](RFD0038-sessions-without-workspaces-and-session-actors.md) and [RFD0041](RFD0041-axod-session-tasks.md). The Session state is no longer one mutex, and `StateChanges`, `wait_for_state` and `Interrupt` are gone. The relay's blocked request threads became futures in RFD0042. SQLite runs on one `tokio-rusqlite` thread. Kept as history.*

The Session state stays one `std` mutex. Every change to it writes SQLite in the same critical section, so moving it into actors would only move the lock, across 140 call sites, for nothing a person would notice. What this step removes is the waiting: nothing that waits on the state looks again on a timer.

- `StateChanges` counts each release of the state's lock after a write. `wait_for_state` reads the count, checks the state, then sleeps until the count moves: Pi's start and a Pi's controls use it.
- An `Interrupt` (axo-agent) is a check and a descriptor that turns readable whenever the check may answer differently. axo-server makes one per recovery from `StateChanges`, so a close, a removal, a newer recovery or a shutdown calls a takeover off at once. Process inspection, the bridge's connect and reads, and the lock retry sleep on what they wait for and that descriptor together, with one `poll`, until their deadline.
- Every write to the state goes through its guard, so no change goes unheard.
- The relay's request bridges (`recv_timeout` in `outbound.rs`, `peers/live.rs` and `axo-questions`) stay threads blocked on a channel until their answer or deadline: blocked, not polling. Each holds a `spawn_blocking` thread only while one request is outstanding.
- SQLite stays blocking, on `spawn_blocking` (RFD0034, Closed by the data).

### Step 6: descriptors on `AsyncFd`

*As amended. PTY pumps are built as described, and run on axod's runtime. Since RFD0041, terminal attachments are tasks (`crates/axo-server/src/attachments.rs`; short handshake writes use the blocking pool), and each Pi's bridge is an async `UnixStream` read inside its Session's task (`crates/axo-agent/src/pi/link.rs`). Since RFD0042, sign-in's callback listener is a `tokio::net::TcpListener` whose connection tasks live in a `JoinSet`. The side-car bullet is built.*

- PTY output pumps: `AsyncFd` on the master, one task per pane, on the caller's runtime (axod's since RFD0041; first axo-pty's own two-thread runtime, which now only its tests use). The master stays blocking (attached clients share its file description), so a pump reads once per readiness and again while `poll` says there is more.
- The terminal attach listener: one `poll(2)` on the listener and a stop socket, with no timeout. Each attached client keeps its two threads, one streaming output and one waiting for the client to hang up: both are blocked, not polling, and only the panes on screen are attached.
- Each Pi's bridge: one `poll(2)` on the socket and its `Interrupt`, not 100ms slices.
- Sign-in's callback listener: one `poll(2)` on its listeners and a wake its serving threads write, not a non-blocking accept every 50ms.
- The inference side-car's start: `notify` on its run directory (the socket appearing, the log growing) and its exit; its health is asked only when one of them changes.

### What stays a thread

*Historical: the list as of 0.44. Current threads, per RFD0041 and RFD0042: axod's main thread and runtime workers, SQLite's one `tokio-rusqlite` thread, the FSEvents threads of `notify` watchers, and blocking-pool threads for synchronous OS and library work (Keychain, accessibility and TCC, process and filesystem setup, transcript hashing and reads), which expire when idle. libghostty-vt has no thread: each PTY's pump feeds its headless terminal inline (`crates/axo-pty/src/output.rs`). Attachments and Pi bridges have no threads.*

- One FSEvents run-loop thread per `notify` watcher: the uploader's, and the side-car's while it starts.
- Two per attached terminal, and one per Pi's bridge.
- libghostty-vt, one per terminal (RFD0034), reached through a channel.
- `spawn_blocking` for SQLite, Cua and accessibility calls, `SecCode` checks and `fork`/`exec`.
- `axod attach` and `axod mcp` are separate processes, the terminal's and Pi's side; their copy loops are not axod's core.

### Measuring it

- Record latency: from Pi's write to the SessionDO's commit, before and after step 1 (axod's `sync.append` log has both times).
- Idle wakeups: `sudo powermetrics --samplers tasks` on an idle Mac, for axod, before and after.
- Threads: `ps -M` on axod, before and after each step.

## Drawbacks

- FSEvents and the transcript lock's kqueue are macOS-specific. So is axod.
- A missed cause now means a stalled upload rather than a 500ms delay. The upload wakes spec is the argument that none is missed; each reconnect's handshake is the backstop.
- A 150-second lease shows a Mac that lost power as online for up to 2½ minutes instead of 30 seconds. A socket that closes normally (quitting, sleeping with the network up, axod stopping) is still seen at once.

## Rationale and alternatives

- **Keep the tick, lower it.** Halves the delay, doubles the wakeups.
- **A safety sweep every few minutes.** Hides the bugs the spec exists to find, and wakes an idle Mac.
- **`tokio::process`.** Reaps on exit, so a leader's process group id could be reused before inspection's cleanup signals it.
- **A blocking `waitid` thread per child** (0.38 to 0.43). Immediate, and never shares a wake, but a thread per child: most of axod's threads.
- **Raw kqueue (`EVFILT_PROC`, `EVFILT_VNODE`).** Immediate and precise, but our own unsafe event loop three times over, where tokio's signals and `notify` already exist.

## Unresolved questions

- ~~Whether the Mac app's other loops (`AutomaticPiRestarter`, the phone's `ConversationPull`) poll something axod could push.~~ Answered by reading them (2026-11-10). Neither polls axod's state. `AutomaticPiRestarter` (`apple/AxoMac/Sources/AxoMac/Sessions/AutomaticPiRestarter.swift`) is a retry with exponential backoff, capped at 30 s, for a Pi pane that stays unavailable: a deadline that is the point. `ConversationPull` is the phone's pull-to-refresh gesture state, not a loop.
