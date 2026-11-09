# RFD0037 - Axo: axod's reactive core

- Feature Name: `axod-reactive-core`
- Status: Accepted
- Author: leostera
- Start Date: 2026-11-09
- Updated: 2026-11-09
- Document Type: Proposal
- Amends: [RFD0034](RFD0034-axod-as-an-axp-server.md) (step 7), [RFD0018](RFD0018-session-sync-and-client-delivery.md) (Upload)

## Summary

Everything inside axod waits for a cause, on one tokio runtime. A cause is a message on a channel, bytes on a descriptor, a kernel event (kqueue), a signal, or a deadline that is itself the point (a timeout, a backoff, a heartbeat). Nothing checks on a timer whether something changed, and no thread exists except one blocking waiter per child process, and the blocking calls tokio has no async form of (SQLite, libghostty-vt, accessibility). The host's heartbeat moves from every 10 seconds to every minute.

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
| A file changed | kqueue `EVFILT_VNODE` (`NOTE_WRITE`, `NOTE_EXTEND`, `NOTE_DELETE`, `NOTE_RENAME`) through `AsyncFd` on the kqueue |
| A child exited | one blocking `waitpid` thread per child (below), or `tokio::process` |
| A process that isn't axod's child exited | kqueue `EVFILT_PROC` `NOTE_EXIT` |
| A signal | `tokio::signal::unix` |
| Time is the point | `tokio::time::sleep_until` / `interval`: timeouts, backoffs, the heartbeat, the WebSocket ping, the reassembly expiry, debouncing |

A timer is allowed only when the deadline is what's being waited for. "Check again in 50ms" is not.

### Child processes: one blocking waiter each

Each child axod spawns (a shell's program, Pi, an inspection tool) gets one thread that does nothing but `waitpid(pid, 0)`, then sends the exit status on a `oneshot` and ends. Nothing else ever waits on that pid, so the status cannot be stolen, and the exit is seen the instant the kernel reports it, with no SIGCHLD fan-out and no `try_wait` sweep. A thread blocked in `waitpid` costs a stack and nothing else. Waiting for exit becomes awaiting the `oneshot`, with `timeout` where there is a limit. The reaper stops sweeping: it is told which child exited.

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
2. **Watch the directory until the file exists.** Pi creates its transcript with the first line; a watch on a file that doesn't exist is impossible, so the directory's `NOTE_WRITE` stands in for it.

A watch that sees `NOTE_DELETE` or `NOTE_RENAME` (a rewritten transcript) is dropped and registered again on the path by the turn the event wakes. Only open Sessions' transcripts are watched; an archived one changes only by being restored, which is a catalog event. The kqueue is one descriptor in the uploader's `select!` through `AsyncFd`.

Checked with `feynman check sessions/upload-wakes --depth 40`: every property holds on every path.

### Step 2: processes are waited for, not polled

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

The Session state stays one `std` mutex. Every change to it writes SQLite in the same critical section, so moving it into actors would only move the lock, across 140 call sites, for nothing a person would notice. What this step removes is the waiting: nothing that waits on the state looks again on a timer.

- `StateChanges` counts each release of the state's lock after a write. `wait_for_state` reads the count, checks the state, then sleeps until the count moves: Pi's start and a Pi's controls use it.
- An `Interrupt` (axo-agent) is a check and a descriptor that turns readable whenever the check may answer differently. axo-server makes one per recovery from `StateChanges`, so a close, a removal, a newer recovery or a shutdown calls a takeover off at once. Process inspection, the bridge's connect and reads, and the lock retry sleep on what they wait for and that descriptor together, with one `poll`, until their deadline.
- Every write to the state goes through its guard, so no change goes unheard.
- The relay's request bridges (`recv_timeout` in `outbound.rs`, `peers/live.rs` and `axo-questions`) stay threads blocked on a channel until their answer or deadline: blocked, not polling. Each holds a `spawn_blocking` thread only while one request is outstanding.
- SQLite stays blocking, on `spawn_blocking` (RFD0034, Closed by the data).

### Step 6: descriptors on `AsyncFd`

- PTY output pumps: `AsyncFd` on the master, one task per pane, on axo-pty's own two-thread runtime, so they work the same in axod and in tests. The master stays blocking (attached clients share its file description), so a pump reads once per readiness and again while `poll` says there is more.
- The terminal attach listener and each attachment: `tokio::net::UnixListener` and `UnixStream`.
- Each Pi's bridge: one `poll(2)` on the socket and its `Interrupt`, not 100ms slices.
- Sign-in's callback listener: one `poll(2)` on its listeners and a wake its serving threads write, not a non-blocking accept every 50ms.
- The inference side-car's start: one kqueue on its run directory, its log and its exit; its health is asked only when one of them changes.

### What stays a thread

- One `waitpid` waiter per child.
- libghostty-vt, one per terminal (RFD0034), reached through a channel.
- `spawn_blocking` for SQLite, Cua and accessibility calls, `SecCode` checks and `fork`/`exec`.
- `axod attach` and `axod mcp` are separate processes, the terminal's and Pi's side; their copy loops are not axod's core.

### Measuring it

- Record latency: from Pi's write to the SessionDO's commit, before and after step 1 (axod's `sync.append` log has both times).
- Idle wakeups: `sudo powermetrics --samplers tasks` on an idle Mac, for axod, before and after.
- Threads: `ps -M` on axod, before and after each step.

## Drawbacks

- kqueue is macOS-specific. So is axod.
- A missed cause now means a stalled upload rather than a 500ms delay. The upload wakes spec is the argument that none is missed; each reconnect's handshake is the backstop.
- A 150-second lease shows a Mac that lost power as online for up to 2½ minutes instead of 30 seconds. A socket that closes normally (quitting, sleeping with the network up, axod stopping) is still seen at once.

## Rationale and alternatives

- **Keep the tick, lower it.** Halves the delay, doubles the wakeups.
- **A safety sweep every few minutes.** Hides the bugs the spec exists to find, and wakes an idle Mac.
- **SIGCHLD and `try_wait` on every child** (the reaper today). Correct, but every exit wakes every waiter, and `tokio::process` would compete with it for the same children. One waiter per child owns its pid.
- **kqueue `EVFILT_PROC` for children too.** Equally immediate, but the zombie still needs reaping; `waitpid` does both.

## Unresolved questions

- Whether the Mac app's other loops (`AutomaticPiRestarter`, the phone's `ConversationPull`) poll something axod could push. They are looked at with step 4.
