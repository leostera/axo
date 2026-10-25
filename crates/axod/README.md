# axod CLI (`axod`)

`axod` is the daemon's command-line entrypoint. It uses `clap` for argument parsing and delegates server startup to `axo-server`; it does not implement daemon behavior or JSON-RPC itself.

```sh
axod [--socket <absolute-path>] [--server-dir <absolute-path>]
axod --version
```

Without `--socket`, the server uses `~/Library/Application Support/Axo/run/axod.sock`. Without `--server-dir`, it stores `axo.pid`, `stdout.log`, and `stderr.log` under `~/.axo/server/`. It uses `HOME` when absolute and falls back to the current account's home directory when LaunchAgent environments omit it. The directory is private to the user; logs include timestamps, levels, and stable lifecycle event names, append across launches, and rotate to one `.log.1` backup on startup when larger than 10 MiB. `--server-dir` is useful for isolated tests and local runs.

The PID file is diagnostic metadata, not a process-control mechanism: launchd remains the source of truth for service lifetime, and a forced kill may leave a stale PID file until the next successful start replaces it. On macOS, `SMAppService` registers the bundled executable as a per-user LaunchAgent; launchd owns its process lifetime.

## Crates

| Crate | Owns |
| --- | --- |
| `axod` | This binary and the `terminal-attach` CLI. |
| `axo-server` | `SessionManager` orchestration: the catalog lock (`lock_state`, which logs `catalog.lock_wait_long`/`lock_held_long` with the caller), pane lifecycle, Pi bridge and recovery, RPC handlers. `panes.rs` is the pane table and its state machine (`Pane::Running`/`Unavailable`, `Recovery::Idle`/`InProgress`). It parses settings and restores Workspace folder access; it has no SQL outside its tests. |
| `axo-store` | The SQLite catalog: `open` (WAL, `synchronous=FULL`, owner-only file), schema and migrations, and every database-only read and write, each tested against an in-memory database. It knows no processes, files or settings syntax. |
| `axo-protocol` | Wire types: IDs, `PaneRole`, layouts, records, typed RPC params/results and events. |
| `axo-pty` | PTYs, launching children on them, the permanent output pump, attach protocol v2, and `process::stop_all`. |
| `axo-pi` | Pi launch, bridge worker and protocol, writer lock, takeover, activity. |
| `axo-ipc` | Newline-delimited JSON-RPC over the Unix socket and `EventQueue`. |
| `axo-relay` | The Cloudflare host relay. |
| `axod-loadtest` | `axod-loadtest --profile heavy`: load against an isolated axod; pass bar control-plane p99 < 10 ms. |

## Runtime and attachment invariants

