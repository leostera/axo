# axod CLI (`axod`)

`axod` is the daemon's command-line entrypoint. It uses `clap` for argument parsing and delegates server startup to `axo-server`; it does not implement daemon behavior or JSON-RPC itself.

```sh
axod [--socket <absolute-path>] [--server-dir <absolute-path>] [--host-credentials keychain|files]
axod --version
axod mcp            # with AXO_SOCKET and AXO_SESSION_ID set; see below
```

Without `--socket`, the server uses `~/Library/Application Support/Axo/run/axod.sock`. Without `--server-dir`, it stores `axo.pid`, `stdout.log`, and `stderr.log` under `~/.axo/server/`. It uses `HOME` when absolute and falls back to the current account's home directory when LaunchAgent environments omit it. The directory is private to the user; logs include timestamps, levels, and stable lifecycle event names, append across launches, and rotate to one `.log.1` backup on startup when larger than 10 MiB. `--server-dir` is useful for isolated tests and local runs. `--host-credentials` chooses where relay host credentials live: the login Keychain (default on macOS) or `0600` files under `<server-dir>/host-credentials` (default elsewhere, and required in isolated tests so they never write to the Keychain).

The PID file is diagnostic metadata, not a process-control mechanism: launchd remains the source of truth for service lifetime, and a forced kill may leave a stale PID file until the next successful start replaces it. On macOS, `SMAppService` registers the bundled executable as a per-user LaunchAgent; launchd owns its process lifetime.

## Crates

| Crate | Owns |
| --- | --- |
| `axod` | This binary and the `terminal-attach` and `mcp` subcommands. |
| [`axo-server`](../axo-server/README.md) | The daemon (RFD0041): a task per Session owning its panes, Pi and prompts; a `watch` catalog; the store on `tokio-rusqlite`; events on `broadcast`; the local methods, the attach socket and the relay adapter. No SQL outside its tests. |
| [`axo-store`](../axo-store/README.md) | The SQLite catalog: `open` (WAL, `synchronous=FULL`, owner-only file), schema and migrations, and every database-only read and write, each tested against an in-memory database. It knows no processes, files or settings syntax. |
| [`axo-protocol`](../axo-protocol/README.md) | Wire types: IDs, `PaneRole`, layouts, records, typed RPC params/results and events, and `base64` for terminal bytes (bounded, canonical input decoding). |
| [`axo-pty`](../axo-pty/README.md) | PTYs (opened step by step, retrying the kernel's `EREDRIVEOPEN` allocation race), launching children on them, the permanent output pump, attach protocol v2, and `process::stop_all`. |
| [`axo-agent`](../axo-agent/README.md) | Pi launch with the lifeline, the async bridge link and protocol, the writer lock, process identities, activity. |
| [`axo-ipc`](../axo-ipc/README.md) | Newline-delimited JSON-RPC over the Unix socket. |
| [`axo-relay`](../axo-relay/README.md) | The Cloudflare host relay. |
| [`axod-loadtest`](../axod-loadtest/README.md) | `axod-loadtest --profile heavy`: load against an isolated axod; pass bar control-plane p99 < 10 ms. |
| [`axo-vt`](../axo-vt/README.md) | The headless libghostty-vt terminal behind every shell's replay and `axo.terminal.screen`. |
| [`axo-signin`](../axo-signin/README.md) | Loopback sign-in for services that only redirect to `localhost` (RFD0016). |
| [`axo-computer`](../axo-computer/README.md) | Computer use for `axod mcp`, through Cua Driver's macOS runtime. |
| [`axod-infer`](../axod-infer/README.md) | The local inference side-car (Clef on llama.cpp). |

## Runtime and attachment invariants

- A durable pane ID is not a process identity. Each launch gets a daemon-local runtime ID; attachment output/detachment, Pi bridge metadata/activity, and resume requests are checked against that runtime. Late callbacks from a replaced process cannot modify its replacement.
- Axod is the single, permanent reader of every PTY it owns. Each shell has an output pump from spawn until its PTY reaches end of file; it feeds every byte into the shell's headless libghostty-vt terminal (`crates/axo-vt`), publishes `terminal.output`, and fans bytes out to every attachment. Shells never stall on a full PTY buffer because nothing is attached, and any number of clients can attach to one shell.
- Attach protocol v2: the client writes `<shellId>\n`; Axod replies with `u64::MAX` plus a rejection code, or with the replay length (big-endian `u64`), one `SCM_RIGHTS` message carrying the PTY master, then the replay and live output as raw bytes. The replay is a VT snapshot of the shell's screen at the PTY's current size (modes, contents, scrollback, cursor, keyboard state, and any escape sequence in progress), at most 8 MiB; older scrollback is shed to fit. The descriptor is for input, resizing and termios/foreground queries only. Closing the socket detaches; end of file means the shell exited or the client fell more than 8 MiB behind (clients consult the catalog to tell which).
- Accepted terminal sockets explicitly use bounded blocking I/O, including on macOS where accepted sockets can inherit the listener's nonblocking mode. A failed or timed-out write ends the attachment, so a partial write never corrupts a live stream. Stalled clients release their attachment lease; idle attachments observe shutdown, client close and runtime replacement.
- Child wait failures are reported once per runtime and isolated from other children. An uncertain child remains represented; Axod does not infer completion or signal a possibly reused PID after losing wait ownership.
- Every Session has a folder (`initial_pwd`, `folder` on the wire) and opens with Pi on the left and a terminal on the right (one layout, written with the Session). `axo.session.create` takes a `folder`, or `like` another open Session to start beside it, or neither for the home directory (RFD0038). Axod opens no Session by itself, and closing the last one leaves none; a Session whose Pi cannot start fails to be created and never keeps Axod from starting.
- Every Pi inherits the lifeline pipe and exits when axod does, so no Pi outlives axod. A Pi a previous axod left running (one that held its writer lock at boot) is matched against the stored `pi_process:<sessionId>` identity, SIGKILLed, and started again as axod's child on the same transcript; a holder axod did not launch is never signalled, and its pane is unavailable.
- Each open Session is one task owning its panes, its Pi, the Pi's bridge link and the prompts waiting for it. Every change goes through its mailbox; slow work (launching Pi, Pi commands, import, `/resume`) runs beside it and reports back, tagged with the runtime it was for, so late results never touch a replacement.
- Closing a Session or stopping axod stops its panes: SIGHUP and SIGTERM, then SIGKILL when the grace runs out (terminals 500 ms, Pi `axo_agent::pi::STOP_GRACE`). Restarting Pi asks it to shut down over its bridge, kills it after a grace, and starts it again.
- Only the intended Pi child inherits its transcript writer lock across exec. The parent keeps close-on-exec set throughout launch so unrelated child processes cannot accidentally retain that lock. No transcript content is rewritten by these lifecycle operations.
- Local event subscriptions: each is an `axo.session.events.stream` connection, which axod pushes batches down as they happen and which ends the subscription when it closes. Events go out on a `broadcast` channel, so one client never stalls another or the relay. Catalog subscribers (`includeTerminalOutput: false`) receive catalog events only (`session.*`, `workspace.changed`, `shell.activity`, `relay.status`), never terminal output or `pi.event`. Falling behind reports `subscription.lagged` and ends the stream; batches are ordered; initial snapshots go only to the new subscriber.
- `axo.shell.busy` reports whether closing a shell would interrupt work: the PTY foreground process group (`tcgetpgrp`) differs from the shell, or the Pi pane is mid-turn. The foreground process name is a presentation hint only.

- `axo.session.reopen` (⌘⇧T, **Reopen Closed Session**) undoes a close: it reopens the most recently closed Session (`termination_reason = 'explicit_close'`, so not one whose shell exited or whose Workspace was archived) with the panes that closed with it. A pane closed on its own is archived as `pane_closed` and stays closed. Terminals start fresh in the Session's directory and Pi resumes its history. A Session that can no longer be reopened is skipped for the one closed before it; when none is left the error is `-32005`.
- A Pi that never completed a message never wrote its transcript (Pi creates it with the first message). Recovering such a pane, on restart or reopen, starts a fresh Pi on the same path. A transcript that disappears after messages is still refused, never replaced.

See [recovery hardening evidence and remaining boundaries](../../docs/axod-recovery-hardening.md) for verification and follow-up scope.

On start, Axod restores Pis in order: first those its previous run recorded as mid-turn when it stopped (each is then prompted that it was stopped and may continue; see `stop_notice`), then those active in the last hour, most recent first. Older Sessions' Pis stay dormant (`Availability::Dormant`, `"dormant": true` on the wire) until the Session is wanted: a prompt from anyone, a client sizing or typing into that pane, or the Mac showing the Session (which asks for the restart). Dormant Sessions report `ready`.

Answering is not the same as ready: Axod answers once Sessions are restored, while the Pis it started are still booting. It is **ready** once each of those Pis has connected its bridge or died, or after 15 seconds whatever is still starting (`session/readiness.rs`). It then publishes one `daemon.ready` event, and `axo.daemon.health` answers `ready: true` from then on. The Mac app shows the terminal window only once Axod is ready.

These guarantees do not make a daemon restart transparent: restarting Axod still replaces its PTYs/processes. Automatic Pi recovery remains idle-only and non-forcing, and restoration can leave a pane unavailable when the original transcript or safe writer ownership is unavailable.

## Agents as clients (RFD0015)

Each Pi gets `AXO_SOCKET` (this socket) and `AXOD` (this executable) in its environment, and pi-axo registers `axod mcp` for its Session as Pi's `axo` MCP server with `codemode` exposure. `axod mcp` (`crates/axo-mcp`) translates MCP tool calls into calls on the socket: `whoami`, `session_catalog`, `workspace_list`, `workspace_session_create`, `session_rename`, `session_prompt`, `shell_create`, `shell_close`, `terminal_write`, `terminal_screen`. It accepts `"self"` for a Session or Workspace ID and always names its own Session as a prompt's sender. There is no authentication: everything runs as the person's user.

- `axo.session.catalog`: open Sessions plus the 1000 most recently archived, each with `piSessionFile`, so agents search transcripts with `rg`/`jq`. Side-effect free, unlike `axo.session.list`, which consumes the Mac's `/resume` focus.
- `axo.session.prompt { sessionId, text, delivery?, fromSessionId? }`: sends the bridge's `send` command through the Pi's bridge link (`axo_agent::pi::link`), on the one connection pi-axo's bridge serves; a Pi still starting queues up to 8. Remote prompts use the same path with `steer`. A prompt from an agent is headed `[From Axo Session N "Name"]`. More than 30 prompts a minute per sender, or 10 to itself, is `-32003`; not delivered is `-32004`.
- `axo.terminal.write { sessionId, shellId, text }`: types into a pane outside `axo.terminal.input`'s sequence. `axo.terminal.screen { sessionId, shellId, lines? }`: the last lines (default 200) of the pane's headless terminal as plain text.

## Cloudflare host relay

The packaged LaunchAgent supplies the Axo API URL. Axod attempts to connect automatically when it starts and retries with backoff; **Axo.app → Settings → Remote Access** reports the actual relay connection state and lets you request an immediate retry. The host name is read from existing local host metadata (or the system hostname on first setup), and the platform is reported as macOS. There is no API URL or editable host-name setup in the app.

The daemon derives its stable host ID from its private session database and rotates the host generation at each daemon-process start. It connects to `/v1/hosts/<host-id>/daemon` over TLS, registers terminal-free session metadata, sends periodic heartbeats, and streams activity/output events without retaining them in Cloudflare storage. Local PTYs remain owned by `axod`; closing the Axo.app UI detaches the terminal view but does not stop the LaunchAgent or its PTYs. Restarting the daemon itself does stop those processes, after which Axod restores session records by starting replacement shells.

A failed Pi recovery is isolated to its pane: Axod stays available, retains the open Session and transcript, and reports the pane as unavailable. An unexpected Pi process exit also leaves the Session and Pi pane open-but-unavailable; it does not archive the Session or its sibling panes. **Settings → Agent → Automatically restart unavailable Pi sessions** retries recovery for each affected pane. Automatic retries are safe-only: Axod starts a replacement when the transcript lock is free, or asks the exact authenticated Pi bridge to shut down only if Pi reports idle. Busy or unresponsive Pi processes are never force-stopped automatically; their panes remain unavailable and Axo keeps retrying while the option is enabled. The pane's **Restart Pi** action remains an explicit, pane-scoped recovery: it first authenticates to the Pi bridge and requests shutdown. If that bridge is unavailable, the explicit restart may identify the exclusive transcript-lock owner, but only when the lock is held by one process group owned by the current user and led by `pi`. Axod then sends SIGTERM and, if necessary, SIGKILL only to that verified group. Axod acquires the original transcript lock before starting any replacement; it never overwrites the conversation history.

For isolated loopback tests only, the relay supports `allowInsecureLoopback: true` with a `ws://localhost`/loopback URL and `access: { "kind": "accessAssertion", "assertion": "<fixture JWT>" }`; never use that test mode on a non-loopback endpoint.