- A durable pane ID is not a process identity. Each launch gets a daemon-local runtime ID; attachment output/detachment, Pi bridge metadata/activity, and resume requests are checked against that runtime. Late callbacks from a replaced process cannot modify its replacement.
- Axod is the single, permanent reader of every PTY it owns. Each shell has an output pump from spawn until its PTY reaches end of file; it records replay history, publishes `terminal.output`, and fans bytes out to every attachment. Shells never stall on a full PTY buffer because nothing is attached, and any number of clients can attach to one shell.
- Attach protocol v2: the client writes `<shellId>\n`; Axod replies with `u64::MAX` plus a rejection code, or with the replay length (big-endian `u64`), one `SCM_RIGHTS` message carrying the PTY master, then the replay and live output as raw bytes. The descriptor is for input, resizing and termios/foreground queries only. Closing the socket detaches; end of file means the shell exited or the client fell more than 8 MiB behind (clients consult the catalog to tell which).
- Accepted terminal sockets explicitly use bounded blocking I/O, including on macOS where accepted sockets can inherit the listener's nonblocking mode. A failed or timed-out write ends the attachment, so a partial write never corrupts a live stream. Stalled clients release their attachment lease; idle attachments observe shutdown, client close and runtime replacement.
- Child wait failures are reported once per runtime and isolated from other children. An uncertain child remains represented; Axod does not infer completion or signal a possibly reused PID after losing wait ownership.
- Every pane process stops through `stop_panes`: SIGHUP and SIGTERM to all at once, SIGKILL to each whose own grace runs out (terminals 500 ms, Pi `axo_pi::STOP_GRACE`). It owns the processes, so a Pi's writer lock and PTY are released only after it exits. Closing a Session stops its panes on one background worker; shutdown stops them inline.
- Shutdown drains runtime ownership before slow child cleanup, without holding the catalog mutex while waiting for processes. Cleanup is idempotent, avoids joining its own worker, and retains cleanup responsibility if a background cleanup thread cannot start.
- Only the intended Pi child inherits its transcript writer lock across exec. The parent keeps close-on-exec set throughout launch so unrelated child processes cannot accidentally retain that lock. No transcript content is rewritten by these lifecycle operations.
- Pi recovery reserves only the unavailable pane, snapshots its launch inputs, then releases the catalog mutex before connecting, waiting for writer ownership, or executing the replacement. Duplicate recovery returns a retryable error. Startup restore and archived-session resume use this same path; restoring an already represented pane never replaces its runtime.
- Close/removal and shutdown invalidate recovery reservations. Waits poll cancellation, force-signal dispatch is ordered with cancellation under a short catalog guard, and a launch completing after invalidation is cleaned up outside the mutex rather than resurrecting its pane. A previously dispatched graceful shutdown cannot be recalled. Failed recovery releases its reservation without removing the unavailable pane.
- Recovery requires a unique persisted owner and an existing regular history file inside Axo's private history directory; leaf symlinks, missing history, and history inode/device changes while takeover waits are rejected. Writer-lock opens reject symlinks and nonregular files. Credentials rotate only after exclusive writer ownership and history revalidation.
- Pi takeover connect/read phases share an absolute two-second deadline, including partial records and unrelated events; writes have independent bounded timeouts. Bridge-worker connects are also bounded and cancellation-aware, including a full listener accept queue. `/resume` validates target availability and archives its requester in one catalog transition.
- Explicit lock-owner inspection uses one two-second deadline across `lsof`/`ps`, caps stdout at 16 KiB per tool and unique owners at 32, and polls cancellation. Partial/malformed/expired results cannot authorize takeover. Failed inspection cleans up only its own newly launched utility group with retained wait ownership and a separate bounded reap budget; lost ownership is reported, never guessed. No tool output or stderr is logged.
- Local event subscriptions: the subscription registry lock only guards membership, and each long-poll waits on its own receiver, so one waiting client never stalls another or the relay. Catalog subscribers (`includeTerminalOutput: false`) receive catalog events only (`session.*`, `workspace.changed`, `shell.activity`, `relay.status`), never terminal output or `pi.event`. A full queue reports `subscription.lagged`; `events.next` with `maxEvents` returns ordered batches; initial snapshots go only to the new subscriber.
- `axo.shell.busy` reports whether closing a shell would interrupt work: the PTY foreground process group (`tcgetpgrp`) differs from the shell, or the Pi pane is mid-turn. The foreground process name is a presentation hint only.

See [recovery hardening evidence and remaining boundaries](../../docs/axod-recovery-hardening.md) for verification and follow-up scope.

These guarantees do not make a daemon restart transparent: restarting Axod still replaces its PTYs/processes. Automatic Pi recovery remains idle-only and non-forcing, and restoration can leave a pane unavailable when the original transcript or safe writer ownership is unavailable.

## Cloudflare host relay

The packaged LaunchAgent supplies the Axo API URL. Axod attempts to connect automatically when it starts and retries with backoff; **Axo.app → Settings → Remote Access** reports the actual relay connection state and lets you request an immediate retry. The host name is read from existing local host metadata (or the system hostname on first setup), and the platform is reported as macOS. There is no API URL or editable host-name setup in the app.

The daemon derives its stable host ID from its private session database and rotates the host generation at each daemon-process start. It connects to `/v1/hosts/<host-id>/daemon` over TLS, registers terminal-free session metadata, sends periodic heartbeats, and streams activity/output events without retaining them in Cloudflare storage. Local PTYs remain owned by `axod`; closing the Axo.app UI detaches the terminal view but does not stop the LaunchAgent or its PTYs. Restarting the daemon itself does stop those processes, after which Axod restores session records by starting replacement shells.

A failed Pi recovery is isolated to its pane: Axod stays available, retains the open Session and transcript, and reports the pane as unavailable. An unexpected Pi process exit also leaves the Session and Pi pane open-but-unavailable; it does not archive the Session or its sibling panes. **Settings → Agent → Automatically restart unavailable Pi sessions** retries recovery for each affected pane. Automatic retries are safe-only: Axod starts a replacement when the transcript lock is free, or asks the exact authenticated Pi bridge to shut down only if Pi reports idle. Busy or unresponsive Pi processes are never force-stopped automatically; their panes remain unavailable and Axo keeps retrying while the option is enabled. The pane's **Restart Pi** action remains an explicit, pane-scoped recovery: it first authenticates to the Pi bridge and requests shutdown. If that bridge is unavailable, the explicit restart may identify the exclusive transcript-lock owner, but only when the lock is held by one process group owned by the current user and led by `pi`. Axod then sends SIGTERM and, if necessary, SIGKILL only to that verified group. Axod acquires the original transcript lock before starting any replacement; it never overwrites the conversation history.

For isolated loopback tests only, the relay supports `allowInsecureLoopback: true` with a `ws://localhost`/loopback URL and `access: { "kind": "accessAssertion", "assertion": "<fixture JWT>" }`; never use that test mode on a non-loopback endpoint.
